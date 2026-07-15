# WIRING — fingerprint::Profile (Plan 02 / patches/core/102)

Placement + build/DEPS wiring for `fingerprint::Profile`. These BUILD.gn / DEPS
edits are applied against the real tree POST-BUILD (drop staged files in, then
`git diff` → patch). Nothing here modifies the Chromium tree yet.

## 1. Chosen directory

`third_party/blink/renderer/platform/fingerprint/`
  - `profile.h`, `profile.cc`, `DEPS` (all staged here).

Rationale (mirrors Brave, inverts its scope). Brave keeps `BraveSessionCache` in
blink **core** (`core/farbling/`) because it is an `ExecutionContext`-scoped
`Supplement` — an inherently core concept. Raven's Profile is **process-global**
(design §0/§2), untied to any ExecutionContext, and must be callable from
surfaces in **all three** blink layers (audio lives in `platform/`, canvas/webgl
in `core`+`modules`, navigator/screen in `core`). `platform` is the lowest blink
layer — core and modules already depend on it, and it cannot depend on them — so
it is the only layer every surface can reach. This is exactly where Brave keeps
its lowest-layer farbling primitive (`platform/brave_audio_farbling_helper.*`).
Placing Profile in `platform` also keeps the abseil-randen dependency contained
the same way `//third_party/lifted` does.

## 2. GN target

Primary (recommended): **fold the two sources into the existing
`component("platform")`** in `third_party/blink/renderer/platform/BUILD.gn`
(target `blink_platform`). No new link target — the component boundary already
exports symbols, and this avoids the duplicate-symbol / ODR hazard a standalone
`source_set` linked by both the component and its dependents would create.
Compiling inside the component means `PLATFORM_EXPORT` resolves to dllexport for
`Profile::Get()` / `SurfacePrng` / `CanvasPrng`, and core/modules link them as
dllimport across the component boundary — identical to every other platform API.

Concrete edits to `third_party/blink/renderer/platform/BUILD.gn`:
- In `component("platform")` **sources** (list begins ~L355), add:
  ```
  "fingerprint/profile.cc",
  "fingerprint/profile.h",
  ```
- In `component("platform")` **public_deps** (list ~L1776, beside
  `":blink_platform_public_deps"`), add:
  ```
  "//third_party/lifted",
  ```
  `public_deps` (not `deps`) because `profile.h` exposes `FarblingPRNG` (an
  abseil `randen_engine` type) inline in `SurfacePrng`/`CanvasPrng` return
  values, so callers that pull draws need abseil's headers + linked randen
  object to propagate transitively. `//third_party/lifted` already
  `public_dep`s `//third_party/abseil-cpp/absl/random:random` (staged in
  core/100), so no direct abseil entry is needed here.

Alternative (if the component fold is undesirable): a
`source_set("fingerprint")` in a new `platform/fingerprint/BUILD.gn`, added to
`component("platform")` public_deps, compiled with the blink-platform
implementation config so `PLATFORM_EXPORT` = dllexport. Rejected as primary
because a source_set pulled into both the component and its dependents risks
duplicate symbols at the component boundary.

## 3. DEPS / include-rule allowlist

New local file `third_party/blink/renderer/platform/fingerprint/DEPS` (staged).
Parent `platform/DEPS` already permits `+base/command_line.h`, `+base/json`,
`+base/values.h`, `+base/no_destructor.h`; local rules are additive, so the file
adds only:
- `+third_party/lifted`  (for `farbling_prng.h` + `siphash.h`)
- `+base/base64.h`  (ctor decodes the descriptor blob)
- `+base/strings/string_number_conversions.h`  (`base::StringToUint64` for the
  string-encoded u64 seed)

abseil note: checkdeps flags only **direct** includes. `profile.{h,cc}` include
`third_party/lifted/*` (allowlisted above); `absl/random` is pulled only
transitively by `farbling_prng.h`, whose own dir allowlists it
(`third_party/lifted/DEPS`, staged in core/100). So no absl allowlist is needed
in this dir.

Callers need NO DEPS edit: `third_party/blink/renderer/DEPS` (L109) already
allows `+third_party/blink/renderer/platform` for all of core + modules, so any
surface may `#include
"third_party/blink/renderer/platform/fingerprint/profile.h"`.

## 4. Renderer init call-site

**Profile is lazily self-initializing — no explicit init call is required.**
`Profile::Get()` is a thread-safe magic-static (C++11); its constructor reads
`base::CommandLine::ForCurrentProcess()->GetSwitchValueASCII("fingerprint-profile-data")`,
`base::Base64Decode`s it, and parses the compact JSON. The renderer command line
is fully populated long before any blink surface runs, so the first surface that
calls `Profile::Get()` triggers construction safely.

Correction to design §8's "near content/child/runtime_features.cc" note:
`content/` may include only `+third_party/blink/public` (content/DEPS L92), NOT
`third_party/blink/renderer/platform` — so `runtime_features.cc` **cannot**
`#include` or call `fingerprint::Profile`. Its
`SetRuntimeFeaturesFromCommandLine(const base::CommandLine&)` is the conceptual
analog for how the ungoogled fp switches are read, not a valid Profile call
site. If an explicit startup warm-up / early validation-log is wanted, add a
bare `fingerprint::Profile::Get();` in a blink-internal renderer entry point that
CAN include platform (e.g. `third_party/blink/renderer/controller/blink_initializer.cc`),
not in content/.

## 5. Switch-name coupling (with patch 102)

`profile.cc` reads the literal `"fingerprint-profile-data"`. When core/102
declares `switches::kFingerprintProfileData` in
`components/ungoogled/ungoogled_switches.{h,cc}` (browser-side, design §4/§8),
optionally swap the literal for that constant — which would additionally require
adding `+components/ungoogled/ungoogled_switches.h` to this dir's DEPS. Keeping
the literal avoids a platform→components dependency and is functionally
identical.

## 6. Prerequisite (already staged)

`//third_party/lifted` (`:lifted` target: `farbling_prng.h`, `siphash.{h,cc}`,
its own `DEPS` + `BUILD.gn`) is staged and verified in core/100. This wiring only
adds a `public_deps` edge to it; no change to the lifted target is needed.
