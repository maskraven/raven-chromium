# GeekEZ Chromium Fingerprint Build — Findings & Design Spec

**Status:** Draft v1.1 — core decisions resolved (see §11), basis for development
**Scope:** Design a custom Chromium build (target milestone 150) that spoofs browser
fingerprints at the C++ source level, producing a **persistent, coherent synthetic
identity per profile** for multi-account / e-commerce operations.
**Supersedes:** the current Electron + Puppeteer + runtime-injection approach, which
operates above the engine and is detectable as such.

---

## 1. Purpose

GeekEZ today spoofs fingerprints from outside the engine (Electron/Puppeteer, JS-level).
Any spoofing done in JavaScript leaves detectable artifacts (wrong `toString()` on patched
functions, property-descriptor mismatches, CDP leaks). The goal of this work is to move
fingerprint modification **into the Chromium binary itself**, so the spoofed values are
reported natively with no JS shim to detect — and to make each profile's fingerprint
**stable across sessions** (unlike privacy browsers, which randomize to prevent tracking).

This document records what we learned surveying the field, the technical baseline we will
build on, its gaps, and the target architecture.

---

## 2. Landscape findings

### 2.1 Closed-source products (what we are competing with / not copying)

- **CloakBrowser (CloakHQ).** Markets "66 source-level C++ patches." The patches are **not
  published** — the GitHub repo is only the MIT wrapper (Python/JS/.NET); the patched
  Chromium is a proprietary binary downloaded at runtime. The number is inconsistent across
  their own materials (58 / 59 / 66 depending on the page and platform), i.e. a marketing
  figure, not an auditable patch series. Categories advertised: canvas, WebGL, WebGPU,
  audio, fonts, hardware concurrency, device memory, client rects, GPU strings, screen,
  WebRTC, timezone, automation-signal removal, CDP input mimicking.
- **BotBrowser, Multilogin, Kameleo, AdsPower, GoLogin** — same closed-binary model; useful
  as feature checklists, not as source references. BotBrowser is the most transparent of
  these (publishes *selected* example patches + target source tree; core stays private).

### 2.2 Open-source references (what we can actually read and borrow from)

| Project | Engine | License | Value to us |
|---|---|---|---|
| **fingerprint-chromium** (adryfish) | Chromium (ungoogled) | BSD-3 / MPL parts | **Our baseline.** 144 patch set is public; 148 source was **not released**. |
| **Brave** (brave-core) | Chromium | MPL-2.0 | Best-engineered fingerprint code in the open. Broadest surface coverage; strong PRNG. Opposite *goal* (see §5). |
| **Cromite** (uazo) | Chromium (Android) | GPL/BSD | Clean published `.patch` series for canvas/rects noise. |
| **Camoufox** (daijro) | Firefox | MPL-2.0 | Not Chromium, but best-documented anti-detect design; core spoofing kept closed. |

**Key takeaway:** the honest reference implementation is fingerprint-chromium for the
*persistence model* and Brave for the *coverage and value-plausibility*. Our design combines
the two.

---

## 3. Technical baseline — fingerprint-chromium 144

The public build is **ungoogled-chromium 144.0.7559.132** plus one folder,
`patches/extra/fingerprint/`, containing **16 patches** wired in via `patches/series`.

### 3.1 The seed architecture

Everything derives from a single master command-line seed, `--fingerprint=<int>`, propagated
from the browser process into every renderer (`render_process_host_impl.cc`). Each surface
reads the seed and derives its value **deterministically** (via `std::hash`), so the same
seed reproduces the same fingerprint forever. Companion switches registered in patch `000`:

`--fingerprint-brand`, `--fingerprint-brand-version`, `--fingerprint-platform`,
`--fingerprint-platform-version`, `--fingerprint-hardware-concurrency`,
`--fingerprint-screen-width`, `--fingerprint-screen-height`,
`--fingerprint-device-scale-factor`, `--fingerprint-location`, `--timezone`,
`--disable-spoofing=<surface,...>`.

### 3.2 The 16 patches

| # | Patch | Layer / file | What it does |
|---|---|---|---|
| 000 | add-fingerprint-switches | `components/ungoogled/ungoogled_switches.*`, `render_process_host_impl.cc` | Registers switches; propagates browser→renderer |
| 001 | disable-runtime.enable | `v8/src/inspector/v8-runtime-agent-impl.*` | Neuters `Runtime.enable` — defeats the CDP automation-detection leak |
| 002 | user-agent-fingerprint | UA + Client Hints | Spoofs UA string, brand, platform, platform-version |
| 003 | audio-fingerprint | `webaudio/offline_audio_context.cc` | Seeded ±0.01 noise on sample rate + frame count |
| 005 | hardware-concurrency | `navigator_concurrent_hardware.cc`, `navigator_device_memory.cc` | Spoofs `hardwareConcurrency` from seed; **hardcodes `deviceMemory` to 8** |
| 006 | font-fingerprint | font matching | Font enumeration spoofing |
| 007 | shadow-root | `dom/element.*` | Adds `fakeShadowRoot` (closed-shadow-root access for automation) |
| 009 | webdriver | `core/frame/navigator.cc` | Removes forced `navigator.webdriver === true` |
| 010 | headless | `headless_browser_impl.cc` | Renames `HeadlessChrome` → `Chrome` in UA |
| 011 | gpu-info | GPU info | Spoofs WebGL `UNMASKED_VENDOR/RENDERER` strings |
| 012 | canvas-get-image-data | `base_rendering_context_2d.cc`, `static_bitmap_image.cc` | Deterministic LSB perturbation of ≤10 edge pixels, keyed by `hash(seed+coords)` |
| 013 | canvas-toDataURL | encode path | Same noise on `toDataURL` |
| 014 | client-rects | client rects | Noise on `getClientRects`/`getBoundingClientRect` |
| 015 | canvas-measure-text | `base_rendering_context_2d.cc` | Noise on `measureText` metrics |
| 016 | webgl-readPixels | `webgl_rendering_context_base.cc` | Applies canvas noise to WebGL `readPixels` |
| 018 | timezone | `timezone_controller.cc` | `--timezone` overrides ICU zone + notifies V8 |

(004, 008, 017 are unused numbers — 16 files total.)

### 3.3 Verified gaps in the baseline (do not inherit these as "done")

- **Dead switches:** `--fingerprint-screen-width`, `--fingerprint-screen-height`,
  `--fingerprint-device-scale-factor`, and `--fingerprint-location` are **registered but
  consumed by no patch**. Screen geometry and geolocation are *not* actually spoofed.
- **Weak PRNG:** derivation is `std::hash<std::string>{}(...) & 1` — a non-cryptographic
  stdlib hash reduced to one bit. Adequate for "nudge a value," poor as a randomness source.
- **Missing surfaces** (no patch touches these): WebRTC IP, WebGPU adapter, media-device
  enumeration, speech-synthesis voices, `navigator.plugins`/mimeTypes, `navigator.languages`,
  keyboard layout, full screen properties (`colorDepth`, `pixelDepth`, `availWidth`,
  `devicePixelRatio`), sensor APIs. WebRTC/WebGPU/battery are only *disabled/limited* by
  inherited ungoogled/Bromite patches, not spoofed to a consistent identity.

**Conclusion:** the baseline is a focused core set (~13 spoofing + 3 automation-hiding
patches), **not comprehensive.** The additional surfaces below are the work.

---

## 4. Brave as the coverage/quality reference

Brave's farbling (source: `brave-core`) is the best open implementation, but built for the
**opposite goal** — see §5. What we borrow is its *coverage* and *value plausibility*:

- **PRNG:** `FarblingPRNG = absl::random_internal::randen_engine<uint64_t>` — AES-based,
  cryptographically strong, statistically uniform. (`components/brave_shields/core/common/farbling_prng.h`)
- **Surfaces farbled** (from `browser/farbling/` browsertests, ~18): canvas, offscreen-canvas,
  WebGL, **WebGPU**, WebAudio, **enumerateDevices (media)**, hardwareConcurrency, deviceMemory,
  **navigator.languages**, **plugins**, **USB**, userAgent, **keyboard API**,
  **speech-synthesis voices**, **screen / pointer coordinates**, **dark-mode**,
  **font allowlist**.
- **Mechanisms worth copying:** `PerturbPixels` (broad LSB canvas noise), `FarbleAudioChannel`
  (per-origin fudge-factor multiplier ≈1.0), `FarbleInteger(key, spoof, min, max)`
  (shape-preserving integer jitter), `AllowFontFamily` (font allowlisting).

**Bold** items above are the surfaces our baseline lacks — the target feature set for this build.

---

## 5. The design decision: persistence vs. randomization

The two references have opposite objectives, and our build must be explicit about which it is:

| | Brave (anti-tracking) | **GeekEZ target (anti-detection)** |
|---|---|---|
| Goal | Make you **un-linkable** — different value per site, per session | Present a **stable, coherent fake identity** that persists |
| Seed | Random session token, `HMAC-SHA256` mixed with eTLD+1, per storage area | **One profile seed / descriptor**, identical across sites & sessions |
| Over time | Values change every restart (by design) | Values **never change** for a given profile |
| Automation hiding | None (it's a real user's browser) | Required (webdriver/headless/CDP patches) |

**We take Brave's coverage + value-generation, but re-point it from Brave's per-session
RANDEN seed to our persistent profile seed.** That single substitution converts
"randomize-to-hide" into "fix-to-impersonate."

---

## 6. Target architecture (Chromium 150)

### 6.1 Core principle

Every surface derives its value from a **deterministic, per-surface function of the profile
seed**, computed once and cached for the process lifetime:

```
surface_seed = keyed_hash(profile_seed, "webgpu")     // SipHash/HMAC, NOT raw std::hash
FarblingPRNG prng(surface_seed)                        // reuse Brave's randen_engine
value        = generate_plausible_value(prng)          // Brave-style shape-preserving logic
// cache value for process lifetime
```

Two upgrades over the baseline fall out of this:

1. **Replace `std::hash & 1` with Brave's `randen_engine`.** Lift `farbling_prng.h`
   (MPL-2.0 — keep MPL headers on those files; compatible in the BSD/ungoogled tree).
   Brave-quality randomness, our persistence.
2. **Seed the PRNG from `--fingerprint` (or the profile descriptor), not a session token.**
   Deterministic and stable across restarts.

### 6.2 Coherence model (the make-or-break requirement)

For a persistent persona, **internal contradiction is a stronger detection signal than no
spoofing.** Do **not** derive identity axes independently from the seed. The identity is a
structured **profile descriptor** — a **JSON document** passed at launch via
`--fingerprint-profile=<path-to-json>` (decision §11.1) — and each patch reads its field. The
existing thin switches (`--fingerprint`, `--timezone`, `--fingerprint-platform`, …) remain as
per-field overrides for quick testing:

```jsonc
// profile.json (one entry from the real-device DB)
{
  "seed": 4815162342,                         // drives within-profile jitter
  "os": "Windows 11", "platform": "Win32",
  "gpu": { "vendor": "Google Inc. (NVIDIA)",
           "renderer": "ANGLE (NVIDIA, NVIDIA GeForce RTX 3060 ...)" },
  "locale": "en-US", "languages": ["en-US","en"], "timezone": "America/New_York",
  "screen": { "w": 1920, "h": 1080, "dpr": 1.0, "colorDepth": 24 },
  "chrome": "150", "hardwareConcurrency": 12, "deviceMemory": 8
}
   → platform / UA / Client Hints / navigator.platform
   → WebGL + WebGPU vendor+renderer
   → languages + Accept-Language + keyboard layout
   → screen + DPR + color/pixel depth
   → font set + speech voices
   → timezone
```

The profile fixes the **identity axes** (must co-vary like a real device); the seed only
drives **within-profile jitter** (canvas noise, device counts, etc.).

**Profile source (decision §11.2): a curated database of *real captured devices*, not
synthesized attribute combinations.** Every axis combination shipped must be one that
actually exists in the wild (a real Win11 + RTX 3060 + en-US machine reports a specific,
mutually-consistent set of values). Synthesizing combinations is how anti-detect builds
produce contradictions that CreepJS flags. The DB is a build/runtime asset, versioned
separately, with a schema validator in CI.

### 6.3 Surfaces to implement

Existing 16 patches are rebased and kept. New patches, each following the baseline pattern
(read descriptor/seed → derive → override at Blink layer). **Paths are from the 144 tree —
verify against 150.**

| Surface | Patch target (Blink) | Persisted value |
|---|---|---|
| **WebGPU adapter** | `modules/webgpu/gpu_adapter{,_info}.cc` | Descriptor-picked (vendor, architecture, device); limits/features set |
| **Media devices** | `modules/mediastream/media_devices.cc` | Seed-derived device count + stable synthetic `deviceId`/`groupId` salt; strip labels |
| **navigator.languages** | `core/frame/navigator.cc` **+ Accept-Language (`//net`)** | From descriptor locale; JS **and** HTTP header must match |
| **plugins/mimeTypes** | `core/frame/navigator_plugins.cc` | Real Chrome PDF-viewer set matching descriptor OS |
| **WebUSB** | `modules/webusb/usb.cc` | Stable empty/small `getDevices()` (low priority) |
| **Keyboard API** | `modules/keyboard/keyboard_layout_map.cc` | Layout map from descriptor locale |
| **Speech voices** | `modules/speech/speech_synthesis.cc` | Curated voice list matching descriptor OS (high-value gap) |
| **Screen/pointer** | `core/frame/screen.cc`, `local_dom_window.cc`, pointer events | **Implement the dead `--fingerprint-screen-*` switches**; avail ≤ total, DPR ↔ OS, color/pixel depth |
| **Dark mode** | `web_preferences` / preference override | Force `prefers-color-scheme` / `reduced-motion` from descriptor |
| **Fonts** | `platform/fonts/FontCache` / font matching | Expose only descriptor-OS fonts; must agree with canvas/measureText |
| **WebRTC** (decision §11.3) | `//content` + `peer_connection` | **Hard-disable** — block `RTCPeerConnection`/ICE so no local- or real-IP candidate is ever gathered. No spoofing path. |

Extend `000-add-fingerprint-switches` with each new switch + browser→renderer propagation.

### 6.4 Keep from baseline (automation hiding — Brave has none of this)

`001` Runtime.enable, `007` fakeShadowRoot, `009` webdriver, `010` headless. Required because
GeekEZ drives automated sessions; these are what make automation look human. Note: if driving
via CDP/Puppeteer, additional CDP leaks beyond `Runtime.enable` still exist and need review.

---

## 7. Build plan

1. **Base tree (decision §11.4): ungoogled-chromium-150.** Sync to its `150.x.y.z-1` tag; it
   provides the `components/ungoogled/ungoogled_switches` infra that patch `000` extends, the
   privacy hardening, and — usefully here — existing WebRTC IP-handling patches we build the
   hard-disable on. Accept its added rebase surface as a known cost. If the 150 tag lags
   upstream, pin to the latest available ungoogled 150 revision rather than jumping to raw
   Chromium.
2. **Rebase the 16 baseline patches 144 → 150.** Highest-churn files:
   `base_rendering_context_2d.cc`, `webgl_rendering_context_base.cc`,
   `static_bitmap_image.cc`, the V8 inspector. Budget real time here — this treadmill is why
   the upstream 148 source was never released.
3. **Swap in `randen_engine`** and the keyed-hash seed derivation; refactor existing patches
   to use it.
4. **Introduce the profile descriptor** (switch(es) or a JSON blob passed via a switch) and
   the profile database.
5. **Add new surface patches** (§6.3), highest-value first: speech voices, screen/pointer,
   media devices, WebGPU, languages+Accept-Language.
6. **Build:** `gn gen` with ungoogled `flags.gn` args; target `chrome`. Expect multi-hour
   builds, ~100 GB, full depot_tools toolchain. Reuse the baseline's `.cirrus.yml` CI path or
   a distributed build (reclient) for iteration speed.
7. **Package** into GeekEZ per existing macOS/Windows/Linux release pipeline.

---

## 8. Validation plan

Validate in this order — most builds pass 1–2 and fail 3:

1. **Persistence:** same profile seed across restarts → byte-identical fingerprint outputs
   (automated diff).
2. **Coverage:** CreepJS, browserleaks.com, amiunique.org, EFF Cover Your Tracks, Brave's
   farbling test page, fingerprint.com demo.
3. **Coherence (the real test):** CreepJS "lies"/entropy detector flags contradictory spoofs
   (e.g., UA=Windows but WebGL renderer=Apple, or DPR inconsistent with screen size). A
   profile passes only if no axis contradicts another.
4. **Regression harness:** snapshot expected values per profile; fail CI on drift after each
   Chromium rebase.

---

## 9. Risks & caveats

- **Rebase maintenance is the dominant ongoing cost.** Every Chromium milestone can break
  hunks. Plan for a recurring rebase + revalidate cycle.
- **Source patches only cover the JS/DOM layer.** Modern detectors (DataDome, Kasada,
  fingerprint.com) also use TLS/JA4, HTTP/2 frame ordering, and server-side behavioral
  signals. Those need network-stack / proxy work (GeekEZ already integrates Xray — coordinate
  there) and are out of scope for the Blink patches.
- **WebRTC hard-disable is a (minor) signal in itself.** A browser with no `RTCPeerConnection`
  at all is slightly unusual for stock Chrome. It's a defensible, privacy-consistent choice and
  eliminates the far worse real-IP leak, but note the tradeoff: if a future profile needs to
  *look* like it has WebRTC, we'd have to revisit and spoof ICE to the proxy IP instead. For
  now (decision §11.3) absence beats leakage.
- **Persistence trades anti-tracking for anti-detection.** A stable fingerprint is itself a
  durable tracking handle. Two "isolated" profiles that collide on a seed become linkable —
  keep the profile/seed space large and unique per profile.
- **Coherence debt:** every new spoofed axis is another chance to contradict an existing one.
  Grow the descriptor deliberately, not ad hoc.

---

## 10. Scope & compliance note

This technology is dual-use. Legitimate uses — the ones GeekEZ targets (managing multiple
e-commerce storefronts/accounts, QA across device profiles, ad verification, privacy) — are
lawful and are the reason an anti-detect browser category exists commercially. The same
persistence enables abuse (ban evasion, mass fraudulent account creation), which is often a
platform-ToS violation and, for fraud, illegal. This build is scoped to the legitimate
multi-account/e-commerce use case; abuse-enabling features beyond that (e.g. tooling for
bulk automated account creation) are explicitly out of scope.

---

## 11. Resolved decisions (v1.1)

| # | Decision | Choice | Implication |
|---|---|---|---|
| 11.1 | Descriptor transport | **JSON descriptor** via `--fingerprint-profile=<path>`; thin `--fingerprint-*` switches kept as overrides | One coherent identity object; per-patch reads a field (§6.2) |
| 11.2 | Profile database source | **Curated real-device set** (real captured devices, not synthesized combos) | Versioned DB asset + CI schema/consistency validator (§6.2) |
| 11.3 | WebRTC | **Hard-disable** `RTCPeerConnection`/ICE | No IP leak; no spoof path; minor "absent WebRTC" signal accepted (§6.3, §9) |
| 11.4 | Base tree | **ungoogled-chromium-150** | Switch infra + privacy + WebRTC IP patches; accept added rebase surface (§7.1) |

### Still open (not blocking initial coding)

- Exact JSON schema for the descriptor (field names, versioning) — settle alongside the first
  `000` switch patch.
- Real-device DB sourcing/collection method and how many seed profiles to ship at v1.
- Whether the descriptor is embedded in GeekEZ per-profile storage or passed as a temp file at
  launch.

---

## 12. References

- fingerprint-chromium 144 patch set — local: `fingerprint-chromium-144.0.7559.132/patches/extra/fingerprint/`
- Brave farbling — `brave-core`: `third_party/blink/renderer/core/farbling/brave_session_cache.{h,cc}`,
  `components/brave_shields/core/common/farbling_prng.h`, `browser/farbling/*`
- Brave, "Fingerprinting Defenses 2.0" — https://brave.com/privacy-updates/4-fingerprinting-defenses-2.0/
- Cromite anti-fingerprinting — https://github.com/uazo/cromite
- CloakBrowser (closed reference) — https://github.com/CloakHQ/CloakBrowser
