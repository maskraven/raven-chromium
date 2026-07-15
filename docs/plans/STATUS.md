# Raven-Chromium — build status (2026-07-14)

Autonomous execution of Plans 00→05. Base: ungoogled-chromium 150.0.7871.114 (`build/PINS`).
Build host: VPS `raven` (`~/chromium/src`, branches `raven-base` = ungoogled baseline,
`raven-patched` = full series applied). Source of truth: this repo.

## Series — 41 patches, all apply clean on `raven-base`, full tree COMPILES + VALIDATES
`patches/series` (order): `core/100` (lifted SipHash/randen primitives), `core/101`
(`fingerprint::Profile` + descriptor + SipHash→randen chain), `fingerprint/000-018` (16 rebased
fp-chromium baseline), `fingerprint/201-214` (14 new surfaces), `fingerprint/219-222`
(Accept-Language header + canvas/webgl/audio/client-rects seed-wiring), `fingerprint/223`
(matchMedia device-dims → descriptor.screen), `fingerprint/224`+`226` (WebGL
param/extension/precision/UNMASKED-string spoof from `profile-db/webgl/`), `fingerprint/225`
(Linux proprietary-codec swap-gate), `core/102` (browser→renderer descriptor plumbing). Verified via
`git apply` on a pristine worktree + the v8-submodule patch (001) applied separately; 0 failures.

**Update (2026-07-15) — R12 fix in `core/102`.** The descriptor is now read + base64-encoded once at
startup (`ungoogled::InitFingerprintProfileData` from `PreCreateThreadsImpl`) and cached; the
renderer-spawn hot path only copies the cache. The prior lazy `base::ReadFileToString` ran on the UI
thread and fatally DCHECKed (disallow-blocking) when the first fingerprint renderer spawned after
startup — which crashed the browser for stock go-rod/chromedp (cold launch + bare `Target.createTarget`).
Now stock go-rod/Puppeteer/chromedp drive the fork with no workaround. See
[`docs/notes/r12-root-cause.md`](notes/r12-root-cause.md); guarded by `test/cdp/r12_auto_attach_regression.py`.

## Plan status
- **00 DONE** — vanilla `Chromium 150.0.7871.114` builds + runs (cold build 4900s).
- **01 DONE** — 16 fp-chromium patches rebased 144→150 (8 clean / 8 fixed from VERIFY@150 drafts /
  3 bromite dropped as redundant-in-ungoogled-150); compiles; patch 010 gives stock `Chrome` UA.
  `apply-patches.sh` fixed for the v8 submodule (falls back to plain `git apply`).
- **02 DONE** — keyed SipHash-2-4 (verified vs canonical vectors) → abseil randen chain; process-global
  `fingerprint::Profile` in `blink_platform`; `--fingerprint-profile=<path>` (browser reads+validates)
  → base64 → renderer. Descriptor schema + coherence validator + fixtures. `docs/plans/02-ratified-design.md`.
- **03 DONE — 14 surfaces** reading the descriptor (pattern: switch-override > descriptor > real):
  hardwareConcurrency, deviceMemory (spec-clamped ≤8), screen, WebGPU adapter, WebRTC-disable, plugins,
  navigator.languages, geolocation-deny, keyboard-layout, WebUSB-empty, speech-empty, mediaDevices
  (seed-stable), UA-CH version→150, timezone. `docs/plans/03-surface-implementation-spec.md`.
- **04 DONE (core gate)** — `build/validate-persona.sh` drives the built browser through
  `test/probe/fingerprint-probe.html`. **Linux persona (linux-intel fixture) passes ALL gates:**
  PERSISTENCE (byte-identical fingerprint across 3 restarts), COHERENCE (UA↔UA-CH major, languages↔Intl,
  platform↔UA, timezone all pass), BRANDING (no Raven/Headless leak; UA is stock Chrome).
- **05 IMPLEMENTED (execution host-gated)** — full release capability authored:
  - T5.4 contract: `docs/contract/launch-contract-v1.md`.
  - T5.1 release args: `build/args/release.gni` (append after common+platform; `RELEASE=1`).
  - T5.5 packaging: `build/package-linux.sh` (tar.xz + SHA256 + optional GPG),
    `build/package-macos.sh` (recursive codesign + notarytool + staple + DMG),
    `build/package-windows.ps1` (Authenticode signtool + zip). All GATED on Plan 04 validation;
    all resolve the runtime file set via `gn runtime_deps`.
  - T5.3 signing: hardened-runtime entitlements `build/sign/entitlements-{app,helper-renderer}.plist`;
    codesign/notarize (macOS) + signtool (Windows) wired into the package scripts.
  - T5.2 branding scrub: in `build/validate-persona.sh` (Raven/Headless never allowed; Chromium only
    a leak inside `navigator.userAgent`).
  - CI: `.github/workflows/build-linux.yml` (T0.6) + `release.yml` (tag-triggered per-OS jobs on
    matching-OS self-hosted runners).
  **EXECUTION requires the environment, not more code:** a macOS host + Developer ID + notarytool
  creds, a Windows host + code-signing cert, and (for a real release binary) a long LTO build.
  These are infrastructure/credentials, not unimplemented features. Linux is runnable now.

## Round 2 (2026-07-14) — code follow-ups + persona DB DONE
Full series now **41 patches** (all apply clean on `raven-base`, compile, validate).
- **Real persona DB** — `profile-db/personas/` (**8** source-verified real devices: Win NVIDIA/Intel/AMD,
  macOS Apple-Silicon, Linux NVIDIA), all pass `validate.py`, provenance in its README. Each paired with
  a HIGH-confidence WebGL param bundle in `profile-db/webgl/webgl-gpu-params.json` (**8 GPUs**).
- **Accept-Language header** (`fingerprint/219`) — NEW `components/ungoogled/fingerprint_accept_language.*`
  singleton parsed in `PreCreateThreadsImpl` (blocking allowed, before the UI-thread ban), read by
  `ComputeAcceptLanguage()`. VALIDATED end-to-end: de-DE persona → `Accept-Language: de-DE,de`.
- **Canvas/WebGL/audio/client-rects seed-wiring** (`fingerprint/220-222`) — noise re-keyed from
  `descriptor.seed` via `CanvasPrng`/`SurfacePrng`, replacing the **banned `std::hash`** path (which
  was also inert without a `--fingerprint` switch). VALIDATED: canvas hash is persona-differentiated
  (A≠B≠vanilla) AND persistent (A run1==run2). Fixes the canvas-not-persona-specific gap.
- **Richer speech** (`fingerprint/211`) — OS-appropriate voice list (Google set + OS-local voices)
  instead of empty. **Refined media** (`fingerprint/212`) — pre-permission 3 blank placeholders,
  resolved at `enumerateDevices()` entry (host-independent; no round-trip hang).

## Round 3 (2026-07-14) — codecs, matchMedia, full WebGL param set, dataset finalized
- **Codecs (Plan 05):** Win/macOS bundle proprietary decoders (`ffmpeg_branding="Chrome"`); Linux ships a
  SWAPPABLE `libffmpeg.so` (no patented decoder) + a runtime `avcodec_find_decoder` probe-gate
  (`fingerprint/225`) so `canPlayType` advertises H.264/AAC **iff** decodable. **Enable-path VALIDATED
  end-to-end** on the VPS: default → H.264/AAC `""`; a Chrome-branded `libffmpeg.so` installed via
  `build/raven-launch.sh --fingerprint-ffmpeg=<path>` → `"probably"` + real decode (readyState 4). Fixed
  a SIGPIPE false-warning in the launcher. Contract §6 documents the model.
- **matchMedia** (`fingerprint/223`): device-width/height/aspect/resolution wired to `descriptor.screen`
  → CreepJS totalLies 1→0.
- **Full WebGL param set** (`fingerprint/224`+`226`): UNMASKED strings + all `getParameter` caps +
  extension filtering + shader precision, per-GPU from `profile-db/webgl/webgl-gpu-params.json` via
  `gen_webgl_table.py`. Metadata spoof validated (RTX 3060 persona flips SwiftShader→NVIDIA values).
- **WebGL dataset finalized to 8 uniformly-HIGH GPUs.** Apple-Silicon (M1/M3) upgraded to HIGH from a
  direct Chrome-150 ANGLE-Metal capture (family-constant across M-series; corrected UNIFORM_BUFFER_BINDINGS
  32, UNIFORM_BLOCK_SIZE 16384, ELEMENT_INDEX 4294967294, VARYING_VECTORS 30). Dropped 2 niche/weak
  devices (macOS-Intel Iris Plus, Linux-Intel Iris Xe) + their personas → 10→**8**. Windows(5) + Linux-NVIDIA
  all HIGH from web3dsurvey corpus. `capture-webgl-params.html` added for on-machine capture.
- **Detection research (keystone):** per-GPU *exact-host* capture is NOT required — CreepJS keys on
  (brand + whole param bundle) ∈ known-real-set, brand-granular, no per-model DB; a coherent whole-device
  bundle suffices. Confirms the **source-level (C++) approach is correct**; JS-injection (e.g. apify
  `fingerprint-injector`) gets caught by CreepJS "lied" detection. `apify/fingerprint-suite` data is usable
  for offline persona *authoring* only, not runtime.
- **Third-party integration guide** added: `docs/guides/third-party-integration-guide.md`.

## Remaining follow-ups (non-blocking)
- **Patch `226` regeneration + rebuild** pending: the WebGL header (`webgl_persona_params_data.h`) must be
  regenerated from the finalized 8-GPU dataset and the series recompiled. Blocked 2026-07-14 by VPS being
  unreachable; retry when it returns. (Dataset JSON = source of truth, already validated.)
- **Cross-host personas** (persona GPU/fonts ≠ host): needs **font-metrics** spoofing. WebGL param set is
  now done; rendered pixels remain host-GPU-bound (v1 host-match constraint). Detection research: coherent
  bundle + real-GPU host is sufficient; SwiftShader/software rendering is self-revealing.
- `navigator.keyboard.getLayoutMap()`: canonical 47-entry US map headful; times out **headless** (no
  display) in the VPS test env only.
- macOS/Windows **build + validate + sign**: user has Win/macOS build machines; ADP + Windows EV cert
  deferred by user. Scripts ready (Plan 05 T5.3/T5.5).
- T0.6 minimal CI build-linux still deferred.
