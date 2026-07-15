#!/usr/bin/env bash
# build/gen-and-build.sh — Plan 00 / T0.3. Composes gn args from
# build/args/common.gni + build/args/<platform>.gn (concatenation, not gn
# import), runs `gn gen`, then `autoninja` the target.
#
# Usage:
#   build/gen-and-build.sh [platform] [target]
#     platform: linux-x64 | macos-arm64 | win-x64  (default: autodetect)
#     target:   ninja target                        (default: chrome)
#
# Env:
#   CHROMIUM_SRC  chromium checkout (default: $HOME/chromium/src)
#   DEPOT_TOOLS   depot_tools dir   (default: $HOME/depot_tools)
#   OUT           gn out dir        (default: out/Default, relative to CHROMIUM_SRC)
set -euo pipefail

RAVEN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHROMIUM_SRC="${CHROMIUM_SRC:-$HOME/chromium/src}"
DEPOT_TOOLS="${DEPOT_TOOLS:-$HOME/depot_tools}"
OUT="${OUT:-out/Default}"
TARGET="${2:-chrome}"

# --- platform autodetect ---
PLATFORM="${1:-}"
if [ -z "$PLATFORM" ]; then
  case "$(uname -s)-$(uname -m)" in
    Darwin-arm64)  PLATFORM="macos-arm64";;
    Linux-x86_64)  PLATFORM="linux-x64";;
    *) echo "gen-and-build: cannot autodetect platform for $(uname -s)-$(uname -m); pass one" >&2; exit 2;;
  esac
fi
ARGS_COMMON="$RAVEN_ROOT/build/args/common.gni"
ARGS_PLAT="$RAVEN_ROOT/build/args/${PLATFORM}.gn"
[ -f "$ARGS_COMMON" ] || { echo "gen-and-build: missing $ARGS_COMMON" >&2; exit 1; }
[ -f "$ARGS_PLAT" ]   || { echo "gen-and-build: missing $ARGS_PLAT" >&2; exit 1; }
[ -d "$CHROMIUM_SRC" ] || { echo "gen-and-build: missing $CHROMIUM_SRC (run sync.sh)" >&2; exit 1; }

export PATH="$DEPOT_TOOLS:$PATH"
ARGS="$(cat "$ARGS_COMMON"; printf '\n'; cat "$ARGS_PLAT")"
# RELEASE=1 appends build/args/release.gni (LTO/official overrides). GN resolves the
# LAST assignment, so release.gni overrides the dev toggles from common.gni.
if [ "${RELEASE:-0}" = "1" ]; then
  ARGS_REL="$RAVEN_ROOT/build/args/release.gni"
  [ -f "$ARGS_REL" ] || { echo "gen-and-build: RELEASE=1 but missing $ARGS_REL" >&2; exit 1; }
  ARGS="$(printf '%s\n%s\n' "$ARGS" "$(cat "$ARGS_REL")")"
fi

echo "== platform=$PLATFORM target=$TARGET out=$OUT release=${RELEASE:-0} =="
echo "== gn gen (args below) =="
printf '%s\n' "$ARGS" | grep -vE '^\s*(#|$)'

cd "$CHROMIUM_SRC"
gn gen "$OUT" --args="$ARGS"
echo "== autoninja -C $OUT $TARGET =="
time autoninja -C "$OUT" "$TARGET"
echo "== build done: $CHROMIUM_SRC/$OUT =="
