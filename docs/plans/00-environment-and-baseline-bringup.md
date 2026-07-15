# Plan 00 — Environment & Baseline Bring-up

**Goal:** a reproducible ungoogled-chromium-150 checkout that builds a vanilla `chrome` binary,
the two reference trees on disk, the repo skeleton from [README §4](README.md), and a CI path
that can compile. No spoofing yet — this is the platform everything else stands on.

**Exit criteria**
- [ ] `out/Default/Chromium` (or `.app`) launches from a clean pinned checkout on the dev machine.
- [ ] fingerprint-chromium 144 patch set + brave-core farbling files are vendored/readable.
- [ ] `patches/series` applies (empty/no-op is fine) via `build/apply-patches.sh`.
- [ ] CI compiles the vanilla tree (may be a long/nightly job).

---

## T0.1 — Provision the build host

Chromium build needs: ~100 GB free disk (150+ GB with `out/` and ccache), 16 GB+ RAM (32 GB
recommended), depot_tools, and platform SDKs. The dev machine here is **macOS arm64** (darwin
25.5). Primary dev target = macOS arm64; Linux x64 is the CI/reference target.

> **Persona ↔ host constraint (decided in review).** Cross-OS spoofing is out of scope for v1: a
> build can only present personas whose **OS and GPU class match the build/validation host**.
> Fonts (their *metrics*, not just names) and the WebGL parameter/extension set are host-derived
> and cannot be faithfully manufactured for a foreign OS/GPU (doc 03 §S9/§S4). **Consequence: one
> build + validation host per shipped OS** — a Linux CI runner cannot produce a valid Win11
> persona snapshot. Provision matching-OS runners (doc 04 T4.2, doc 05 T5.1).

1. Install depot_tools and put it on `PATH`:
   ```bash
   git clone https://chromium.googlesource.com/chromium/tools/depot_tools.git ~/depot_tools
   export PATH="$HOME/depot_tools:$PATH"   # persist in ~/.zshrc
   ```
2. macOS: install the matching Xcode + command-line tools that M150 requires (check
   `chromium/src/build/mac_toolchain` / the milestone's `//build/config/mac`). Chromium pins a
   specific Xcode; using a newer one can break the build — match the milestone.
3. Confirm `gclient`, `gn`, `autoninja`, `siso` resolve (`siso` is the default build executor in
   recent milestones; `autoninja` dispatches to it).

> **Decision to record now:** pick the build executor. Default to **`siso` local** for the dev
> box; wire **reclient/RBE or a distributed cache** only if iteration time hurts (spec §7.6).
> Note this in `build/README.md`.

## T0.2 — Pin the base tree (spec §7.1, decision §11.4)

Base is **ungoogled-chromium-150**, synced to its `150.x.y.z-1` tag. Two supported acquisition
paths — implement **both** in `build/sync.sh` behind a flag:

- **Path A — gclient checkout (dev iteration, recommended for engineers).** Full git history,
  fast incremental rebuilds.
  1. `fetch --nohooks chromium`, then `cd src && git checkout <chromium-tag-that-ug-150-targets>`.
  2. `gclient sync -D --with_branch_heads --with_tags` at that revision.
  3. Apply the ungoogled-chromium patch series (their `utils/patches.py apply` or `quilt`) from
     the pinned ungoogled-150 tag. This gives the `components/ungoogled/ungoogled_switches`
     infra that our patch `000` extends, the privacy hardening, and the existing WebRTC
     IP-handling patches the hard-disable builds on (spec §7.1).
- **Path B — ungoogled source tarball (reproducible CI).** Download ungoogled-chromium-150's
  prepared tarball + run their `build.py`/patch step. Deterministic, no `gclient`. Use for the
  release/regression jobs.

**Pinning:** record the exact `(chromium_tag, ungoogled_tag)` pair in `build/PINS` (a checked-in
file). Every plan below assumes this pin. If the ungoogled 150 tag lags upstream, pin to the
latest available ungoogled-150 revision rather than jumping to raw Chromium (spec §7.1).

`build/sync.sh` responsibilities:
```
sync.sh --mode gclient|tarball
  → read build/PINS
  → fetch/checkout Chromium at chromium_tag
  → apply ungoogled series (ungoogled_tag)
  → leave a clean tree ready for build/apply-patches.sh
```

## T0.3 — First vanilla build (baseline sanity)

1. Create `build/args/common.gni` from the ungoogled `flags.gn` (spec §7.6) plus dev toggles:
   ```gn
   # build/args/common.gni  (imported by per-platform files)
   is_debug = false
   is_component_build = false        # release-like; component build is faster for iteration
   symbol_level = 1                  # 0 for fastest link during bring-up
   blink_symbol_level = 0
   dcheck_always_on = true           # keep DCHECKs during development
   # ... paste ungoogled flags.gn contents here ...
   ```
   `build/args/macos-arm64.gn`:
   ```gn
   import("//../build/args/common.gni")   # (adjust path; or inline)
   target_cpu = "arm64"
   ```
   Provide `linux-x64.gn` and `win-x64.gn` stubs for CI/release later.
2. `build/gen-and-build.sh`:
   ```bash
   gn gen out/Default --args="$(cat build/args/${PLATFORM}.gn)"
   autoninja -C out/Default chrome
   ```
3. Launch it. Confirm it runs and reports a normal Chrome UA. **Record the build wall-clock** —
   this sets iteration expectations for everyone (expect multi-hour cold, minutes-to-tens warm).

> Keep a warm `out/Default` and ccache/siso cache. Cold rebuilds are the tax; incremental
> Blink edits are cheap.

## T0.4 — Vendor the reference trees (spec §2.2, §12)

These are **read-only references**, not build inputs (except the one lifted header in doc 02).
Put them outside the Chromium `src/` so `gclient` never touches them. Suggested: a sibling
`references/` dir (git-ignored or a separate clone), with paths recorded in `docs/plans`.

1. **fingerprint-chromium 144** — the persistence baseline. Get
   `ungoogled-chromium 144.0.7559.132` + `patches/extra/fingerprint/` (16 patches, spec §3.2).
   This is the literal source for doc 01's rebase.
   ```
   references/fingerprint-chromium-144.0.7559.132/patches/extra/fingerprint/
   ```
2. **brave-core** — coverage/quality reference (spec §4, §12). We read, and lift exactly one file
   in doc 02:
   - `components/brave_shields/core/common/farbling_prng.h`  ← lifted in 02 (MPL header kept)
   - `third_party/blink/renderer/core/farbling/brave_session_cache.{h,cc}`  ← read for mechanisms
   - `browser/farbling/*` browsertests  ← the surface checklist + expected shapes
3. Optional references worth a shallow clone: **Cromite** (clean canvas/rects `.patch` series),
   **Camoufox** (design notes, Firefox — not Chromium).

Write `references/README.md` listing each tree, its upstream URL, the exact tag/commit, and
"what we use it for" so nobody treats a reference as a dependency.

## T0.5 — Lay down the repo skeleton (README §4)

Create the directory tree from [README §4](README.md) with placeholder/committed files:
- `patches/series` — empty to start (ungoogled series is applied by `sync.sh`; ours appended by
  `apply-patches.sh`).
- `build/apply-patches.sh` — reads `patches/series`, applies each `patches/**/<name>.patch` with
  `git apply --3way` (or `quilt push`), stops on first reject with a clear message.
- `profile-db/schema/` , `profile-db/fixtures/` , `test/probe/` , `test/snapshots/` , `ci/` —
  empty with `.gitkeep` + a one-line README each.
- `third_party/lifted/README.md` — provenance ledger (starts empty).

`apply-patches.sh` contract (used by every later doc):
```bash
# after sync.sh has produced a patched ungoogled tree in $CHROMIUM_SRC
apply-patches.sh
  → for name in $(grep -v '^#' patches/series); do
        git -C "$CHROMIUM_SRC" apply --3way "$REPO/patches/**/$name" || fail loudly
    done
```

## T0.6 — Minimal CI that compiles (spec §7.6)

Reuse the baseline's `.cirrus.yml` path (fingerprint-chromium ships one) or GitHub Actions.
For bring-up, one job is enough:

- **`build-linux`** (Path B tarball, reproducible): `sync.sh --mode tarball` →
  `apply-patches.sh` → `gen-and-build.sh` for `linux-x64`. Cache `out/` + siso cache between
  runs. This job stays as the compile gate for every later patch.

Defer per-OS release jobs and the regression/coherence jobs to docs 04–05. Get *one* green
compile of the vanilla + empty-series tree first.

---

## Risks specific to this phase

- **Toolchain drift** — wrong Xcode/SDK vs. the milestone is the #1 first-build failure. Match
  the pin exactly.
- **Disk** — `gclient sync` + `out/` + caches blow past 100 GB fast. Provision 200 GB.
- **ungoogled tag lag** — if ungoogled-150 isn't cut yet at start, pin the latest ungoogled-150
  RC/revision and record it; do not silently start from raw Chromium (spec §7.1).

## Handoff to doc 01

You now have: a pinned, building 150 tree; the 144 patch set to rebase; `apply-patches.sh`; a
compile CI. Doc 01 walks the 16 baseline patches onto this tree.
