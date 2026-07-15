#!/usr/bin/env bash
# build/build-linux.sh — build Raven-Chromium for BOTH Linux arches (x64 native +
# arm64 cross-compile) and, optionally, package each into a release tarball.
#
# Cross-arch DRIVER mirroring build-macos.sh: orchestrates the existing pipeline
# against ONE shared checkout — sync.sh (optional) -> apply-patches.sh (optional) ->
# gen-and-build.sh per arch -> (optional) package-linux.sh per arch. arm64 is a
# CROSS-COMPILE from an x64 host (gn target_cpu="arm64", build/args/linux-arm64.gn);
# it needs Chromium's arm64 sysroot, which this script installs.
#
# By default it assumes CHROMIUM_SRC is ALREADY synced + patched and just (re)builds
# both arches. Pass --sync to do the full fetch+ungoogle+patch first (long).
#
# Usage:
#   build/build-linux.sh                          # dev build both arches
#   build/build-linux.sh --release                # release (LTO/official; hours) both arches
#   build/build-linux.sh --arch linux-arm64       # just one arch (linux-x64 | linux-arm64)
#   build/build-linux.sh --sync gclient           # full fetch+ungoogle+apply first, then build
#   build/build-linux.sh --package --version 150.0.7871.114   # + tar.xz per arch via package-linux.sh
#
# Env overrides:
#   CHROMIUM_SRC  chromium checkout (default: $HOME/chromium/src)
#   DEPOT_TOOLS   depot_tools dir   (default: $HOME/depot_tools)
#   DIST          output dir for tarballs (default: $RAVEN_ROOT/dist)
set -euo pipefail

RAVEN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHROMIUM_SRC="${CHROMIUM_SRC:-$HOME/chromium/src}"
DEPOT_TOOLS="${DEPOT_TOOLS:-$HOME/depot_tools}"
DIST="${DIST:-$RAVEN_ROOT/dist}"

ARCH="both"; RELEASE=0; SYNC="none"; PACKAGE=0; VERSION=""
while [ $# -gt 0 ]; do case "$1" in
  --arch) ARCH="$2"; shift 2;;
  --release) RELEASE=1; shift;;
  --sync) SYNC="$2"; shift 2;;
  --package) PACKAGE=1; shift;;
  --version) VERSION="$2"; shift 2;;
  --src) CHROMIUM_SRC="$2"; shift 2;;
  --out) DIST="$2"; shift 2;;
  -h|--help) grep -E '^# ' "$0" | sed -E 's/^# ?//'; exit 0;;
  *) echo "build-linux: unknown arg: $1" >&2; exit 2;;
esac; done

log() { printf '\n\033[1;36m[linux-build]\033[0m %s\n' "$*"; }
die() { printf '\n\033[1;31m[linux-build:FAIL]\033[0m %s\n' "$*" >&2; exit 1; }

[ -n "$VERSION" ] || VERSION="$(grep -E '^chromium_tag=' "$RAVEN_ROOT/build/PINS" | head -1 | cut -d= -f2-)"

case "$ARCH" in
  both)                    PLATFORMS=(linux-x64 linux-arm64);;
  linux-x64|x64)           PLATFORMS=(linux-x64);;
  linux-arm64|arm64)       PLATFORMS=(linux-arm64);;
  *) die "unknown --arch '$ARCH' (both | linux-x64 | linux-arm64)";;
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

# ---- 2. arm64 cross-compile needs the arm64 sysroot ----
need_arm64=0
for p in "${PLATFORMS[@]}"; do [ "$p" = "linux-arm64" ] && need_arm64=1; done
if [ "$need_arm64" = 1 ]; then
  ss="$CHROMIUM_SRC/build/linux/sysroot_scripts/install-sysroot.py"
  if [ -f "$ss" ]; then
    log "install arm64 sysroot (for the cross-compile)"
    python3 "$ss" --arch=arm64 || die "arm64 sysroot install failed"
  else
    echo "WARN: $ss not found — the arm64 cross-build will fail without the sysroot" >&2
  fi
fi

# ---- 3. build (+ optional package) each arch ----
mkdir -p "$DIST"
ARTIFACTS=()
for plat in "${PLATFORMS[@]}"; do
  arch_label="${plat#linux-}"    # x64 | arm64
  out="out/$plat"
  log "build $plat (release=$RELEASE) -> $CHROMIUM_SRC/$out"
  RELEASE="$RELEASE" OUT="$out" bash "$RAVEN_ROOT/build/gen-and-build.sh" "$plat" chrome \
    || die "build failed for $plat"

  if [ "$PACKAGE" = 1 ]; then
    log "package (tar.xz) $plat via package-linux.sh"
    bash "$RAVEN_ROOT/build/package-linux.sh" --src "$CHROMIUM_SRC" --out "$DIST" \
      --version "$VERSION" --outdir "$out" --arch "$arch_label" --skip-validate \
      || die "packaging failed for $plat"
    ARTIFACTS+=("$DIST/raven-chromium-${VERSION}-linux-${arch_label}.tar.xz")
  else
    ARTIFACTS+=("$CHROMIUM_SRC/$out/chrome")
  fi
done

log "DONE:"
for a in "${ARTIFACTS[@]}"; do printf '  %s\n' "$a"; done
[ "$PACKAGE" = 1 ] || log "NOTE: built binaries only. Add --package (with --version) to also produce a tar.xz per arch via build/package-linux.sh."
