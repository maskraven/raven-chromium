# Plan 03 — New Surface Patches (spec §6.3)

**Goal:** add the 12 surfaces the baseline lacks (spec §3.3 gaps, §4 bold items, §6.3 table, plus
geolocation), each plugged into the doc-02 spine. Ordered **highest-value first** per spec §7.5:
speech voices → screen/pointer → media devices → WebGPU → languages+Accept-Language → then
plugins, keyboard, dark-mode, fonts, WebUSB, WebRTC, and geolocation (S12, implementing the last
§3.3 dead switch).

Each surface is a patch `patches/fingerprint/2xx-<name>.patch` added to `patches/series` after
the baseline set. **Every path below is `VERIFY@150`** (spec §6.3 is 144-relative).

**Exit criteria:** every switch in spec §6.3 has an effect; the dead switches from §3.3 are
implemented; each surface is persistent (doc 04 §8.1) and coherent (doc 04 §8.3); `000` carries a
switch + propagation for each; each descriptor field has a schema + validator rule (doc 02 T2.6).

---

## Uniform template (apply to every surface)

For surface **X**:

1. **Descriptor** — add field(s) to `fingerprint::Profile`, `descriptor.schema.json`, and a
   coherence rule in `validate.py` (doc 02 T2.6). Add a **public fixture** value.
2. **Seed** — add `Surface::kX` to the enum + `SurfaceTag` (doc 02 T2.2). Use `SurfacePrng` only
   for *jitter*; identity comes from the descriptor field.
3. **Blink override** — patch the getter/enumeration at the layer named below to return the
   descriptor-derived value, cached for process lifetime.
4. **Switch** — extend `000` with `--fingerprint-<x>` (per-field override) + browser→renderer
   propagation (goes through the b64 descriptor blob; add a thin switch only if useful for
   testing).
5. **Coherence** — enforce the cross-axis constraint listed; add `TODO(coherence)` cross-links
   between surfaces that must agree (fonts↔canvas, WebGL↔WebGPU, languages↔Accept-Language↔tz).
6. **Probe + snapshot** — extend `test/probe/probe.html` to read X; add expected value to
   `test/snapshots/<profile>.json` (doc 04).

---

## S1 — Speech-synthesis voices  *(high-value gap, spec §6.3)*

- **Target:** `third_party/blink/renderer/modules/speech/speech_synthesis.cc`
  (`SpeechSynthesis::getVoices` / the `VoiceList`). `WebSpeechSynthesisClient` is the *legacy*
  path; in current Chromium the voice list arrives over the **mojo `SpeechSynthesis` interface**
  from the browser's `TtsController` — override where the mojo voice list is consumed, not just the
  Blink accessor. `VERIFY@150`.
- **Descriptor:** derive from `os` + `languages` (no new required field; optionally an explicit
  `voices[]` override). Ship curated canonical lists per OS:
  - Windows: `Microsoft David - English (United States)`, `Microsoft Zira …`, + Edge Natural
    voices matching `chromeMajor`/Edge presence — pick the stock set for the OS build.
  - macOS: `Alex`, `Samantha`, `Daniel (en-GB)`, … the system voice set for the OS version.
- **Derivation:** fixed list for `(os, locale)`; `default` and `localService` flags set;
  `voiceURI`/`lang` consistent. No per-call randomness (voices don't jitter).
- **Coherence:** voices' `lang` set must include `Profile.languages`; OS must match `Profile.os`.
  A Windows persona exposing `Alex` is an instant CreepJS lie.
- **Test:** `speechSynthesis.getVoices()` → curated list; identical across restarts; async
  `voiceschanged` path returns the same list.

## S2 — Screen / pointer  *(implements the dead screen switches, spec §3.3)*

- **Target:** `third_party/blink/renderer/core/frame/screen.cc` (+`.h`) for
  `width/height/availWidth/availHeight/availLeft/availTop/colorDepth/pixelDepth`;
  `local_dom_window.cc` for `screenX/Y`, `outerWidth/Height`; pointer/hover media features via
  `web_preferences`. `VERIFY@150`.
- **DPR must be spoofed at the source, not the getter.** `devicePixelRatio` **and**
  `matchMedia('(resolution:…)')` / `(min-resolution)` / `image-set` / CSS px math all read the
  compositor's `blink::ScreenInfo.device_scale_factor` (plumbed via `WidgetBase`/`VisualProperties`),
  *not* `LocalDOMWindow::devicePixelRatio` alone. Patch `ScreenInfo`/`VisualProperties` (or use
  `--force-device-scale-factor` for DSF) so **every** DPR consumer agrees; overriding only the JS
  getter desyncs matchMedia and is a textbook CreepJS lie.
- **Descriptor:** `screen{ w, h, dpr, colorDepth, pixelDepth, availW, availH }` (spec §6.2).
  **This finally wires `--fingerprint-screen-width/-height/-device-scale-factor` and computes
  avail/depth** — the §3.3 dead switches.
- **Derivation:** all values come straight from the descriptor (identity, not jitter). If avail\*
  omitted, compute from OS chrome insets (Windows taskbar ⇒ `availH = h - 40ish`; macOS menubar).
- **Coherence (critical — CreepJS checks these):** `availW ≤ w`, `availH ≤ h`;
  `colorDepth == pixelDepth ∈ {24,30}`; `dpr` plausible for OS (mac Retina ⇒ 2.0);
  `(w,h)` is a real resolution; `devicePixelRatio`, `matchMedia` `resolution`, and CSS pixel math
  all agree. Also fix `window.screen.orientation` for the form factor.
- **Test:** browserleaks/screen + `window.screen.*` + `devicePixelRatio` match descriptor; avail ≤
  total; stable across restarts and across windows.

## S3 — Media devices  *(enumerateDevices, spec §4/§6.3)*

- **Target:** `third_party/blink/renderer/modules/mediastream/media_devices.cc`
  (`MediaDevices::enumerateDevices`). `VERIFY@150`.
- **Descriptor:** device counts (default a plausible laptop set: 1 `audioinput`, 1 `audiooutput`,
  1 `videoinput`) — optionally `mediaDevices{ mic, cam, speaker }`. A per-profile `deviceIdSalt`
  derived from the seed.
- **Derivation:** `deviceId`/`groupId` = `HMAC(deviceIdSalt, eTLD+1, device_index)` — **per-origin
  salted**, matching how real Chrome scopes device IDs. A single *global* synthetic id both
  deviates from Chrome and creates a cross-site correlation handle inside one persona, so derive
  per eTLD+1. Stable across sessions, unique per device. **Strip `label` until permission is
  granted** (matches real Chrome pre-getUserMedia). Counts may be seed-jittered within realistic
  bounds via `FarbleInteger`.
- **Coherence:** counts plausible for the persona form factor (a desktop without a camera is fine;
  a laptop usually has all three); `videoinput` presence should agree with any camera implied
  elsewhere. IDs stable ⇒ no per-call drift.
- **Test:** `enumerateDevices()` stable across restarts; labels empty without permission;
  `groupId` groups mic+speaker consistently.

## S4 — WebGPU adapter  *(spec §4/§6.3; hard one)*

- **Target:** `third_party/blink/renderer/modules/webgpu/gpu_adapter.cc`,
  `gpu_adapter_info.cc` (`GPUAdapterInfo` vendor/architecture/device/description), and
  `GPU::requestAdapter`. `VERIFY@150`.
- **Descriptor:** `gpu{ vendor, architecture, device, renderer }` — the **same object** WebGL 011
  reads.
- **Derivation:** override `adapter.info` from `Profile.gpu`; set `limits`/`features` to a
  plausible tier for that GPU (don't expose contradictory limits). Keep it descriptor-picked, not
  seed-random (identity). **Match Chrome's redaction:** real Chrome returns **empty
  `device`/`description`** on `GPUAdapterInfo` by default — populate `vendor`/`architecture` but
  leave `device`/`description` as Chrome actually exposes them, or the populated fields are
  themselves the anomaly.
- **Coherence (make-or-break):** WebGPU `vendor`/`architecture` ↔ WebGL `UNMASKED_VENDOR/RENDERER`
  (patch 011) ↔ `Profile.gpu` — all three must name the same physical GPU (spec §6.2 example:
  "Google Inc. (NVIDIA)" / "ANGLE (NVIDIA … RTX 3060 …)"). Wire the `TODO(coherence)` marker left
  in 011. Limits must be consistent with the named device.
- **Host-GPU-class constraint (README):** WebGL/WebGPU expose far more than the vendor/renderer
  *strings* — the WebGL extension list, `MAX_*` parameters, and shader-precision formats come from
  the **real host GPU/driver** and are hashed by CreepJS/browserleaks. We do not manufacture that
  surface; instead personas are constrained to the host GPU class so `Profile.gpu` never
  contradicts the real parameter set. **Do not ship a persona GPU outside the build host's class.**
- **Test:** `navigator.gpu.requestAdapter()` → `adapter.info` matches; a script comparing WebGL vs
  WebGPU vendor agrees; CreepJS GPU section shows no lie.

## S5 — navigator.languages + Accept-Language  *(JS **and** HTTP must match, spec §6.3)*

- **Target:** renderer `navigator_language.cc` (`NavigatorLanguage::languages`/`language`) **and**
  the network `Accept-Language` header. The header is pref-driven
  (`RendererPreferences::accept_languages` / the locale prefs the browser sends); patch both from
  one source. `//net` header assembly is the HTTP side. `VERIFY@150`.
- **Descriptor:** `languages[]` + `locale` (spec §6.2).
- **Derivation:** set `RendererPreferences.accept_languages` (browser) **and** the renderer
  `navigator.languages` from the same `Profile.languages`, with matching q-values in the header.
- **Coherence:** `navigator.languages[0] == Profile.locale`; the HTTP `Accept-Language` q-value
  ordering equals `navigator.languages`; `locale` ↔ `timezone` plausible. **Double-derivation is
  the classic bug here** — one field, two consumers (README §5).
- **Test:** compare `navigator.languages` to the `Accept-Language` seen by an echo endpoint — must
  be identical ordering; CreepJS "languages lie" clean.

## S6 — plugins / mimeTypes  *(spec §6.3)*

- **Target:** `third_party/blink/renderer/core/frame/navigator_plugins.cc` (`DOMPluginArray`,
  `DOMMimeTypeArray`). `VERIFY@150`.
- **Descriptor:** none new. Modern Chrome exposes a fixed set of ~5 named PDF "plugins" all backed
  by the internal PDF viewer, each with `application/pdf` + `text/pdf` mime types. These names are
  **hardcoded and OS-independent** in Blink (do *not* derive them from `os`); they key only to the
  Chrome/`chromeMajor` line. `VERIFY@150`: confirm the exact current names/order for the pinned
  milestone, **and** check that the ungoogled baseline hasn't already emptied `navigator.plugins`
  (an empty list is itself a lie vs. real Chrome — restore the canonical set if so).
- **Derivation:** return the canonical Chrome set for the persona; order + names + mimeTypes
  fixed. Not seed-random.
- **Coherence:** set must match the Chrome version the persona claims (UA `chromeMajor`).
- **Test:** `navigator.plugins` length/names/mimeTypes byte-match a real Chrome of the same
  version.

## S7 — Keyboard API  *(spec §6.3)*

- **Target:** `Keyboard::getLayoutMap` lives in `.../modules/keyboard/keyboard.cc`; the map is
  resolved via the platform `DomKeyboardLayoutMap` (`keyboard_layout.cc`). `keyboard_layout_map.cc`
  is just the result container — **override the resolution, not the container.** `VERIFY@150`.
- **Descriptor:** from `locale` (+ optional explicit `keyboardLayout`). Ship canonical layout maps
  (en-US QWERTY: `KeyA→"a"`, `KeyQ→"q"`, `Digit1→"1"`, …; add common locales as needed).
- **Derivation:** fixed map for the locale; no jitter.
- **Coherence:** layout ↔ `Profile.locale`/`os`; a US persona must not report an AZERTY map.
- **Test:** `navigator.keyboard.getLayoutMap()` entries match the locale; stable.

## S8 — Dark mode / preferences  *(spec §6.3)*

- **Target:** `blink::WebPreferences::preferred_color_scheme` (+ `prefers-reduced-motion`) via the
  web-preferences override path. `VERIFY@150`.
- **Descriptor:** `prefersColorScheme` (`light`/`dark`), `prefersReducedMotion` (default
  `no-preference`).
- **Derivation:** set the preference from the descriptor; stable.
- **Coherence:** just a stable pref, but keep it consistent per profile (don't let OS dark-mode of
  the *host* machine leak through — force the descriptor value).
- **Test:** `matchMedia('(prefers-color-scheme: dark)').matches` follows the descriptor regardless
  of host OS theme.

## S9 — Fonts  *(hardest coherence; spec §4/§6.3)*

- **Target:** `third_party/blink/renderer/platform/fonts/font_cache*` / font matching
  (`FontCache::Get…`) + the enumeration path used by canvas/`measureText`. Port Brave's
  `AllowFontFamily` allowlist mechanism (doc 02 T2.3). `VERIFY@150`.
- **Descriptor:** `os` (+ optional explicit `fonts[]`). Expose **only** the descriptor-OS font set
  (Windows vs. macOS system fonts differ sharply — a strong fingerprint axis).
- **Host-OS constraint (README) — read this first.** `AllowFontFamily` can only *hide* fonts that
  are present on the build host; it **cannot manufacture a foreign OS's font metrics** — a hidden
  or missing family falls back to a host font, so `measureText`/canvas would still render with host
  metrics and contradict the claimed OS. Therefore the allowlist is a **subset of the real host
  fonts**, and a persona OS ≠ host OS is out of scope for v1 (would require bundling that OS's
  actual font files). Personas are host-OS-constrained precisely so this stays coherent.
- **Derivation:** allowlist by OS; unknown family requests fall back deterministically. No jitter
  on *which* fonts exist.
- **Coherence (make-or-break):** the font set must agree with **canvas/`measureText` metrics**
  (baseline 015) and with `Profile.os`. If a font is "present" per enumeration but renders with
  fallback metrics, that's a detectable contradiction. This surface and the canvas/measureText
  patches must be validated together (doc 04 §8.3).
- **Test:** JS font-probe (measure a string across many families) matches the OS set; `measureText`
  for allowed fonts stable; no font present in enumeration that measures as fallback.

## S10 — WebUSB  *(low priority, spec §6.3)*

- **Target:** `third_party/blink/renderer/modules/webusb/usb.cc` (`USB::getDevices`). `VERIFY@150`.
- **Descriptor:** none (default empty). Optionally a small stable list later.
- **Derivation:** return a stable empty array.
- **Coherence:** trivial (empty is normal).
- **Test:** `navigator.usb.getDevices()` → `[]`, stable, no prompt side effects.

## S11 — WebRTC hard-disable  *(decision §11.3; spec §6.3/§9)*

- **Target:** block `RTCPeerConnection`/ICE so **no candidate is ever gathered** —
  `//content` + `peer_connection` factory, and the Blink binding. `VERIFY@150`.
- **Approach:** disable the `RTCPeerConnection` interface at the Blink
  `RuntimeEnabledFeatures`/bindings level (constructor absent) **and** ensure no ICE agent is
  created browser-side. ungoogled already ships WebRTC IP-handling patches (spec §7.1) — build the
  hard-disable on top; do **not** implement a spoofing path (decision §11.3). Do not disable
  `getUserMedia`/`enumerateDevices` (separate API, S3) — only peer connections.
- **Coherence / caveat:** absence of `RTCPeerConnection` is itself a *minor* signal (spec §9) —
  accepted: absence beats real-IP leakage. Document the tradeoff in the patch header; note the
  future option (spoof ICE to the proxy IP) is explicitly out of scope now.
- **Test:** `typeof RTCPeerConnection === 'undefined'` (or throws); no host/srflx candidates ever
  appear; browserleaks WebRTC shows no local or public IP.

## S12 — Geolocation  *(implements the dead `--fingerprint-location` switch, spec §3.3)*

- **Target:** the Geolocation position source, **not** just the JS getter — Blink
  `.../modules/geolocation/geolocation.cc` consumes positions from the browser-side
  `device::GeolocationImpl` / `GeolocationContext` (`//services/device/geolocation`). Override the
  position the service supplies so both the one-shot and `watchPosition` paths agree. `VERIFY@150`.
- **Descriptor:** `location{ lat, lon, accuracy }`. **This wires the last §3.3 dead switch,**
  `--fingerprint-location`.
- **Derivation:** return the descriptor's fixed coordinates (identity, not jitter) with a plausible
  `accuracy` (e.g. 20–100 m); permission flow unchanged (still user/policy gated — spoofing the
  *value*, not bypassing the prompt).
- **Coherence (the reason this is a real surface, not a descoped switch):** `location` must lie
  inside the `timezone`'s region and agree with `locale` — a persona on `America/New_York` must not
  report Tokyo coordinates. Add a **`timezone ↔ location`** rule to `validate.py` (doc 02 T2.6) and
  treat {S12 ↔ 018 timezone ↔ S5 locale} as a coupled set (below).
- **Test:** with permission pre-granted, `navigator.geolocation.getCurrentPosition()` returns the
  descriptor coords; stable across restarts; coordinates fall within the timezone region.

---

## Ordering & parallelization

- **Serial value order** (spec §7.5): S1 → S2 → S3 → S4 → S5, then S6–S11 as capacity allows.
- Once doc 02's spine is in, S1/S6/S7/S8/S10 are largely independent and **parallelizable across
  engineers** (each is: enum + descriptor field + one Blink getter + probe).
- **Coupled pairs — do together:** {S4 WebGPU ↔ 011 WebGL}, {S9 fonts ↔ 015 measureText/canvas},
  {S5 languages ↔ Accept-Language ↔ 018 timezone ↔ S12 geolocation}. Assign each coupled set to one
  engineer.
- After each surface: extend `000`, `probe.html`, snapshots, and `validate.py`; run the doc-04
  persistence + coherence checks before calling it done.

## Definition of done

- All 12 surfaces respond to the descriptor; **all** §3.3 dead switches implemented (screen → S2,
  geolocation → S12).
- Every coupled pair validated together with **no CreepJS lie** (doc 04 §8.3).
- `000` propagates every new field; `validate.py` has a rule per new axis; fixtures updated.
- Snapshots regenerated; regression CI green (doc 04).

## Handoff to docs 04 / 05

The identity surface is complete. Doc 04 hardens the persistence/coverage/**coherence** harness
and the rebase-survival snapshots; doc 05 signs + packages and formalizes the launch/descriptor
contract to Raven Browser.
