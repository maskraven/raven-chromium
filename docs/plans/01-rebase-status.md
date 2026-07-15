# Plan 01 — Rebase status (VERIFY@150 results, 2026-07-14)

19 fp-chromium 144 patches analyzed against live ungoogled-150 (workflow `wf_36c079fd-141`,
19/19 agents, 0 errors). Per-patch reports: `$CLAUDE_JOB_DIR/tmp/plan01-verify/<patch>.md`
(each has the actual 150 code + pre-drafted rebased hunks for every conflicting hunk).

## Categorization
**CLEAN — apply as-is (context verbatim, offset-tolerant) — 7**
`000-add-fingerprint-switches`, `001-disable-runtime-enable`, `005-hardware-concurrency`,
`009-webdriver`, `010-headless`, `011-gpu-info`, `018-timezone`

**NEEDS-REBASE — partial conflicts, fixes pre-drafted — 10**
| patch | reject hunks | cause (144→150 drift) |
|---|---|---|
| `002-user-agent-fingerprint` | 7/19 | GetUserAgentInternal/GetUnifiedPlatform refactor (CRITICAL — UA/CH coherence) |
| `b02-max-connections-per-host` | 3/10 | NORMAL_SOCKET_POOL→SocketPoolType::kNormal; ApplyMetricsReportingPolicy→metrics ns; histogram_macros.h removed |
| `014-client-rects` | 3/13 | document.cc include-block + TRACE_EVENT drift; element.cc include drift |
| `012-canvas-get-image-data` | 2/9 | base_rendering_context_2d.cc new record_paint_canvas.h include; static_bitmap_image.cc switch rewrite |
| `016-webgl-readPixels` | 2/4 | (hunks 3-4 load-bearing body are CLEAN; 1-2 header drift) |
| `003-audio-fingerprint` | 1/3 | hunk-2 leading anchor reformatted upstream |
| `006-font-fingerprint` | 1/3 | 150 inserted byte_size.h + safe_conversions.h into the include block |
| `007-shadow-root` | 1/3 | element.h GetShadowRoot() refactor |
| `013-canvas-toDataURL` | 1/3 | hunk-2 trailing ctx (ukm_recorder.h reorder) |
| `015-canvas-measure-text` | 1/1 | 150 gates measureText shuffle on runtime-feature, not the cmdline gate the patch expects |

**REDUNDANT — DROP (already byte-for-byte in ungoogled-150) — 2**
`b01-clientrects-measuretext-flags` (= upstream ungoogled PR #377), `b03-canvas-image-data-noise`.
Files kept under `patches/fingerprint/` for provenance; removed from `patches/series`.

**Final Plan 01 series = 17 patches** (`b02` + 16 fingerprint).

## Two load-bearing technical findings
1. **No 3-way fallback.** `git apply --3way` needs the patch's 144 base-blob SHAs in the 150 object
   DB to merge; they're absent (different milestone) and the bromite patches have no `index` lines
   at all. So `--3way` degrades to offset-tolerant straight apply — CLEAN/OFFSET hunks land, but any
   context-CHANGED hunk hard-rejects. This is why the 10 need manual (drafted) fixes.
2. **ungoogled-150 natively carries the bromite noise infra** (client-rects, measuretext, canvas
   image-data) on `base::RandDouble`. COHERENCE REQUIREMENT for Plan 02/03: our deterministic
   SipHash→randen path must *supersede/control* this native random noise, not run alongside it
   (else canvas/rects get double-perturbed with one random + one deterministic layer). Track when
   wiring canvas (012/013), client-rects (014), measure-text (015) surfaces.

## Post-build rebase procedure (execute once BUILD_EXIT lands & tree is free)
Sequential series-rebase in the freed checkout (patches share files: base_rendering_context_2d.cc ×3,
element.cc ×2 — so cumulative order matters; independent worktrees would drift):
1. On `~/chromium/src`, commit the ungoogled-150 working tree as baseline: branch `raven-base`,
   `git add -A && git commit`. (Working-tree files unchanged → out/Default stays valid for incremental.)
2. Branch `raven-patched`. For each patch in `patches/series` order:
   `git apply --reject <patch>` → resolve any `.rej` using that patch's verify report drafted hunks →
   `git add -A && git commit -m "<patch>"` → export rebased patch back to `patches/fingerprint/<name>`
   via `git format-patch -1 --stdout` (now applies clean by construction on `raven-base`).
3. Re-run `build/apply-patches.sh` from a clean `raven-base` to confirm the whole series applies clean.
4. **Build incrementally after each churny/critical patch** (compile-verify individually):
   `002` (UA), `011` (gpu), `012`/`013`/`015` (canvas), `014` (rects), `016` (webgl), `003` (audio).
5. Keep provenance: `patches/fingerprint/` files are the rebased-onto-150 versions after this pass.

## Execution result (2026-07-14) — DONE
Sequential rebase executed on `raven` (branch `raven-patched` off committed `raven-base` baseline).
**Outcome: 8 CLEAN, 8 FIXED (all from the VERIFY@150 drafted hunks — no invented code), 3 DROPPED, 0 FAILED.**
- **All 3 bromite patches dropped as redundant** (b02 joined b01/b03 — its additions incl. the
  `browser_process_impl.cc SocketPoolType::kNormal` block are already in ungoogled-150). **Final
  series = 16 fingerprint patches** (000–018).
- FIXED: 002 (6 hunks — UA refactor), 003, 006, 007, 012 (`RandInt`→`RandIntInclusive` API rename +
  include), 013, 014 (3), 016. All regenerated as line-exact 150 diffs in `patches/fingerprint/`.
- **Patch 001 targets the v8 submodule** (`v8/src/inspector/…`, a gitlink). `git apply --3way` can't
  write submodule paths → `apply-patches.sh` fixed to fall back to plain `git apply` (the other 15
  apply via `--3way`). Verified: all 16 apply clean from `raven-base`.
- Compile-verify: incremental build of `raven-patched` launched (`~/build-plan01.log`, sentinel).
