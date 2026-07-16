#!/usr/bin/env bash
# build/apply-patches.sh — Plan 00 / T0.5. Applies the RAVEN patch series
# (patches/core/* then patches/fingerprint/*, ordered by patches/series) on top
# of an already-ungoogled tree produced by build/sync.sh. Stops on first reject.
#
# patches/series holds one patch path per line, RELATIVE TO patches/, e.g.:
#     core/100-farbling-prng.patch
#     fingerprint/000-add-fingerprint-switches.patch
# Blank lines and lines starting with '#' are ignored. Order = file order.
#
# Env:
#   CHROMIUM_SRC  chromium checkout to patch (default: $HOME/chromium/src)
#   REVERSE=1     un-apply the series (reverse order) — for clean rebase resets
set -euo pipefail

RAVEN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHROMIUM_SRC="${CHROMIUM_SRC:-$HOME/chromium/src}"
SERIES="$RAVEN_ROOT/patches/series"

[ -d "$CHROMIUM_SRC/.git" ] || { echo "apply-patches: $CHROMIUM_SRC is not a git checkout (run sync.sh first)" >&2; exit 1; }
[ -f "$SERIES" ] || { echo "apply-patches: missing $SERIES" >&2; exit 1; }

# bash 3.2 (macOS /bin/bash) has no `mapfile`; read the series portably.
# `[[:space:]]` not `\s` — BSD/macOS grep doesn't support the \s shorthand.
NAMES=()
while IFS= read -r line; do NAMES+=("$line"); done \
  < <(grep -vE '^[[:space:]]*(#|$)' "$SERIES" || true)
if [ "${#NAMES[@]}" -eq 0 ]; then
  echo "apply-patches: patches/series is empty — nothing to apply (vanilla tree)."
  exit 0
fi

if [ "${REVERSE:-0}" = "1" ]; then
  for ((i=${#NAMES[@]}-1; i>=0; i--)); do NAMES_REV+=("${NAMES[$i]}"); done
  NAMES=("${NAMES_REV[@]}")
fi

for name in "${NAMES[@]}"; do
  patch="$RAVEN_ROOT/patches/$name"
  [ -f "$patch" ] || { echo "apply-patches: patch not found: $patch" >&2; exit 1; }
  if [ "${REVERSE:-0}" = "1" ]; then
    echo "[reverse] $name"
    if ! git -C "$CHROMIUM_SRC" apply --3way --reverse "$patch" 2>/dev/null; then
      # --3way can't touch submodule paths (e.g. the v8 gitlink needs an index
      # blob); a plain apply edits the submodule working tree directly.
      git -C "$CHROMIUM_SRC" apply --reverse "$patch" \
        || { echo "apply-patches: FAILED to reverse $name" >&2; exit 1; }
    fi
  else
    echo "[apply]   $name"
    # Try a 3-way apply first (tolerant of context drift). If it fails, retry a
    # plain apply: --3way cannot write submodule paths (e.g. patch 001 targets
    # the v8 gitlink), whereas a plain apply edits the submodule working tree.
    if ! git -C "$CHROMIUM_SRC" apply --3way "$patch" 2>/dev/null; then
      if ! git -C "$CHROMIUM_SRC" apply "$patch"; then
        echo "apply-patches: FAILED to apply $name (conflict/reject) — resolve before continuing" >&2
        exit 1
      fi
      echo "          (applied without --3way — submodule or exact-context patch)"
    fi
  fi
done
echo "apply-patches: ${#NAMES[@]} patch(es) OK."
