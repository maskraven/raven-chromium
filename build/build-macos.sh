#!/usr/bin/env bash
# build/build-macos.sh — build Raven-Chromium for BOTH macOS arches (arm64 native +
# x64 cross-compile on Apple silicon) and package each into a .dmg.
#
# Cross-arch DRIVER: it orchestrates the existing pipeline against ONE shared
# checkout — sync.sh (optional) -> apply-patches.sh (optional) -> gen-and-build.sh
# per arch -> DMG per arch. x64 cross-compiles cleanly from an arm64 host via gn
# target_cpu="x64" (build/args/macos-x64.gn); no Rosetta needed.
#
# By default it assumes CHROMIUM_SRC is ALREADY synced + patched (the normal dev
# loop: you ran the pipeline once) and just (re)builds both arches. Pass --sync to
# do the full fetch+ungoogle+patch first (long).
#
# Usage:
#   build/build-macos.sh                         # dev build both arches -> UNSIGNED DMGs
#   build/build-macos.sh --release               # release (LTO/official; hours) both arches
#   build/build-macos.sh --arch macos-x64        # just one arch (macos-arm64 | macos-x64)
#   build/build-macos.sh --sync gclient          # full fetch+ungoogle+apply first, then build
#   build/build-macos.sh --identity "Developer ID Application: NAME (TEAMID)" \
#        --version 150.0.7871.114 [--skip-notarize]   # signed(+notarized) DMG via package-macos.sh
#
# Env overrides (shared with the rest of the pipeline):
#   CHROMIUM_SRC  chromium checkout (default: $HOME/chromium/src)
#   DEPOT_TOOLS   depot_tools dir   (default: $HOME/depot_tools)
#   DIST          output dir for the DMGs (default: $RAVEN_ROOT/dist)
set -euo pipefail

RAVEN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHROMIUM_SRC="${CHROMIUM_SRC:-$HOME/chromium/src}"
DEPOT_TOOLS="${DEPOT_TOOLS:-$HOME/depot_tools}"
DIST="${DIST:-$RAVEN_ROOT/dist}"

ARCH="both"; RELEASE=0; SYNC="none"; IDENTITY=""; SKIP_NOTARIZE=0; VERSION=""
while [ $# -gt 0 ]; do case "$1" in
  --arch) ARCH="$2"; shift 2;;
  --release) RELEASE=1; shift;;
  --sync) SYNC="$2"; shift 2;;
  --identity) IDENTITY="$2"; shift 2;;
  --skip-notarize) SKIP_NOTARIZE=1; shift;;
  --version) VERSION="$2"; shift 2;;
  --src) CHROMIUM_SRC="$2"; shift 2;;
  --out) DIST="$2"; shift 2;;
  -h|--help) grep -E '^# ' "$0" | sed -E 's/^# ?//'; exit 0;;
  *) echo "build-macos: unknown arg: $1" >&2; exit 2;;
esac; done

[ "$(uname)" = "Darwin" ] || { echo "build-macos: must run on macOS (needs Xcode + hdiutil)" >&2; exit 1; }
log() { printf '\n\033[1;36m[macos-build]\033[0m %s\n' "$*"; }
die() { printf '\n\033[1;31m[macos-build:FAIL]\033[0m %s\n' "$*" >&2; exit 1; }

# version label defaults to the pinned chromium tag
[ -n "$VERSION" ] || VERSION="$(grep -E '^chromium_tag=' "$RAVEN_ROOT/build/PINS" | head -1 | cut -d= -f2-)"

case "$ARCH" in
  both)                     PLATFORMS=(macos-arm64 macos-x64);;
  macos-arm64|arm64)        PLATFORMS=(macos-arm64);;
  macos-x64|x64)            PLATFORMS=(macos-x64);;
  *) die "unknown --arch '$ARCH' (both | macos-arm64 | macos-x64)";;
esac

export PATH="$DEPOT_TOOLS:$PATH"
export CHROMIUM_SRC DEPOT_TOOLS

# ---- 1. (optional) prepare the shared tree ----
if [ "$SYNC" != "none" ]; then
  log "sync ($SYNC) + ungoogle"; bash "$RAVEN_ROOT/build/sync.sh" --mode "$SYNC"
  log "apply Raven series";      bash "$RAVEN_ROOT/build/apply-patches.sh"
else
  [ -d "$CHROMIUM_SRC/.git" ] || die "no checkout at $CHROMIUM_SRC (run with '--sync gclient', or set CHROMIUM_SRC)"
fi

# ---- 2. build + DMG each arch ----
mkdir -p "$DIST"
DMGS=()
for plat in "${PLATFORMS[@]}"; do
  arch_label="${plat#macos-}"    # arm64 | x64
  out="out/$plat"
  log "build $plat (release=$RELEASE) -> $CHROMIUM_SRC/$out"
  RELEASE="$RELEASE" OUT="$out" bash "$RAVEN_ROOT/build/gen-and-build.sh" "$plat" chrome \
    || die "build failed for $plat"

  dmg="$DIST/raven-chromium-${VERSION}-macos-${arch_label}.dmg"
  if [ -n "$IDENTITY" ]; then
    # Full signed (+ optionally notarized) DMG through the release packager.
    log "package (signed) $plat via package-macos.sh"
    pkg_args=(--src "$CHROMIUM_SRC" --out "$DIST" --version "$VERSION"
              --identity "$IDENTITY" --outdir "$out" --arch "$arch_label")
    [ "$SKIP_NOTARIZE" = 1 ] && pkg_args+=(--skip-notarize)
    bash "$RAVEN_ROOT/build/package-macos.sh" "${pkg_args[@]}" || die "packaging failed for $plat"
  else
    # Unsigned dev DMG (no certs needed): hdiutil the built .app directly.
    app="$(/bin/ls -d "$CHROMIUM_SRC/$out/"*.app 2>/dev/null | head -1)"
    [ -d "$app" ] || die "no .app in $CHROMIUM_SRC/$out — did the build produce one?"
    log "package (unsigned) $plat -> $dmg"
    rm -f "$dmg"
    hdiutil create -volname "Raven Chromium" -srcfolder "$app" -ov -format UDZO "$dmg" >/dev/null
    ( cd "$DIST" && shasum -a 256 "$(basename "$dmg")" > "$(basename "$dmg").sha256" )
  fi
  DMGS+=("$dmg")
done

log "DONE — DMGs:"
for d in "${DMGS[@]}"; do printf '  %s\n' "$d"; done
[ -n "$IDENTITY" ] || log "NOTE: these DMGs are UNSIGNED (dev). For signed+notarized release DMGs pass --identity (and set up notarytool); that routes through build/package-macos.sh."
