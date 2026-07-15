#!/usr/bin/env bash
# build/raven-launch.sh — Linux launcher wrapper for Raven Chromium.
#
# Delivers the "user-supplied codecs" flag the in-process browser can't (libffmpeg
# is a DT_NEEDED lib resolved by ld.so before main, so no --switch can redirect it).
# This wrapper does the file-swap for you, then execs chrome.
#
#   raven-launch.sh --fingerprint-ffmpeg=/path/to/chrome-libffmpeg.so \
#                   --fingerprint-profile=/path/to/persona.json [other chrome args...]
#
# --fingerprint-ffmpeg=<path>  installs a licensed Chrome-branded libffmpeg.so next to
#   the binary ($ORIGIN/libffmpeg.so). Once present, the runtime avcodec_find_decoder
#   probe (fingerprint/225) flips canPlayType/MediaCapabilities for H.264/AAC to
#   "supported" AND playback works. The fork ships NO patented decoder; the licensing
#   for the lib you install rests with its source. All other args pass through to chrome.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHROME="${RAVEN_CHROME:-$HERE/chrome}"      # override with RAVEN_CHROME=/path/to/chrome
[ -x "$CHROME" ] || { echo "raven-launch: chrome not found/executable at $CHROME (set RAVEN_CHROME)" >&2; exit 1; }
ORIGIN="$(dirname "$CHROME")"

PASS=()
for arg in "$@"; do
  case "$arg" in
    --fingerprint-ffmpeg=*)
      SRC="${arg#*=}"
      [ -f "$SRC" ] || { echo "raven-launch: libffmpeg not found: $SRC" >&2; exit 1; }
      # basic sanity: it must export avcodec symbols (an actual ffmpeg build).
      # Slurp nm's full output into a var before matching: piping straight into
      # `grep -q` lets grep close the pipe on the first hit, so nm dies with
      # SIGPIPE (141) and `set -o pipefail` would flag a perfectly valid lib as
      # missing the symbol. Matching a captured string avoids the early close.
      if command -v nm >/dev/null 2>&1; then
        SYMS="$(nm -D "$SRC" 2>/dev/null || true)"
        case "$SYMS" in
          *avcodec_find_decoder*) ;;
          *) echo "raven-launch: WARNING: $SRC has no avcodec_find_decoder symbol — may not be a Chrome libffmpeg" >&2 ;;
        esac
      fi
      cp -f "$SRC" "$ORIGIN/libffmpeg.so"
      echo "raven-launch: installed user libffmpeg -> $ORIGIN/libffmpeg.so (H.264/AAC enabled)" >&2
      ;;
    *) PASS+=("$arg") ;;
  esac
done

exec "$CHROME" "${PASS[@]}"
