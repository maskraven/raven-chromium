#!/usr/bin/env bash
# build/package-linux.sh — Plan 05 (Linux) T5.1/T5.3/T5.5.
# Packages a built Raven Chromium into a checksummed (+ optionally GPG-signed)
# release tarball, GATED on Plan 04 validation (persistence + coherence +
# branding scrub). macOS/Windows artifacts require matching-OS runners with
# codesign/notarize or Authenticode (out of scope for this Linux script).
#
# Usage:
#   package-linux.sh --src <chromium/src> --out <dist-dir> --version <v> \
#       --probe <fingerprint-probe.html> --profile <host-matched-descriptor.json> \
#       [--gpg-key <keyid>] [--skip-validate]
set -euo pipefail

SRC="" DIST="" VERSION="" PROBE="" PROFILE="" GPG_KEY="" SKIP_VALIDATE=0
OUTDIR="out/Default" ARCHLBL=""
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
while [ $# -gt 0 ]; do case "$1" in
  --src) SRC="$2"; shift 2;; --out) DIST="$2"; shift 2;; --version) VERSION="$2"; shift 2;;
  --probe) PROBE="$2"; shift 2;; --profile) PROFILE="$2"; shift 2;;
  --gpg-key) GPG_KEY="$2"; shift 2;; --outdir) OUTDIR="$2"; shift 2;;
  --arch) ARCHLBL="$2"; shift 2;;   # target arch label for the artifact name (else uname -m)
  --skip-validate) SKIP_VALIDATE=1; shift;; *) echo "unknown: $1" >&2; exit 2;; esac; done
: "${SRC:?--src required}" "${DIST:?--out required}" "${VERSION:?--version required}"
CHROME="$SRC/$OUTDIR/chrome"
[ -x "$CHROME" ] || { echo "package: no chrome at $CHROME" >&2; exit 1; }

if [ -n "$ARCHLBL" ]; then ARCH="$ARCHLBL"; else ARCH="$(uname -m)"; [ "$ARCH" = "x86_64" ] && ARCH="x64"; fi
NAME="raven-chromium-${VERSION}-linux-${ARCH}"
STAGE="$DIST/$NAME"

# --- 1. Plan 04 validation gate (persona must pass all gates) ---
if [ "$SKIP_VALIDATE" = 0 ]; then
  [ -n "$PROBE" ] && [ -n "$PROFILE" ] || { echo "package: --probe and --profile required (or --skip-validate)" >&2; exit 1; }
  echo "== [1/6] Plan 04 validation gate =="
  bash "$SELF/validate-persona.sh" --chrome "$CHROME" --probe "$PROBE" --profile "$PROFILE" --runs 3 \
    || { echo "package: VALIDATION FAILED — refusing to package" >&2; exit 1; }
else
  echo "== [1/6] validation SKIPPED (--skip-validate) =="
fi

# --- 2. resolve the exact runtime file set via gn ---
echo "== [2/6] runtime_deps =="
export PATH="$HOME/depot_tools:$PATH"
DEPS_FILE="$(mktemp)"
( cd "$SRC" && gn desc "$OUTDIR" //chrome:chrome runtime_deps 2>/dev/null ) > "$DEPS_FILE" || true
if [ ! -s "$DEPS_FILE" ]; then
  echo "package: gn runtime_deps empty — falling back to a known runtime set" >&2
  printf '%s\n' chrome chrome_crashpad_handler chrome_sandbox icudtl.dat \
    v8_context_snapshot.bin snapshot_blob.bin resources.pak chrome_100_percent.pak \
    chrome_200_percent.pak libEGL.so libGLESv2.so libvulkan.so.1 libvk_swiftshader.so \
    vk_swiftshader_icd.json > "$DEPS_FILE"
fi

# --- 3. stage runtime files ---
echo "== [3/6] stage -> $STAGE =="
rm -rf "$STAGE"; mkdir -p "$STAGE"
while IFS= read -r rel; do
  [ -n "$rel" ] || continue
  case "$rel" in \#*|obj/*|gen/*) continue;; esac   # skip comments + build intermediates
  f="$SRC/$OUTDIR/$rel"
  [ -e "$f" ] || continue
  mkdir -p "$STAGE/$(dirname "$rel")"
  cp -a "$f" "$STAGE/$rel"
done < "$DEPS_FILE"
rm -f "$DEPS_FILE"
[ -x "$STAGE/chrome" ] || { echo "package: chrome missing from stage" >&2; exit 1; }

# --- 4. drop a versioned manifest + the descriptor contract pointer ---
cat > "$STAGE/RAVEN-RELEASE.txt" <<EOF
Raven Chromium ${VERSION} (linux-${ARCH})
Base: ungoogled-chromium (see build/PINS). Runtime presents as stock Chrome.
Launch/descriptor contract: docs/contract/launch-contract-v1.md
EOF

# --- 5. tarball + checksums ---
echo "== [5/6] tar.xz + SHA256SUMS =="
TARBALL="$DIST/$NAME.tar.xz"
( cd "$DIST" && tar -cJf "$NAME.tar.xz" "$NAME" )
( cd "$DIST" && sha256sum "$NAME.tar.xz" > "$NAME.tar.xz.sha256" )

# --- 6. optional GPG detached signature ---
if [ -n "$GPG_KEY" ]; then
  echo "== [6/6] GPG sign ($GPG_KEY) =="
  gpg --local-user "$GPG_KEY" --armor --detach-sign --output "$TARBALL.asc" "$TARBALL"
else
  echo "== [6/6] GPG signing skipped (no --gpg-key) — checksum only =="
fi

echo "PACKAGED: $TARBALL"
ls -la "$DIST/$NAME".tar.xz* 2>/dev/null
