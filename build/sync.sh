#!/usr/bin/env bash
# build/sync.sh — Plan 00 / T0.2. Pin + fetch Chromium, apply the
# ungoogled-chromium series, and leave a clean tree at $CHROMIUM_SRC that is
# ready for build/apply-patches.sh (our patches) + build/gen-and-build.sh.
#
# Reads the (chromium_tag, ungoogled_tag) pin from build/PINS.
#
# Usage:
#   build/sync.sh --mode gclient   # dev iteration: full git history, fast incremental (Path A)
#   build/sync.sh --mode tarball    # reproducible CI: ungoogled prepared source (Path B)
#
# Flags:
#   --prune / --no-prune            run ungoogled prune_binaries (default: off gclient, on tarball)
#   --domain-sub / --no-domain-sub  run ungoogled domain substitution (default: off gclient, on tarball)
#   --no-history                    shallow gclient fetch (faster/smaller; hurts doc-01 rebasing)
#
# Env overrides:
#   WORK          working root (default: $HOME)
#   DEPOT_TOOLS   depot_tools dir            (default: $WORK/depot_tools)
#   CHROMIUM_DIR  dir that will hold src/    (default: $WORK/chromium)
#   CHROMIUM_SRC  the chromium checkout      (default: $CHROMIUM_DIR/src)
#   UGC_DIR       ungoogled-chromium clone   (default: $WORK/ungoogled-chromium)
set -euo pipefail

RAVEN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="${WORK:-$HOME}"
DEPOT_TOOLS="${DEPOT_TOOLS:-$WORK/depot_tools}"
CHROMIUM_DIR="${CHROMIUM_DIR:-$WORK/chromium}"
CHROMIUM_SRC="${CHROMIUM_SRC:-$CHROMIUM_DIR/src}"
UGC_DIR="${UGC_DIR:-$WORK/ungoogled-chromium}"

MODE=""
PRUNE="default"; DOMAIN_SUB="default"; HISTORY="full"
while [ $# -gt 0 ]; do
  case "$1" in
    --mode) MODE="$2"; shift 2;;
    --prune) PRUNE="on"; shift;;
    --no-prune) PRUNE="off"; shift;;
    --domain-sub) DOMAIN_SUB="on"; shift;;
    --no-domain-sub) DOMAIN_SUB="off"; shift;;
    --no-history) HISTORY="shallow"; shift;;
    *) echo "sync.sh: unknown arg: $1" >&2; exit 2;;
  esac
done
[ "$MODE" = "gclient" ] || [ "$MODE" = "tarball" ] || { echo "sync.sh: --mode gclient|tarball required" >&2; exit 2; }

log() { printf '\n\033[1;36m[sync:%s]\033[0m %s\n' "$MODE" "$*"; }
die() { printf '\n\033[1;31m[sync:FAIL]\033[0m %s\n' "$*" >&2; exit 1; }

# --- read pins ---
PINS="$RAVEN_ROOT/build/PINS"
[ -f "$PINS" ] || die "missing $PINS"
pin() { grep -E "^$1=" "$PINS" | head -1 | cut -d= -f2-; }
CHROMIUM_TAG="$(pin chromium_tag)"; UGC_TAG="$(pin ungoogled_tag)"
[ -n "$CHROMIUM_TAG" ] && [ -n "$UGC_TAG" ] || die "could not read chromium_tag/ungoogled_tag from PINS"
log "pins: chromium=$CHROMIUM_TAG ungoogled=$UGC_TAG"

export PATH="$DEPOT_TOOLS:$PATH"

# per-mode defaults for the ungoogled post-steps
if [ "$MODE" = "tarball" ]; then
  [ "$PRUNE" = "default" ] && PRUNE="on"
  [ "$DOMAIN_SUB" = "default" ] && DOMAIN_SUB="on"
else
  [ "$PRUNE" = "default" ] && PRUNE="off"
  [ "$DOMAIN_SUB" = "default" ] && DOMAIN_SUB="off"
fi

clone_ungoogled() {
  if [ -d "$UGC_DIR/.git" ]; then
    git -C "$UGC_DIR" fetch --depth 1 origin "refs/tags/$UGC_TAG:refs/tags/$UGC_TAG" -q || true
    git -C "$UGC_DIR" checkout -q "$UGC_TAG"
  else
    log "cloning ungoogled-chromium @ $UGC_TAG"
    git clone -q --depth 1 --branch "$UGC_TAG" \
      https://github.com/ungoogled-software/ungoogled-chromium.git "$UGC_DIR"
  fi
}

apply_ungoogled_series() {
  local src="$1"
  command -v python3 >/dev/null || die "python3 required for ungoogled utils"
  if [ "$PRUNE" = "on" ]; then
    log "ungoogled: prune_binaries"
    python3 "$UGC_DIR/utils/prune_binaries.py" "$src" "$UGC_DIR/pruning.list" || die "prune_binaries failed"
  fi
  log "ungoogled: applying patch series ($(grep -vc '^#' "$UGC_DIR/patches/series" 2>/dev/null || echo '?') patches)"
  python3 "$UGC_DIR/utils/patches.py" apply "$src" "$UGC_DIR/patches" || die "ungoogled patches.py apply failed"
  if [ "$DOMAIN_SUB" = "on" ]; then
    log "ungoogled: domain substitution"
    python3 "$UGC_DIR/utils/domain_substitution.py" apply \
      -r "$UGC_DIR/domain_regex.list" -f "$UGC_DIR/domain_substitution.list" \
      -c "$WORK/domsubcache.tar.gz" "$src" || die "domain_substitution failed"
  fi
  log "ungoogled series applied; components/ungoogled/ should now exist"
  [ -d "$src/components/ungoogled" ] || echo "WARN: components/ungoogled missing after apply — check patch 000 base (ungoogled_switches)"
}

case "$MODE" in
  gclient)
    command -v fetch >/dev/null || die "depot_tools not on PATH ($DEPOT_TOOLS)"
    mkdir -p "$CHROMIUM_DIR"
    if [ ! -e "$CHROMIUM_DIR/.gclient" ]; then
      log "fetch --nohooks chromium into $CHROMIUM_DIR (long: ~tens of GB)"
      ( cd "$CHROMIUM_DIR" && \
        if [ "$HISTORY" = "shallow" ]; then fetch --no-history --nohooks chromium; else fetch --nohooks chromium; fi )
    else
      log "existing .gclient found; reusing $CHROMIUM_DIR"
    fi
    # Fetch ONLY the pinned tag (never `git fetch --tags`: that enumerates all of
    # chromium's tags and deadlocks). In FULL mode fetch normally. In shallow mode
    # use --depth 1 — but note --no-history is FRAGILE here: gclient's own re-fetch
    # (`git fetch origin --no-tags`) omits --depth and DEADLOCKS negotiating the
    # shallow boundary against googlesource. Prefer full. (VERIFY@env-specific.)
    if [ "$HISTORY" = "shallow" ]; then
      echo "WARN: --no-history is fragile with gclient here (no-depth re-fetch deadlocks)." >&2
      log "fetch pinned tag (shallow, depth 1) @ $CHROMIUM_TAG"
      git -C "$CHROMIUM_SRC" fetch --depth 1 -q origin "+refs/tags/$CHROMIUM_TAG:refs/tags/$CHROMIUM_TAG" \
        || die "tag fetch failed for $CHROMIUM_TAG"
    else
      log "fetch pinned tag (full) @ $CHROMIUM_TAG"
      git -C "$CHROMIUM_SRC" fetch -q origin "+refs/tags/$CHROMIUM_TAG:refs/tags/$CHROMIUM_TAG" \
        || die "tag fetch failed for $CHROMIUM_TAG"
    fi
    git -C "$CHROMIUM_SRC" checkout -q "refs/tags/$CHROMIUM_TAG" || die "tag checkout failed"
    log "gclient sync -> src@$CHROMIUM_TAG (deps + hooks; long)"
    # Do NOT pass --with_branch_heads/--with_tags: they add refs/branch-heads/* +
    # refs/tags/* to the src refspec and `git fetch origin` then deadlocks
    # enumerating all of chromium's tags. --revision pins src to the tag.
    SYNC_FLAGS="-D"
    [ "$HISTORY" = "shallow" ] && SYNC_FLAGS="$SYNC_FLAGS --no-history"
    ( cd "$CHROMIUM_SRC" && gclient sync $SYNC_FLAGS \
        --revision "src@refs/tags/$CHROMIUM_TAG" ) || die "gclient sync failed"
    clone_ungoogled
    apply_ungoogled_series "$CHROMIUM_SRC"
    ;;
  tarball)
    # Reproducible path: official chromium source tarball + ungoogled apply.
    # Toolchain hooks (clang/rust/pgo) are wired up with CI in Plan 00 / T0.6.
    mkdir -p "$CHROMIUM_DIR"
    TARBALL="chromium-$CHROMIUM_TAG.tar.xz"
    URL="https://commondatastorage.googleapis.com/chromium-browser-official/$TARBALL"
    if [ ! -d "$CHROMIUM_SRC" ]; then
      log "download $URL (large)"
      curl -fL --retry 3 -o "$CHROMIUM_DIR/$TARBALL" "$URL" || die "tarball download failed"
      log "extract tarball"
      mkdir -p "$CHROMIUM_SRC"
      tar -xf "$CHROMIUM_DIR/$TARBALL" -C "$CHROMIUM_DIR"
      mv "$CHROMIUM_DIR/chromium-$CHROMIUM_TAG"/* "$CHROMIUM_SRC"/ 2>/dev/null || true
    else
      log "existing $CHROMIUM_SRC; reusing"
    fi
    clone_ungoogled
    apply_ungoogled_series "$CHROMIUM_SRC"
    log "NOTE: tarball mode still needs depot_tools toolchain hooks before build (Plan 00 / T0.6)"
    ;;
esac

log "done. next: build/apply-patches.sh  then  build/gen-and-build.sh"
log "CHROMIUM_SRC=$CHROMIUM_SRC"
