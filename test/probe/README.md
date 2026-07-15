# test/probe/ — fingerprint probe + comparator (Plan 04)

The validation scaffold for Plan 04 (§8 validation ladder). Two artifacts:

| file | role |
|---|---|
| `fingerprint-probe.html` | self-contained, offline, CSP-safe page that reads **every** web-observable fingerprint surface and emits a canonical (recursively key-sorted) JSON snapshot + a top-level SHA-256. |
| `compare.py` | stdlib-only python3 gate: **PERSISTENCE** (byte-identical across restarts) + **COHERENCE** (zero cross-axis contradictions). Exit 0 = pass. |

The built browser does **not** exist yet — this harness is stood up ahead of it so the net
goes up "right after 01" (Plan 04 T4.2). Until `--fingerprint-profile` lands (Plan 02), drive the
early build with the baseline `--fingerprint=<int>` smoke flag; switch to the descriptor below once
Plan 02 is in.

## The probe page

`fingerprint-probe.html` runs entirely on load. No external resources (verified: no
`http(s)://`, no `src=`/`href=`/`@import`, no `fetch`/XHR/WebSocket), no `eval`, no inline event
handlers — a single inline `<script>` + inline `<style>` under a self-imposed strict CSP
(`default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; connect-src 'none'`).
It works from `file://` or loopback HTTP. SHA-256 uses `crypto.subtle` with a verified pure-JS
fallback for non-secure contexts.

**Surfaces captured** (each defended with try/catch; unreachable ones record `"unavailable"`; async
ones are awaited and timeboxed before the snapshot finalizes):

- **navigator** — userAgent, appVersion, platform, vendor, language, languages,
  hardwareConcurrency, deviceMemory, maxTouchPoints, webdriver, pdfViewerEnabled, cookieEnabled,
  doNotTrack, connection/permissions presence.
- **navigator.userAgentData** — brands, mobile, platform, and
  `getHighEntropyValues(['architecture','bitness','model','platformVersion','uaFullVersion','fullVersionList','wow64'])`.
- **screen** — width, height, availWidth, availHeight, colorDepth, pixelDepth, devicePixelRatio,
  orientation.type.
- **window** — inner/outer sizes, `matchMedia` resolution (DPR-desync cross-check),
  prefers-color-scheme, prefers-reduced-motion.
- **Intl / time** — `Intl.DateTimeFormat().resolvedOptions()` timeZone/locale/numberingSystem/calendar,
  `Date().getTimezoneOffset()`.
- **Canvas 2D** — fixed scene (rects, gradient, text with an emoji, arc, filled path); SHA-256 of
  `toDataURL()` and of `getImageData()` bytes.
- **WebGL1 + WebGL2** — VENDOR/RENDERER/VERSION, UNMASKED_VENDOR/RENDERER, a fixed getParameter set
  (max sizes, bit depths, aliased ranges, anisotropy), sorted supported-extensions list, and a
  SHA-256 of `readPixels()` after a fixed shader draw.
- **WebGPU** — guarded `requestAdapter()` → adapter info (vendor/architecture/device/description),
  a fixed key-limits set, and features (records `available:false` when absent).
- **AudioContext** — `OfflineAudioContext` fixed oscillator→compressor render; SHA-256 of a fixed
  sample window + abs-sum.
- **Fonts** — measurement-based detection (offsetWidth/Height vs monospace/serif/sans-serif
  baselines) over a fixed ~70-font candidate list → sorted "present" list.
- **Plugins / mimeTypes** — sorted name/type lists.
- **mediaDevices.enumerateDevices** — counts by kind + whether labels are populated.
- **speechSynthesis.getVoices** — count + sorted name/lang list (awaits `voiceschanged`).
- **WebRTC** — `RTCPeerConnection` presence + constructability (Raven hard-disables it → recorded
  as `disabled`/`enabled`).
- **feature presence** — performance.memory, crypto.subtle, webgl, webgpu, offline audio,
  speechSynthesis, usb, bluetooth, keyboard.getLayoutMap, geolocation.

**Outputs when ready:**
- `window.__RAVEN_FP__ = { hash, snapshot, canonical, probeVersion }`
- `document.title = 'FP:' + hash`
- `<div id="ready" data-ready="1">ready</div>` — the automation wait flag.
- The pretty JSON + hash are also rendered on the page.

The snapshot contains **zero time-varying data** (no timestamps, no RNG) so the same descriptor
must produce a byte-identical snapshot across restarts.

## The comparator

```
python3 compare.py A.json B.json        # exit 0 iff persistent AND coherent
python3 compare.py --help
```

Each input is either a raw snapshot or the full `window.__RAVEN_FP__` payload (`{hash, snapshot}`).

- **Persistence** — if both files carry a top-level `hash` (same engine → directly comparable), the
  authoritative check is `hashA == hashB`; otherwise a Python-side canonical (recursively
  key-sorted, compact) byte comparison. On divergence it prints a per-key `added/removed/changed`
  diff so the non-deterministic surface is obvious.
- **Coherence** — basic cross-axis assertions (mirrors Plan 02's `validate.py`, observed live):
  UA Chrome major == userAgentData Chrome major; `languages[0]` subtag == Intl locale subtag;
  `navigator.platform` consistent with the UA OS token; timezone present and not the UTC default
  (a spoof tell). Missing inputs → `skip`, contradictions → `fail`.

## The Plan 04 loop (via chrome-devtools MCP)

Persistence + regression drive the built browser through the `chrome-devtools` MCP:

1. **Launch** the built browser with a fixed descriptor —
   `--fingerprint-profile=fixtures/win11-nvidia-enus.json` (or the baseline `--fingerprint=<int>`
   before Plan 02) — **on a matching-OS runner** (personas are host-OS/GPU-class constrained; a
   Linux runner cannot produce a valid Win11 snapshot).
2. **Navigate** to `fingerprint-probe.html` served over **loopback HTTP** (not `file://` — some APIs
   differ; Plan 04 T4.1).
3. **Wait** for the ready flag: MCP `wait_for` on the `#ready[data-ready="1"]` element, or poll the
   title for the `FP:` prefix.
4. **Read** the result: MCP `evaluate_script` returning `window.__RAVEN_FP__` → save as
   `dump_A.json`.
5. **Restart** the browser with the *same* descriptor on a clean profile dir and repeat →
   `dump_B.json`. Also capture a *different* descriptor → `dump_D.json`.
6. **Gate** with `compare.py`:
   - `compare.py dump_A.json dump_B.json` must exit 0 (**byte-identical + coherent**).
   - `compare.py dump_A.json dump_D.json` must show persistence **FAIL** (proves no accidental
     constant — Plan 04 T4.2 step 4).
   - Freeze the accepted snapshot under `test/snapshots/<profile>.json` for the regression gate
     (T4.5); regenerate only via a reviewed `make update-snapshots` after an intentional rebase.

**Caveat (spec §6.4):** if driving via CDP, run at least one pass **without** an automation driver
(manual or a non-CDP launcher) so the harness itself doesn't mask a CDP leak. Record which mode
produced each snapshot.

## External targets (coverage + coherence — Plan 04 T4.3/T4.4)

The manual/driven pass points a shipped profile at, and archives results under
`test/coverage/<date>/` from: **CreepJS** (primary — its lies/entropy detector must report **zero**
contradictions), **browserleaks.com** (canvas/webgl/webrtc/fonts/screen/audio),
**amiunique.org**, **EFF Cover Your Tracks**, the **Brave farbling test page**, and the
**fingerprint.com demo**. A profile ships only when CreepJS is clean (spec §8.3, §6 DoD).
