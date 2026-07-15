# Plan 02 — Core Architecture: PRNG, Keyed Seed, Descriptor, Profile DB

**Goal:** replace the baseline's weak, per-surface-independent derivation with the spec's target
architecture (§6): one **profile descriptor** → **keyed per-surface seed** → **`randen_engine`
PRNG** → **shape-preserving value**, cached for process lifetime. After this doc, every existing
patch derives from the descriptor via one shared helper, and new surfaces (doc 03) plug into the
same helper. This is the substitution that turns "randomize-to-hide" into "fix-to-impersonate"
(spec §5).

**Exit criteria**
- [ ] `farbling_prng.h` lifted from brave-core (MPL header kept) and compiling in-tree.
- [ ] A shared `fingerprint::SurfacePrng(descriptor, "surface_tag")` helper: deterministic keyed
      SipHash → `randen_engine`, with a compile-time-checked list of surface tags.
- [ ] `--fingerprint-profile=<path>` parsed + schema-validated in the **browser** process, the
      resolved descriptor propagated to **every renderer** (sandbox-safe), and exposed as a
      process-global `fingerprint::Profile::Get()`.
- [ ] Baseline patches (doc 01) refactored to read the descriptor + use `SurfacePrng` instead of
      `std::hash & 1` / hardcoded constants. Persistence still byte-identical.
- [ ] `profile-db/schema/descriptor.schema.json` + `profile-db/validate.py` (schema + cross-axis
      coherence) wired into CI.

Patches produced here live in `patches/core/` (numbered `1xx`) and are inserted in
`patches/series` **before** the `fingerprint/` surface patches.

---

## Design recap (spec §6.1–6.2)

```
profile.json  ──parse+validate (browser)──►  Profile (immutable struct)
                                              │  propagate to renderers (b64 switch)
                                              ▼
per surface:  surface_seed = SipHash(key=key128(profile.seed), msg="webgpu")   // deterministic
              FarblingPRNG prng(surface_seed)                                   // Brave's randen
              value = generate_plausible_value(prng, profile.<field>)          // Brave-style
              // computed once, cached for process lifetime
```

- **Identity axes** (os, gpu, locale, screen, …) come **from descriptor fields** and must co-vary
  like a real device — they are *not* independently hashed from the seed (spec §6.2).
- **The seed** drives only **within-profile jitter** (canvas LSB noise, device counts) — the part
  that's allowed to vary and still look like the same machine.

---

## T2.1 — Lift Brave's PRNG (spec §6.1 upgrade 1)

Patch `patches/core/100-lift-farbling-prng.patch`.

1. Copy `components/brave_shields/core/common/farbling_prng.h` from the brave-core reference into
   `third_party/lifted/farbling_prng.h`. **Keep the MPL-2.0 header verbatim** (README §5).
   Record provenance in `third_party/lifted/README.md` (upstream path + brave-core commit).
2. It's a thin wrapper over `absl::random_internal::randen_engine<uint64_t>` (AES-based,
   cryptographically strong, statistically uniform — spec §4). abseil is already vendored at
   `//third_party/abseil-cpp`; no new third-party *source*, but **not dependency-free**: pulling
   in `//third_party/abseil-cpp:random` (specifically `absl/random/internal`) will likely trip
   Chromium's `checkdeps` / abseil include-rule restrictions — budget DEPS + `BUILD.gn` allowlist
   work here; brave-core carries exactly such a patch, use it as the reference.
3. Add a `BUILD.gn` target (or fold the header into an existing Blink `source_set` visible to both
   `//content/browser` and `//third_party/blink/renderer`). `VERIFY@150`: pick a target both
   process sides can depend on.

> Why lift Brave's wrapper instead of using abseil directly: it gives a stable `FarblingPRNG`
> type + `uint64_t` seeding + `result_type` API, and documents provenance. Using
> `absl::random_internal` raw is allowed but the wrapper is the reference the spec names.

## T2.2 — Deterministic keyed per-surface seed (spec §6.1)

Patch `patches/core/101-keyed-seed-derivation.patch`. New helper
`third_party/blink/renderer/platform/fingerprint/surface_prng.{h,cc}` (or a `//components`
location if browser-side derivation is also needed — see T2.4).

**Requirements**
- Deterministic across processes, builds, and restarts (persistence, spec §8.1). The **integer
  PRNG stream** is also identical across OS/arch; **float-derived observables (canvas/audio
  noise) may diverge across arch** (FMA contraction, SSE vs NEON). Keep derivation in integer
  math where possible, and scope persistence snapshots **per-platform** (doc 04) — acceptable
  because personas are host-OS-constrained anyway (README).
- Keyed by the profile seed; different `surface_tag` → statistically independent stream.
- Not `std::hash` (weak, spec §3.3) and **not `absl::Hash`** (intentionally per-process
  randomized — would silently break persistence; README §5 determinism rule).

**Implementation** — vendor a small public-domain **SipHash-2-4** (≈80 lines, deterministic,
keyed) as the mixing function, then seed `randen_engine`:

```cpp
// surface_prng.h  (sketch)
namespace fingerprint {

// Compile-time list of every surface tag so a typo can't create a silent new stream.
enum class Surface {
  kCanvas, kWebglReadPixels, kAudio, kClientRects, kMeasureText,
  kHardwareConcurrency, kMediaDevices, kSpeechVoices, kWebGpu, kFonts, /*…*/ kMaxValue
};
const char* SurfaceTag(Surface s);   // "canvas", "webgl_readpixels", …

// key128 = splitmix64-expand(profile_seed) → 128-bit SipHash key (fixed algorithm).
// surface_seed = SipHash24(key128, SurfaceTag(s))   → uint64_t
FarblingPRNG SurfacePrng(uint64_t profile_seed, Surface s);

}  // namespace fingerprint
```

- `key128`: expand the 64-bit `profile.seed` to a 128-bit key with two `splitmix64` steps (fixed
  constants). Deterministic, no dependency.
- `SurfacePrng`: `FarblingPRNG(SipHash24(key128, tag))`. Callers pull `prng()` for uniform
  `uint64_t`; provide Brave-style helpers on top (T2.3).
- **Unit test** (`surface_prng_unittest.cc`): golden vectors — fixed `(seed, surface)` → fixed
  first N outputs, checked in. This test *is* the persistence contract at the unit level; if it
  changes, persistence broke.

## T2.3 — Port Brave's value-generation helpers (spec §4 mechanisms)

Same patch or a sibling. Port (adapting from `brave_session_cache.cc`, MPL provenance in headers)
the shape-preserving generators the surfaces need:

- `PerturbPixels(prng, pixels, …)` — broad LSB canvas noise (generalizes baseline 012/013/016).
- `FarbleAudioChannel(prng, …)` — per-stream fudge-factor ≈1.0 multiplier (audio).
- `FarbleInteger(prng, real, min, max)` — shape-preserving integer jitter (device counts, etc.).
- `AllowFontFamily(...)` — font allowlist predicate (doc 03 fonts).

These wrap `FarblingPRNG`, so re-pointing Brave's per-session seed to our persistent
`SurfacePrng` is the *only* change from Brave's semantics (spec §5).

## T2.4 — The profile descriptor: parse, validate, propagate (spec §6.2, decision §11.1)

The load-bearing piece. Patch `patches/core/102-fingerprint-profile-descriptor.patch`
(+ `103-profile-propagation-renderer.patch` if you split browser/renderer).

### Data model
`fingerprint::Profile` — an immutable struct mirroring the JSON (spec §6.2 example):
```
seed:uint64, os, platform, chromeMajor,
gpu{vendor,renderer,architecture,device}, locale, languages[], timezone,
screen{w,h,dpr,colorDepth,pixelDepth,availW,availH}, hardwareConcurrency, deviceMemory, …
```
Ship a versioned `schemaVersion` field. Keep a canonical **default** (a real-device fixture) used
when no `--fingerprint-profile` is passed, so the browser is never in an undefined state.

### Browser side (parse + validate)
1. Register `--fingerprint-profile=<path>` in `ungoogled_switches.*` (extends baseline `000`).
2. At browser startup (where switches are first read — `ChromeMainDelegate` /
   `ChromeContentBrowserClient` init; `VERIFY@150`), read the file with **`base::JSONReader`**
   (`//base/json`), map to `fingerprint::Profile`, and **validate** (see T2.6 checks mirrored in
   C++: required fields present, `availW ≤ w`, `languages[0]` matches `locale`, etc.). On invalid
   → fail fast with a clear log line (don't silently run a broken identity).
3. Keep the thin `--fingerprint*` / `--timezone` switches as **per-field overrides** applied
   *after* the JSON (decision §11.1) — for quick testing. Override precedence:
   `default < json < individual switch`.

### Renderer side (sandbox-safe propagation) — the critical detail
**Renderers are sandboxed and cannot open the JSON file.** So the browser must serialize the
*resolved* descriptor and hand it to each child over the command line:
1. In `RenderProcessHostImpl` where child cmdline is assembled (the same site baseline `000`
   patches; `VERIFY@150`), append `--fingerprint-profile-data=<base64(compact-json)>`.
2. In the renderer, decode + parse **once** with `base::JSONReader`, build the same
   `fingerprint::Profile`, and store it in a **process-global singleton**:
   ```cpp
   const fingerprint::Profile& fingerprint::Profile::Get();  // renderer: lazy-init from switch
   ```
   Every surface patch reads fields from `Profile::Get()`; every jitter uses
   `SurfacePrng(Profile::Get().seed, Surface::kX)`.

> Why the b64-blob switch (not N individual switches, not a file path to the renderer): one atomic
> object, no per-field switch sprawl, sandbox-safe (cmdline is readable by the renderer), and it
> matches the spec's open question favorably ("temp file at launch" resolves to "browser reads the
> file, renderer reads the cmdline"). Command-line length is ample for this payload.

### Coherence guard-rail
`Profile` construction is the **single derivation point** for identity axes. Surfaces must read
`Profile::Get().languages`, never re-derive languages from the seed. This is how §6.2's "do not
derive identity axes independently" is enforced structurally.

## T2.5 — Refactor baseline patches onto the new core

Update the doc-01 patches in place (their diffs now sit *after* `patches/core/*` in the series):
- `002 user-agent` → read `os/platform/chromeMajor/brand` from `Profile`. The UA string,
  `navigator.userAgentData.getHighEntropyValues()`, **and** the HTTP Client-Hint *request headers*
  (`Sec-CH-UA-Platform-Version`, `-Arch`, `-Bitness`, `-Model`, `-Full-Version-List`, assembled
  browser/network-side via `//components/client_hints`) must all derive from the *same* descriptor
  fields. Give UA-CH the same JS↔header dual-consumer discipline as languages↔Accept-Language
  (T2.5) — otherwise `userAgentData` vs. the CH headers is a UA-vs-hints lie.
- `003 audio` → pick **one** observable, don't blindly do both: keep the baseline
  `sampleRate`/`frameCount` noise **or** switch to `FarbleAudioChannel(SurfacePrng(seed, kAudio),
  …)` (PCM-buffer noise). They're different hooks; the standard audio-fingerprint test hashes the
  *rendered buffer*, so `FarbleAudioChannel` is the higher-fidelity target. Reconcile with doc 01
  §003.
- `005 hardware-concurrency` → `Profile.hardwareConcurrency`; **`deviceMemory` from
  `Profile.deviceMemory`** (removes the hardcoded 8, spec §3.2 gap).
- `011 gpu-info` → WebGL unmasked strings from `Profile.gpu` (sets up WebGPU coherence, doc 03).
- `012/013/015/016 canvas/webgl` → `PerturbPixels(SurfacePrng(seed, kCanvas/kWebgl…), …)`.
- `014 client-rects` → `SurfacePrng(seed, kClientRects)`.
- `018 timezone` → default from `Profile.timezone`; `--timezone` still overrides.

**Persistence must remain byte-identical for a fixed descriptor** (re-run doc 01's smoke test).
The *values* change vs. the old `std::hash` build (expected — new PRNG); persistence and
coherence are what must hold.

## T2.6 — Profile DB: schema + CI validator (spec §6.2, decision §11.2)

The DB is **curated real captured devices**, versioned separately; the **real records stay
proprietary in Raven Browser**. This repo ships the *contract*: schema + validator + public
fixtures.

1. `profile-db/schema/descriptor.schema.json` — JSON Schema (draft 2020-12) for the descriptor:
   field names, types, required set, `schemaVersion`, enums for `platform`/`os`. This schema is
   the versioned public interface Raven Browser writes against.
2. `profile-db/validate.py` — runs in CI over any JSON in `profile-db/fixtures/` (and, in the
   Raven Browser CI, over the real DB). Two layers:
   - **Schema** validation (`jsonschema`). *(Uses Python — activate the repo venv per the user's
     global rule before running: `source .venv/bin/activate`.)*
   - **Cross-axis coherence** checks — the anti-CreepJS rules (spec §6.2, §8.3):
     - `screen.availW ≤ screen.w`, `availH ≤ h`; `colorDepth == pixelDepth ∈ {24,30}`.
     - `dpr ∈ {1,1.25,1.5,2,…}` and plausible for `os` (e.g. mac Retina ⇒ 2).
     - `gpu.vendor`/`renderer` string ↔ `os` (no "Apple GPU" on `Win32`).
     - `languages[0]` startswith `locale`; `timezone` in the locale's plausible set.
     - `hardwareConcurrency` even & in a real range; `deviceMemory ∈ {4, 8}` — Chrome clamps
       `navigator.deviceMemory` to a **max of 8** (`blink::ApproximatedDeviceMemory`; the buckets
       are `{0.25,0.5,1,2,4,8}`). **Never `>8`** — that's why the baseline hardcodes 8 (spec §3.2);
       `16` is an instant CreepJS lie.
     - `platform` **exact**: Windows ⇒ `"Win32"`, macOS ⇒ `"MacIntel"` (**even on Apple Silicon** —
       Chrome never reports an `"arm"` platform string), Linux ⇒ `"Linux x86_64"`. Must match `os`.
     - **host-OS/GPU match** (README constraint): the persona's `os` and `gpu` class must equal the
       validation host's. Give `validate.py` an optional `--host-os`/`--host-gpu-class` and, in CI,
       assert every fixture matches the runner — a Win11 persona validated on a Linux/mac host is
       rejected (its font metrics + WebGL params would be the host's, not the persona's).
   - Fail CI on any violation. This validator is the mechanical guard for the "coherence debt"
     risk (spec §9); the real test is CreepJS (doc 04).
3. `profile-db/fixtures/` — 2–3 **public** sample real-device profiles (Win11+NVIDIA+en-US,
   macOS-arm+Apple+en-US, etc.) used by unit/regression tests. Not the shipping DB.

> **Open items to close here** (spec §11 "still open"): finalize the JSON field names/versioning
> *with the first `000`/`102` patch*; decide DB sourcing + v1 profile count (record in
> `profile-db/README.md`); confirm the descriptor reaches the browser as a temp file at launch
> (matches T2.4). Surface these to the product owner if not obvious.

---

## Definition of done

- `patches/core/100–103` in `patches/series` before `fingerprint/*`; tree builds + runs.
- `SurfacePrng` golden-vector unit test green (persistence at unit level).
- A descriptor JSON drives UA/GPU/tz/hardware/canvas; **`deviceMemory` no longer hardcoded**.
- Sandboxed renderers get the identity via the b64 switch (verify: renderer with sandbox on still
  spoofs).
- `validate.py` green on fixtures, red on a deliberately contradictory fixture (add one as a
  negative test), wired into CI.

## Handoff to doc 03

Surfaces now share one derivation spine: read `Profile::Get()` for identity, `SurfacePrng(seed,
Surface::kX)` for jitter. Doc 03 adds the 12 new surfaces by (a) adding a `Surface::` enum value,
(b) adding descriptor field(s) + schema/validator rules, (c) writing the Blink override, (d)
extending `000` with any new switch. Each new surface is a small, uniform addition to this spine.
