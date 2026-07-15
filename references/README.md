# references/ — READ-ONLY reference trees (NOT build inputs)

Vendored per Plan 00 / T0.4. These are read for rebasing and mechanism study. Keep them OUTSIDE
the chromium `src/` so `gclient` never touches them. The one file we actually *lift* into the
build (Brave's `farbling_prng.h`) is copied into `third_party/lifted/` in Plan 02 with its MPL-2.0
header kept — see [`../third_party/lifted/README.md`](../third_party/lifted/README.md).

On the build hosts these live in `$HOME/references/`; only this ledger is committed.

| Tree | Upstream | Pin (vendored 2026-07-14 on `raven:~/references/`) | What we use it for |
|---|---|---|---|
| **fingerprint-chromium 144** | github.com/adryfish/fingerprint-chromium | tag **`144.0.7559.132`** (commit `831623f2`) | The persistence baseline; **Plan 01 rebase source**. 16 patches at `patches/extra/fingerprint/` (000–018) + 2 bromite patches (`patches/extra/bromite/…client-rects-and-measuretext`, `…canvas-image-data-noise`). NOTE: 148 source is unreleased (ships only after 149); the repo's `148` tag has **0 patches** — do not use it (see memory `fp-148-improvements-to-adopt`). |
| **brave-core** | github.com/brave/brave-core | commit **`d1ce6ee2`** (v**1.94.64**, shallow) | Coverage/quality reference (spec §4). Lift `components/brave_shields/core/common/farbling_prng.h` (Plan 02); read `third_party/blink/renderer/core/farbling/brave_session_cache.{h,cc}` + `browser/farbling/*` (20 browsertests) for mechanisms + expected shapes. |
| **Cromite** (optional) | github.com/uazo/cromite | not yet vendored | Clean canvas/rects `.patch` series (spec §2.2). |
| **Camoufox** (optional) | github.com/daijro/camoufox | not yet vendored | Anti-detect design notes (Firefox — not Chromium). |

**VERIFY@150 (2026-07-14):** all 16 baseline patches' Chromium target files exist at the same paths
in the 150 tree — no relocations. Only `011-gpu-info` references `components/ungoogled/fingerprint_data.h`,
a fingerprint-chromium-*created* helper (not a moved Chromium path). Rebase = hunk-level work.
