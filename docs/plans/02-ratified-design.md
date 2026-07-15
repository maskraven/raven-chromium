# Plan 02 — Ratified Architecture & Decisions

Status: **ratified 2026-07-14** (autonomous run). Derived from the brave-core study
(pin `d1ce6ee2`, v1.94.64) reconciled with `docs/plans/02-core-architecture-prng-seed-descriptor-db.md`
and the CLAUDE.md non-negotiables. This doc is the implementation spec for `patches/core/1xx-*`.

## 0. Core inversion vs Brave (the load-bearing idea)
Brave's farbling token is **random + per-domain** (randomize-to-hide: a different lie per site).
Raven's seed is **fixed + per-profile** (fix-to-impersonate: the *same* identity on every site).
Consequence: no per-frame token, no per-eTLD+1 variation, no `Token::CreateRandom()`. The
`ExecutionContext`-scoped `Supplement` collapses to a **process-global** `fingerprint::Profile`.
The seed drives **only within-profile jitter** (canvas LSB noise, audio fudge, integer offsets);
**identity axes are read verbatim from the descriptor**, never derived from the seed.

## 1. Keyed derivation chain (the ONE algorithm)
```
key128       = splitmix64_expand(descriptor.seed)     // 2 fixed-const splitmix64 steps, seed(u64) -> 128-bit key
msg          = SurfaceTag(Surface::kX)                 // compile-time ascii tag: "canvas","audio","fonts",...
surface_seed = SipHash-2-4(key128, msg) -> uint64_t    // vendored ~80-line public-domain SipHash reference
FarblingPRNG prng(surface_seed);                       // lifted randen typedef (MPL), single-uint64 value ctor
value        = shape_preserving_draw(prng, descriptor.<field>)
```
- **SipHash key = descriptor seed** (expanded to 128-bit); **message = surface tag**. This replaces
  Brave's weak `high^low^enum` XOR with a real keyed PRF → statistically independent per-surface
  streams from one seed.
- **randen seeding** identical to Brave: single `uint64_t` value constructor. Brave's draw helpers
  (`FarbleInteger`, `PerturbPixels`, `FarbleAudioChannel`, `AllowFontFamily`) are reused ~verbatim.
- **Banned-primitive compliance:** derivation touches ONLY SipHash + randen. No `absl::Hash`,
  no `base::RandUint64` (this is why `Token::CreateRandom()` is dropped), no `Time::Now`, no `std::hash`.

## 2. Single derivation point
- `fingerprint::Profile::Get()` — process-global singleton (analogous to `BraveSessionCache::From`),
  holds the parsed descriptor + seed. The ONE place identity is read.
- `fingerprint::SurfacePrng(Profile::Get().seed, Surface::kX)` — the ONE factory for jitter streams.
- `enum class Surface { kCanvas, kAudio, kFonts, kWebgl, kInteger, ..., kMaxValue }` — closed enum,
  so a typo cannot silently spawn a new stream.
- **Structural axis/jitter separation:** identity fields are read directly from `Profile::Get()`;
  `SurfacePrng` never hashes an identity axis out of the seed. Never double-derive a single-source
  axis (languages↔Accept-Language, UA↔Client-Hints, timezone↔geo).

## 3. Canvas content-coupling (ratified — do NOT ship the bare sketch)
Brave's canvas noise is **content-dependent** (HMAC over pixel bytes) so identical canvases on
different sites don't produce identical noise. Preserve this WITHOUT HMAC:
```
noise_seed = SipHash-2-4(canvas_key128, pixel_bytes)   // depends on BOTH profile seed AND canvas contents
```
A bare `PerturbPixels(SurfacePrng(seed,kCanvas), …)` (content-independent) is a subtle tell — rejected.

## 4. Plumbing (extends fp-chromium patch 000, same two sites)
`patches/fingerprint/000-add-fingerprint-switches.patch` already registers per-field switches in
`components/ungoogled/ungoogled_switches.{h,cc}` and allowlists them in
`RenderProcessHostImpl::PropagateBrowserCommandLineToRenderer`. Plan 02 extends the **same two sites**:
- `--fingerprint-profile=<path>` — **browser** reads the file (`base::JSONReader`) + validates.
- `--fingerprint-profile-data=<b64(compact-json)>` — browser appends this to the child cmdline beside
  the existing `switches::kFingerprint*` block; the **sandboxed renderer** decodes it once into
  `Profile::Get()`. (Renderer can't open files → embed the blob, don't pass a path to the sandbox.)
- Existing thin `--fingerprint*` / `--timezone` switches survive as **per-field overrides**:
  precedence `default < json < switch`.

## 5. Lift provenance (farbling_prng.h)
- `farbling_prng.h` is a ~20-line **MPL-2.0** header, pure typedef
  (`using FarblingPRNG = absl::random_internal::randen_engine<uint64_t>;`). Keep the MPL header verbatim.
- Destination: `third_party/lifted/farbling_prng.h` (adjust include-guard + abseil include path;
  namespace → `fingerprint`). The real cost is the **abseil `random_internal` dep**: needs a
  checkdeps/include-rule allowlist + `BUILD.gn` DEPS entry (brave carries a patch for this — mirror it).
- Ledger row in `third_party/lifted/README.md`: File `farbling_prng.h`; Upstream `brave-core`;
  Path `components/brave_shields/core/common/farbling_prng.h`; Commit `d1ce6ee2` (v1.94.64);
  License `MPL-2.0`; Lifted-in `Plan 02 / patches/core/100`. (Record the pin commit, not the
  vendored header's "2026 The Brave Authors" year line.)

## 6. Ratified open decisions
### D1 — Descriptor field names + versioning
JSON keys **mirror the JS-observable names exactly**. Frozen v1 core set:
`schemaVersion`(int, =1), `seed`(u64 as string or number), `os`, `platform`,
`chromeMajor`, `hardwareConcurrency`, `deviceMemory`,
`gpu.{vendor,renderer,architecture,device}`,
`screen.{w,h,dpr,colorDepth,pixelDepth,availW,availH}`,
`languages[]`, `locale`, `timezone`.
`schemaVersion` is pinned to an accepted range by BOTH `validate.py` and the C++ parser; unknown
major → hard fail. Names frozen alongside the first `patches/core/1xx` patch so schema + C++ struct
+ Raven-Browser writer agree. New surfaces (Plan 03) ADD fields under this contract; never rename.

**deviceMemory decision (refines the 148-delta memory note):** `navigator.deviceMemory` is
spec-clamped by Blink's `ApproximatedDeviceMemory` to the bucket set {0.25,0.5,1,2,4,8} — a real
32 GB machine reports **8**. So the schema caps deviceMemory at 8; reporting {16,32} would be a
non-conformant fingerprint **tell**. The memory `fp-148-improvements-to-adopt` "{8,16,32}" idea is
therefore NOT applied to `navigator.deviceMemory`; if 148 used {8,16,32} it was for a raw-RAM signal
(unconfirmed — 148 source unreleased), not this surface. Contract shipped: `profile-db/schema/
descriptor.schema.json` + `profile-db/validate.py` (structural + cross-axis coherence, stdlib-only,
3 fixtures PASS).

### D2 — Real-device DB sourcing + v1 profile count
This repo ships the **contract only**: `profile-db/schema/descriptor.schema.json` + `validate.py`
+ **3 public fixtures** (Win11+NVIDIA+en-US, macOS-arm+Apple+en-US, Linux+Intel+en-US). Proprietary
curated captures live in Raven Browser. v1 = **one canonical default fixture matching the build host**
(browser never in an undefined state) + start real DB at ~**3 personas per supported host-OS/GPU
class**. No cross-OS personas in v1 (host-OS/GPU-match rule).

### D3 — Descriptor delivery to renderer
**Browser reads the file + validates; renderer receives an embedded base64 compact-JSON blob** on the
command line (`--fingerprint-profile-data`), decoded once into `Profile::Get()`. Not a temp file, not
a sandbox file path. Single atomic sandbox-safe object; cmdline length is ample.

## 7. patches/core layout (Plan 02 output)
```
core/100-lift-farbling-prng.patch        # third_party/lifted/farbling_prng.h + BUILD.gn/checkdeps DEPS
core/101-vendor-siphash.patch            # third_party/lifted/siphash.{h,cc} (public-domain ref)
core/102-descriptor-profile.patch        # fingerprint::Profile + descriptor struct + JSON parse + Surface enum + SurfacePrng
core/103-profile-plumbing.patch          # --fingerprint-profile / --fingerprint-profile-data (extends 000's two sites)
```
(Exact split may adjust during implementation; series order = core/1xx before fingerprint/*.)

## 8. Implementation progress — Plan 02 DONE (2026-07-14, built + smoke-tested)
Final series (19): `core/100`, `core/101` (before fingerprint), `fingerprint/000-018` (16),
`core/102` (LAST — extends 000's switch block). Full `chrome` build BUILD_EXIT=0; `chrome
--fingerprint-profile=<fixture>` reads file → base64 → renderer, renders without crash (SMOKEOK).
Key 150 API fix: `base::Value::Dict`→`base::DictValue` (see memory chromium-150-api-migrations).
absl visibility edit (add `//third_party/lifted/*` to `absl.gni`) WAS required after all.
Details below.
- **core/100 (lifted primitives) — STAGED + VERIFIED** at `patches/core/staging/third_party/lifted/`:
  `farbling_prng.h` (Brave MPL header verbatim, ns→fingerprint), `siphash.{h,cc}` (public-domain
  SipHash-2-4, **verified against canonical vectors** len 0/8/15), `BUILD.gn` (`:lifted`,
  public_dep `//third_party/abseil-cpp/absl/random:random`), `DEPS` (allowlist absl/random),
  `README.md` (provenance ledger). Public abseil `random` target has no visibility restriction →
  **no abseil BUILD.gn edit needed** (mirrors Brave). Post-build: drop into tree + `git diff` → patch.
- **core/101 (descriptor Profile) — STAGED** at `patches/core/staging/third_party/blink/renderer/
  platform/fingerprint/`: `profile.{h,cc}` (Descriptor struct per §6 D1; `Surface` enum + `SurfaceTag`;
  process-global magic-static `Profile::Get()`; `SplitMix64Expand`→key128; `SipHash24Tag`→`FarblingPRNG`;
  §3 canvas content-coupled `CanvasPrng`) + local `DEPS` + `WIRING.md`. **Placement: fold into the
  `blink_platform` `component("platform")`** (lowest blink layer → reachable by all surfaces; mirrors
  Brave's lowest-layer farbling helper). Wiring: add `profile.{cc,h}` to platform `sources`;
  `"//third_party/lifted"` to platform `public_deps` (FarblingPRNG returned inline). **Init: lazy
  magic-static — no content-side call** (content can't include blink internals). Post-build verify:
  `base::JSON_PARSE_RFC` spelling, `randen_engine(uint64)` ctor, `Value::Dict::Find{Dict,List}` names.
- **core/102 (plumbing) — TODO post-build, AFTER Plan 01 patch 000 applied:** append
  `--fingerprint-profile-data` in `render_process_host_impl.cc` `PropagateBrowserCommandLineToRenderer`
  (~L3799, switch array ~L3870); declare `kFingerprintProfile{,Data}` in `components/ungoogled/
  ungoogled_switches.*`; browser reads `--fingerprint-profile=<path>` (base::JSONReader+validate) then
  emits base64 blob; renderer decodes once via `base::Base64Decode` early in child init
  (near `content/child/runtime_features.cc` flow). Overrides: default < json < per-field switch.
```
