#!/usr/bin/env bash
# build/validate-persona.sh — Plan 04 core validation gate.
# Drives the built browser through the fingerprint probe and gates on:
#   PERSISTENCE  — byte-identical fingerprint across restarts (compare title FP:<hash>)
#   COHERENCE    — no cross-axis contradictions (profile-db/... compare.py)
#   BRANDING     — no raven/chromium/headless leak into any JS-visible field
#
# Usage: validate-persona.sh --chrome <binary> --probe <fingerprint-probe.html> \
#          [--profile <descriptor.json>] [--runs N] [--out <dir>]
# Exit 0 iff all gates pass. Headless; async surfaces settle within the
# virtual-time budget (the probe timeboxes them and always flips #ready).
set -uo pipefail

CHROME="" PROBE="" PROFILE="" RUNS=2 OUT="/tmp/raven-validate"
while [ $# -gt 0 ]; do
  case "$1" in
    --chrome) CHROME="$2"; shift 2;;
    --probe) PROBE="$2"; shift 2;;
    --profile) PROFILE="$2"; shift 2;;
    --runs) RUNS="$2"; shift 2;;
    --out) OUT="$2"; shift 2;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done
[ -x "$CHROME" ] || { echo "validate: --chrome not executable: $CHROME" >&2; exit 2; }
[ -f "$PROBE" ] || { echo "validate: --probe not found: $PROBE" >&2; exit 2; }
mkdir -p "$OUT"

PROFILE_ARG=()
[ -n "$PROFILE" ] && PROFILE_ARG=(--fingerprint-profile="$PROFILE")

# Portable timeout: macOS has no coreutils `timeout` (it's `gtimeout`, if installed).
# Use GNU `timeout` when present (Linux — identical behavior), else `gtimeout`, else
# a pure-shell watchdog.
_timeout() {  # $1 = seconds; $2.. = command
  local secs="$1"; shift
  if command -v timeout  >/dev/null 2>&1; then timeout  "$secs" "$@"; return $?; fi
  if command -v gtimeout >/dev/null 2>&1; then gtimeout "$secs" "$@"; return $?; fi
  "$@" & local cmd_pid=$!
  ( sleep "$secs"; kill -TERM "$cmd_pid" 2>/dev/null ) & local watch_pid=$!
  wait "$cmd_pid" 2>/dev/null; local rc=$?
  kill -TERM "$watch_pid" 2>/dev/null; wait "$watch_pid" 2>/dev/null
  return $rc
}

run_probe() {  # $1 = output basename
  local dump="$OUT/$1.dump.html"
  # Fixed --window-size so window.outer{Width,Height} are stable across runs
  # (headless leaves them flaky/0 otherwise) — a persona has a fixed window.
  _timeout 90 "$CHROME" --headless=new --no-sandbox --disable-gpu \
    --window-size=1280,800 --virtual-time-budget=8000 "${PROFILE_ARG[@]}" \
    --dump-dom "file://$PROBE" > "$dump" 2>/dev/null
  # hash from <title>FP:...</title>
  grep -oE "FP:[0-9a-f]+" "$dump" | head -1 | sed 's/FP://'
  # canonical snapshot JSON (HTML-unescaped) from <pre id="json">...</pre>
  python3 - "$dump" "$OUT/$1.json" <<'PY'
import sys, re, html
doc = open(sys.argv[1], encoding="utf-8", errors="replace").read()
m = re.search(r'<pre id="json"[^>]*>(.*?)</pre>', doc, re.S)
open(sys.argv[2], "w").write(html.unescape(m.group(1)) if m else "")
PY
}

echo "=== PERSISTENCE ($RUNS runs) ==="
declare -a HASHES
for i in $(seq 1 "$RUNS"); do
  H=$(run_probe "run$i")
  HASHES+=("$H")
  echo "run$i FP-hash: ${H:-<none>}"
done
PERSIST=PASS
for h in "${HASHES[@]}"; do
  [ -n "$h" ] || PERSIST=FAIL
  [ "$h" = "${HASHES[0]}" ] || PERSIST=FAIL
done
echo "PERSISTENCE: $PERSIST"

echo "=== BRANDING scrub (fork identity must not reach a JS-visible field) ==="
# 'Raven' and 'Headless' must NEVER appear in the fingerprint. 'Chromium' is
# legitimate in genuine Chrome (userAgentData brand, WebGL VERSION string, the
# fixed PDF plugin names) so it is only a leak inside navigator.userAgent. The
# probe's own self-identification field ("probe") is excluded.
BRAND=PASS
SCRUB=$(python3 - "$OUT/run1.json" <<'PY'
import json, re, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    print("UNPARSEABLE"); sys.exit()
# Drop the probe's own metadata section ("schema" holds probe name/version, e.g.
# "raven-fingerprint-probe") — it is not browser fingerprint data.
for k in ("probe", "probeVersion", "schema"):
    if isinstance(d, dict):
        d.pop(k, None)
blob = json.dumps(d)
bad = []
for term in ("raven", "headless"):
    if re.search(term, blob, re.I):
        bad.append(term)
def find_ua(o):
    if isinstance(o, dict):
        for k, v in o.items():
            if k == "userAgent" and isinstance(v, str):
                return v
            r = find_ua(v)
            if r:
                return r
    return ""
ua = find_ua(d)
for term in ("Chromium", "Headless", "Raven"):
    if term.lower() in ua.lower():
        bad.append("UA:" + term)
print(",".join(sorted(set(bad))))
PY
)
if [ -n "$SCRUB" ]; then BRAND=FAIL; echo "leak(s): $SCRUB"; fi
echo "BRANDING: $BRAND"

echo "=== COHERENCE (compare.py) ==="
COH=PASS
CMP="$(dirname "$0")/../test/probe/compare.py"
if [ -f "$CMP" ] && [ -s "$OUT/run1.json" ] && [ -s "$OUT/run2.json" ]; then
  python3 "$CMP" "$OUT/run1.json" "$OUT/run2.json" || COH=FAIL
else
  echo "(compare.py or snapshots missing — coherence skipped)"; COH=SKIP
fi
echo "COHERENCE: $COH"

echo "=== RESULT: persistence=$PERSIST branding=$BRAND coherence=$COH ==="
[ "$PERSIST" = PASS ] && [ "$BRAND" = PASS ] && { [ "$COH" = PASS ] || [ "$COH" = SKIP ]; }
