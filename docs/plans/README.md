# Raven Chromium — Implementation Plans

Detailed, buildable implementation plans derived from
[`../chromium-fingerprint-build-spec.md`](../chromium-fingerprint-build-spec.md) (spec v1.1).

Read the spec first. These documents translate the spec's decisions (§11) and target
architecture (§6) into ordered engineering work with per-task instructions, file targets,
code sketches, and acceptance criteria.

---

## 0. What we are building (one paragraph)

An open-source Chromium fork (target **milestone 150**, base **ungoogled-chromium-150**) that
reads a **per-profile JSON identity descriptor** at launch and reports a **persistent, coherent
synthetic device fingerprint** natively from the C++ engine. It combines fingerprint-chromium's
*persistence model* (one seed → deterministic values, stable across restarts) with Brave's
farbling *coverage and value-plausibility* (strong PRNG, broad surface set), re-pointed from
Brave's per-session random seed to our persistent profile seed. The running browser identifies
as **real Chrome**; the "Raven" name never leaves the repo/CLI.

---

## 1. Plan documents (read in order)

| # | Document | Deliverable | Depends on |
|---|---|---|---|
| 00 | [Environment & baseline bring-up](00-environment-and-baseline-bringup.md) | Reproducible checkout + first vanilla build + reference trees + repo skeleton + CI | — |
| 01 | [Rebase the 16 baseline patches 144 → 150](01-rebase-baseline-16-patches.md) | The existing fingerprint-chromium patch set applies cleanly on 150 and builds | 00 |
| 02 | [Core architecture: PRNG, keyed seed, descriptor, DB](02-core-architecture-prng-seed-descriptor-db.md) | `randen_engine` PRNG, keyed per-surface seed derivation, `--fingerprint-profile` JSON descriptor plumbed browser→renderer, profile-DB schema + CI validator | 01 |
| 03 | [New surface patches](03-new-surface-patches.md) | 12 new spoofing surfaces (11 from spec §6.3 + geolocation), highest-value first | 02 |
| 04 | [Validation & regression harness](04-validation-and-regression.md) | Persistence / coverage / **coherence** tests + snapshot CI that survives rebases | 01 (grows through 03) |
| 05 | [Packaging & release contract](05-packaging-and-release-contract.md) | Signed per-OS binaries + versioned launch/descriptor contract to Raven Browser | 03, 04 |

Do **not** start 02 before 01 is green (you need a building 150 tree with the baseline
semantics before you refactor them). 03 surfaces can be parallelized once 02 lands. 04 should be
stood up early (right after 01) and grown continuously — it is the project's safety net.

---

## 2. Dependency / critical path

```
00 env+baseline ─► 01 rebase 16 ─► 02 core arch ─► 03 new surfaces ─► 05 package
                        │                                   ▲
                        └────────► 04 validation harness ───┘  (built early, grows continuously)
```

Critical path is **00 → 01 → 02 → 03 → 05**. 04 runs alongside from the end of 01.
The dominant *ongoing* cost after v1 is re-running 01 every Chromium milestone (spec §9).

---

## 3. Rough effort (calibrate after 00–01 land)

T-shirt sizes, one engineer familiar with Chromium build + Blink. Not commitments.

| Workstream | Size | Notes |
|---|---|---|
| 00 Environment & baseline | M (1–2 wk) | First full build dominates wall-clock, not effort. |
| 01 Rebase 16 patches | L (2–4 wk) | Churn-driven; canvas/webgl/v8-inspector files move most (spec §7.2). |
| 02 Core architecture | L (2–3 wk) | Descriptor plumbing + DB validator are the substance. |
| 03 New surfaces (×11) | XL (4–8 wk) | ~2–5 days each; fonts + WebGPU are the hard ones. |
| 04 Validation harness | M (1–2 wk) then ongoing | Coherence loop (CreepJS) is iterative. |
| 05 Packaging | M (1–2 wk) | Signing/notarization setup is the long pole. |

---

## 4. Repo layout (established in 00, referenced everywhere)

```
Raven-Chromium/
├── build/
│   ├── sync.sh                 # pin + fetch Chromium, apply ungoogled series
│   ├── apply-patches.sh        # apply our patches/series on top
│   ├── args/                   # gn arg files: common.gni + per-platform
│   └── gen-and-build.sh
├── patches/
│   ├── series                  # ordered: (ungoogled) + core/ + fingerprint/
│   ├── core/                   # 1xx: architecture (prng, seed, descriptor)
│   └── fingerprint/            # 0xx rebased baseline + 2xx new surfaces
├── third_party/lifted/
│   └── farbling_prng.h         # lifted from brave-core, MPL-2.0 header kept
├── profile-db/
│   ├── schema/descriptor.schema.json
│   ├── fixtures/               # PUBLIC sample profiles only
│   └── validate.py             # schema + cross-axis coherence checks (CI)
├── test/
│   ├── probe/                  # fingerprint probe page + driver
│   └── snapshots/              # per-profile expected outputs (regression)
├── ci/                         # .cirrus.yml / GH Actions + regression jobs
└── docs/
    ├── chromium-fingerprint-build-spec.md
    └── plans/                  # you are here
```

The **real-device DB stays proprietary in Raven Browser** (README, spec §11.2). This repo ships
only the *schema*, the *validator*, and a few *public fixtures* for tests.

---

## 5. Conventions used across all plans

- **`VERIFY@150`** — a file path or API taken from the 144 tree that **must be re-checked against
  the 150 source** before coding. The spec's §6.3 table is 144-relative; treat every path as
  `VERIFY@150` unless this plan says it was confirmed. The verification step is part of each task,
  not a separate phase.
- **Patch numbering** — baseline keeps its `000–018` numbers (spec §3.2). Core-architecture
  patches are `1xx` under `patches/core/`. New surfaces are `2xx` under `patches/fingerprint/`.
  `patches/series` is the single source of truth for order.
- **MPL provenance** — any file lifted from brave-core (e.g. `farbling_prng.h`) keeps its
  **MPL-2.0 header verbatim**; do not relicense (spec §6.1, README license note). Track lifted
  files in `third_party/lifted/README.md` with upstream path + commit.
- **One source of truth per axis** — JS-visible value and its network/header twin (languages ↔
  Accept-Language, UA ↔ Client Hints) must derive from the **same descriptor field**, never
  computed twice. Coherence bugs come from double-derivation (spec §6.2, §9).
- **Determinism rule** — never seed spoofing from anything non-reproducible. Banned in derivation
  paths: `absl::Hash` (intentionally randomized per process — will break persistence),
  `base::RandUint64`, `Time::Now`, raw `std::hash` as the *randomness source*. Use the keyed
  SipHash → `randen_engine` chain from doc 02.
- **Host-OS/GPU constraint** — a persona's `os` and `gpu` class **must match the build/validation
  host** (decided in review). Fonts (metrics) and the WebGL parameter/extension set are
  host-derived and can't be manufactured cross-OS, so cross-OS personas are out of scope for v1;
  each shipped OS is built + validated on a matching-OS host (docs 00, 03 §S4/§S9, 04, 05).
- **Every patch is self-describing** — top-of-patch comment: purpose, spec §, switch(es) added,
  descriptor field(s) read, coherence constraints, VERIFY@150 targets.

---

## 6. Definition of done (v1)

A profile passes when, per spec §8:

1. **Persistence** — same descriptor across restarts → byte-identical probe output.
2. **Coverage** — every surface in spec §6.3 responds to the descriptor (no dead switches).
3. **Coherence** — CreepJS "lies"/entropy detector flags **zero** internal contradictions.
4. **Regression** — snapshot CI green; rebamp after any Chromium bump re-greens without drift.

Ship gate for v1 = N curated real-device profiles (count set in 02) each passing 1–4.
