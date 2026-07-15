#!/usr/bin/env bash
# build/package-macos.sh — Plan 05 T5.1/T5.3/T5.5 (macOS). Signs, notarizes, and
# packages a built Raven Chromium .app into a signed DMG + checksum, GATED on
# Plan 04 validation. MUST run on a macOS host (matching the persona OS/GPU class,
# README constraint) with a Developer ID Application cert in the keychain.
#
# Chromium's .app nests many Mach-O binaries (frameworks, helpers) that must be
# signed inside-out. This prefers Chromium's own signing tool when present and
# falls back to a manual recursive codesign.
#
# Usage:
#   package-macos.sh --src <chromium/src> --out <dist> --version <v> \
#     --identity "Developer ID Application: NAME (TEAMID)" \
#     --team-id <TEAMID> --profile <host-matched.json> --probe <probe.html> \
#     [--keychain-profile <notarytool-profile>] [--skip-notarize]
set -euo pipefail

SRC="" DIST="" VERSION="" IDENTITY="" TEAMID="" PROFILE="" PROBE=""
NOTARY_PROFILE="" SKIP_NOTARIZE=0 OUTDIR="out/Default" ARCHLBL=""
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
while [ $# -gt 0 ]; do case "$1" in
  --src) SRC="$2"; shift 2;; --out) DIST="$2"; shift 2;; --version) VERSION="$2"; shift 2;;
  --identity) IDENTITY="$2"; shift 2;; --team-id) TEAMID="$2"; shift 2;;
  --profile) PROFILE="$2"; shift 2;; --probe) PROBE="$2"; shift 2;;
  --keychain-profile) NOTARY_PROFILE="$2"; shift 2;; --skip-notarize) SKIP_NOTARIZE=1; shift;;
  --outdir) OUTDIR="$2"; shift 2;;
  --arch) ARCHLBL="$2"; shift 2;;   # target arch label for the artifact name (else uname -m)
  *) echo "unknown: $1" >&2; exit 2;; esac; done
: "${SRC:?--src}" "${DIST:?--out}" "${VERSION:?--version}" "${IDENTITY:?--identity}"
[ "$(uname)" = "Darwin" ] || { echo "package-macos: must run on macOS" >&2; exit 1; }

APP="$(/bin/ls -d "$SRC/$OUTDIR/"*.app 2>/dev/null | head -1)"
[ -d "$APP" ] || { echo "package-macos: no .app in $SRC/$OUTDIR" >&2; exit 1; }
APP_ENT="$SELF/sign/entitlements-app.plist"
REN_ENT="$SELF/sign/entitlements-helper-renderer.plist"

# --- 1. Plan 04 validation gate (chrome CLI inside the .app) ---
CHROME_BIN="$(/usr/bin/find "$APP/Contents/MacOS" -maxdepth 1 -type f | head -1)"
if [ -n "$PROBE" ] && [ -n "$PROFILE" ]; then
  echo "== [1/6] validation gate =="
  bash "$SELF/validate-persona.sh" --chrome "$CHROME_BIN" --probe "$PROBE" --profile "$PROFILE" --runs 3 \
    || { echo "package-macos: VALIDATION FAILED" >&2; exit 1; }
fi

# --- 2. sign (prefer Chromium's tool; else manual recursive) ---
echo "== [2/6] codesign =="
if [ -f "$SRC/chrome/installer/mac/sign_chrome.py" ]; then
  # Chromium's signer handles the nested-binary ordering + per-helper entitlements.
  python3 "$SRC/chrome/installer/mac/sign_chrome.py" \
    --input "$APP" --identity "$IDENTITY" --development || true
fi
# Manual inside-out pass (idempotent; ensures every Mach-O is signed + hardened).
find "$APP/Contents/Frameworks" -type f \( -name "*.dylib" -o -perm -111 \) -print0 2>/dev/null \
  | while IFS= read -r -d '' f; do
      codesign --force --timestamp --options runtime --sign "$IDENTITY" "$f" 2>/dev/null || true
    done
# Helpers (renderer/GPU) need the JIT entitlements.
find "$APP" -name "*Helper*.app" -print0 2>/dev/null | while IFS= read -r -d '' h; do
  codesign --force --timestamp --options runtime --entitlements "$REN_ENT" --sign "$IDENTITY" "$h"
done
# Finally the outer app.
codesign --force --timestamp --options runtime --entitlements "$APP_ENT" --sign "$IDENTITY" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

# --- 3. package into a DMG ---
echo "== [3/6] dmg =="
mkdir -p "$DIST"
NAME="raven-chromium-${VERSION}-macos-${ARCHLBL:-$(uname -m)}"
DMG="$DIST/$NAME.dmg"
rm -f "$DMG"
hdiutil create -volname "Raven Chromium" -srcfolder "$APP" -ov -format UDZO "$DMG"
codesign --force --timestamp --sign "$IDENTITY" "$DMG"

# --- 4. notarize + staple ---
if [ "$SKIP_NOTARIZE" = 0 ]; then
  echo "== [4/6] notarize =="
  if [ -n "$NOTARY_PROFILE" ]; then
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  else
    echo "package-macos: --keychain-profile not set; run 'notarytool store-credentials' first" >&2
    echo "  (skipping notarize submit; DMG is signed but NOT notarized)"
  fi
  xcrun stapler staple "$DMG" || echo "  (staple skipped — not notarized)"
fi

# --- 5. checksums ---
echo "== [5/6] checksum =="
( cd "$DIST" && shasum -a 256 "$NAME.dmg" > "$NAME.dmg.sha256" )

echo "== [6/6] done =="
echo "PACKAGED (signed): $DMG"
