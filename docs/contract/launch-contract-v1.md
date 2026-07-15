# Raven Chromium ↔ Raven Browser — Launch / Descriptor Contract v1

Status: **v1 (2026-07-14)**. This is the ONLY coupling between the open fork (Raven Chromium) and
the closed app (Raven Browser). Keep it narrow and versioned; churn here breaks Raven Browser
releases. Corresponds to Plan 05 T5.4.

## 1. CLI surface (stable — Raven Browser MAY rely on these)

| Switch | Meaning | Stability |
|---|---|---|
| `--fingerprint-profile=<path>` | Path to a JSON descriptor (§2). The **browser** process reads + validates it once and propagates it to renderers internally. **Primary interface.** | STABLE |
| `--user-data-dir=<path>` | Per-persona profile isolation (standard Chromium). One data dir per persona. | STABLE (Chromium) |

**Testing-only overrides (UNSTABLE — do NOT ship against these):** the thin per-field switches from
baseline patch `000` — `--fingerprint`, `--fingerprint-platform`, `--fingerprint-hardware-concurrency`,
`--timezone`, `--fingerprint-screen-width/height`, etc. Precedence is `default < descriptor < switch`,
so these override the descriptor. Use only for manual testing.

**Internal — Raven Browser MUST NOT pass or depend on:** `--fingerprint-profile-data` (the base64
descriptor blob the browser injects into renderers; an implementation detail — passing it directly
bypasses validation). Any switch not listed in the STABLE rows is internal/volatile.

## 2. Descriptor schema

- Canonical schema: [`profile-db/schema/descriptor.schema.json`](../../profile-db/schema/descriptor.schema.json)
  (JSON Schema draft 2020-12). Validate with `profile-db/validate.py` (structural + cross-axis
  coherence) before writing a descriptor.
- Every descriptor carries `schemaVersion` (integer, **1** for this contract). The browser hard-fails
  (profile stays INACTIVE, host values untouched — never crashes) on an unknown major version.
- **Compatibility policy:** additive optional fields ⇒ **minor** revision (same major, back-compatible).
  Field rename/removal or semantic change ⇒ **major** bump + a new `launch-contract-v<N>.md` +
  migration notes. Raven Browser pins the contract major it targets.
- Frozen v1 fields (JS-observable names): `schemaVersion, seed, os, platform, chromeMajor,
  hardwareConcurrency, deviceMemory, gpu{vendor,renderer,architecture,device},
  screen{w,h,dpr,colorDepth,pixelDepth,availW,availH}, languages[], locale, timezone`.

## 3. Descriptor delivery & lifetime

- Raven Browser writes the descriptor to a file and passes `--fingerprint-profile=<path>` at launch.
- The browser reads + base64-encodes it and forwards it to each renderer via the internal
  `--fingerprint-profile-data` switch; the renderer decodes it once into the process-global
  `fingerprint::Profile` (lazy, thread-safe). Identity axes are read verbatim; the `seed` drives only
  within-profile jitter.
- **Lifetime:** the file MUST remain readable for the **lifetime of the browser process** (the
  encoded descriptor is cached on first renderer spawn, but renderers may spawn at any time). Raven
  Browser owns creation and cleanup; delete it only after the browser process exits. A per-launch
  temp file under the persona's `--user-data-dir` is recommended.

## 4. Binary handoff

- Raven Browser consumes **signed binaries only — never source**.
- Artifact naming: `raven-chromium-<version>-<os>-<arch>[.<ext>]` (e.g.
  `raven-chromium-150.0.7871.114-linux-x64.tar.xz`). Each release ships `SHA256SUMS` + a detached
  signature (GPG on Linux; codesign/notarization on macOS; Authenticode on Windows).
- Raven Browser MUST verify the signature + checksum before launch.
- **Version pinning:** a Raven Browser release declares the exact Raven Chromium `<version>` (matches
  `build/PINS` `chromium_tag`) it expects; do not mix.

## 5. Guarantees

1. **Persistence** — the same descriptor ⇒ a byte-identical fingerprint across restarts (validated
   per Plan 04).
2. **Coherence** — only descriptors that pass `validate.py` are supported; identity axes co-vary and
   single-source axes never contradict (languages↔Accept-Language, UA↔Client-Hints, timezone↔geo).
3. **No branding leak** — the running browser presents as **stock Chrome** to any detector: no
   `Raven`/`Chromium`/`Headless` in `navigator.userAgent`, `userAgentData`, `appName/appVersion/
   vendor`, WebGL renderer, or any JS-visible field (Plan 05 T5.2 scrub; asserted by Plan 04).
4. **WebRTC absence** — with an active profile, `new RTCPeerConnection()` fails (NotSupportedError);
   the app MUST NOT depend on WebRTC (spec §11.3, anti-IP-leak).
5. **OS/GPU-class match** — a persona is valid ONLY on the matching-OS binary (no cross-OS personas
   in v1). Raven Browser pairs each descriptor to the correct per-OS artifact.
6. **Geolocation** — `navigator.geolocation` returns the descriptor's coordinates, permission-gated
   (Plan 03 surface).

## 6. Codecs (H.264/AAC) — per-OS model
- **Windows / macOS artifacts** bundle the proprietary decoders (`proprietary_codecs=true` +
  `ffmpeg_branding="Chrome"`) — `canPlayType`/`MediaCapabilities`/playback report real Chrome codec
  support out of the box. Nothing for Raven Browser to do.
- **Linux artifacts** ship a SWAPPABLE `libffmpeg.so` with NO patented decoder. By default H.264/AAC
  report unsupported (coherent — a runtime `avcodec_find_decoder` probe gates `canPlayType`, so the
  browser never claims a codec it can't decode). To enable, install a licensed Chrome-branded
  `libffmpeg.so` (matching the shipped ffmpeg ABI) via the launcher:
  `raven-launch.sh --fingerprint-ffmpeg=<path> --fingerprint-profile=<persona>`. The patent license
  for that lib rests with its source, not Raven Chromium. A raw `--path` browser switch is impossible
  (`libffmpeg` is a `DT_NEEDED` lib loaded before `main`); the launcher does the file-swap.
- **Guarantee:** the browser advertises H.264/AAC **iff** it can actually decode them — so codec probing
  never produces a contradiction, on any OS.

## 7. Target / DevTools (CDP) — automation surface

The CDP `Target`/session channel is a **browser ↔ controlling-driver** signal. It is **not observable by
page JavaScript** (a page cannot see whether a driver auto-attached, enabled a domain, or opened a
session). Page-visible anti-detection is handled by **separate, independent** mechanisms — `navigator.
webdriver === false` (patch 009), `Runtime.enable` hidden from the page, no branding leak (§5.3), WebRTC
absent (§5.4) — so nothing here weakens stealth.

- **Standard auto-attach works, identical to stock Chrome.** With an active `--fingerprint-profile`,
  `Target.setAutoAttach{autoAttach:true, flatten:true}` (with or without `waitForDebuggerOnStart`) at the
  browser target, followed by `Target.createTarget`, delivers `Target.attachedToTarget` with a usable
  flattened session — same as plain mode. Explicit `Target.attachToTarget{flatten:true}` also works.
- **Stock CDP clients are supported.** go-rod, Puppeteer, and chromedp open and drive pages on the fork
  under `--fingerprint-profile` with **no driver-side workaround** — including a *cold* driver whose first
  action is `Target.createTarget` (no pre-warmed page), which is how go-rod/chromedp launch.
- **No fingerprint-conditional DevTools behavior.** Launching with `--fingerprint-profile` does not alter
  the Target/DevTools-agent lifecycle relative to stock. The descriptor is read once during browser
  startup and cached; the renderer-spawn hot path performs no file I/O, so opening a target never blocks
  or crashes the browser.
- **Guarantee:** any conformant CDP client that works against stock Chrome for Testing works against the
  fork with an active profile; the only differences a driver observes are the spoofed identity values
  (§5), never a missing event, dropped session, or closed connection.

> Regression-guarded by `test/cdp/r12_auto_attach_regression.py` (cold-browser `createTarget` must not
> EOF/crash; `setAutoAttach` must deliver `attachedToTarget`).

## Changelog
- **v1** (2026-07-14): initial contract. `--fingerprint-profile` file interface; schemaVersion 1;
  per-OS codec model (§6); WebGL GPU spoofed from `descriptor.gpu` (host-GPU-match for rendered pixels).
- **v1** (2026-07-15): documentation clarification only (no schema/CLI change, pins unchanged) — added §7
  (Target/DevTools/CDP automation surface). Documents that standard CDP auto-attach works identically to
  stock under `--fingerprint-profile`, after fixing R12 (a `core/102` UI-thread descriptor read that
  crashed the browser on the first post-startup fingerprint-renderer spawn; now read+cached at startup).
