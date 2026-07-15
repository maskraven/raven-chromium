# Integrating a Third-Party App with Raven Chromium

**Status:** v1 (2026-07-14) · Pairs with [`docs/contract/launch-contract-v1.md`](../contract/launch-contract-v1.md) (the normative contract) · Pin: Chromium **150.0.7871.114**

This is the practical, end-to-end guide for a host application (Raven Browser, an automation
service, a QA harness, or any integrator) that wants to **launch and drive Raven Chromium** with a
chosen fingerprint persona. The contract file is the source of truth for what is *stable*; this guide
shows you *how to use it*.

> **Scope & lawful use.** Raven Chromium is a fingerprint-managed Chromium fork for lawful
> multi-account operations, e-commerce, and QA. Every persona presents as a coherent, ordinary
> Chrome install — nothing identifies the tool. Do not use it to impersonate a specific real person,
> defeat fraud controls you are not authorized to test, or violate a site's terms. Integrators own
> compliance for their use case.

---

## 1. Mental model

Your app never links against Chromium source and never speaks a private RPC. There is exactly **one
coupling surface**, and it is deliberately tiny:

```
┌─────────────────┐   1. write descriptor.json   ┌──────────────────────────┐
│   Your app      │ ───────────────────────────▶ │  persona.json (on disk)  │
│ (Raven Browser, │                              └──────────────────────────┘
│  automation, …) │   2. launch with CLI flags            │ read once, validated
│                 │ ─────────────────────────────────────▶│ in the BROWSER process
│                 │        --fingerprint-profile=<path>   ▼
│                 │                              ┌──────────────────────────┐
│                 │   3. drive over DevTools     │     Raven Chromium        │
│                 │ ◀───────────────────────────▶│  (signed per-OS binary)   │
└─────────────────┘     CDP / remote-debugging   └──────────────────────────┘
```

Three moves, in order:

1. **Build a descriptor** — a small JSON file describing the persona (OS, GPU, screen, locale, …).
2. **Launch** the signed binary with `--fingerprint-profile=<path>` and a per-persona `--user-data-dir`.
3. **Drive** it over the standard Chrome DevTools Protocol (CDP), or just let a user interact.

The browser reads the descriptor **once**, validates it, and propagates it internally to every
renderer. Your app does not touch renderers, seeds, or any internal switch.

**What you rely on (guarantees, see §9):** same descriptor ⇒ byte-identical fingerprint across
restarts; identity axes co-vary and never contradict; nothing leaks the tool's identity; WebRTC is
disabled; a persona is valid only on its matching-OS binary.

---

## 2. Prerequisites: obtain and verify a binary

Your app consumes **signed binaries only — never source.**

### 2.1 Artifact naming

```
raven-chromium-<version>-<os>-<arch>[.<ext>]
```

| Example | OS | Notes |
|---|---|---|
| `raven-chromium-150.0.7871.114-linux-x64.tar.xz` | Linux | ships `chrome` + `raven-launch.sh` + swappable `libffmpeg.so` |
| `raven-chromium-150.0.7871.114-win-x64.zip` | Windows | `chrome.exe`, codecs bundled |
| `raven-chromium-150.0.7871.114-macos-arm64.dmg` | macOS | notarized `.app`, codecs bundled |

### 2.2 Verify before launch (mandatory)

Every release ships `SHA256SUMS` plus a detached signature:

- **Linux** — detached GPG signature over `SHA256SUMS`.
- **macOS** — `codesign`/notarization on the `.app` (verify with `spctl`/`codesign --verify`).
- **Windows** — Authenticode signature on `chrome.exe` (verify with `signtool`/WinVerifyTrust).

```bash
# Linux example
gpg --verify SHA256SUMS.asc SHA256SUMS          # trust the signer
sha256sum -c SHA256SUMS                          # integrity of the artifact
```

Never launch an artifact that fails either check.

### 2.3 Version pinning

A host-app release declares the exact Raven Chromium `<version>` it targets — matches
`build/PINS` `chromium_tag` (currently **150.0.7871.114**). Do not mix a descriptor/app built for one
milestone with a binary from another; the descriptor's `chromeMajor` should track the binary.

---

## 3. Step 1 — Build a descriptor

The descriptor is a JSON object whose keys mirror the JS-observable names exactly. Canonical schema:
[`profile-db/schema/descriptor.schema.json`](../../profile-db/schema/descriptor.schema.json)
(JSON Schema draft 2020-12).

### 3.1 A complete, valid descriptor

```json
{
  "schemaVersion": 1,
  "seed": 11111111111111111111,
  "os": "windows",
  "platform": "Win32",
  "chromeMajor": 150,
  "hardwareConcurrency": 12,
  "deviceMemory": 8,
  "gpu": {
    "vendor": "Google Inc. (NVIDIA)",
    "renderer": "ANGLE (NVIDIA, NVIDIA GeForce RTX 3060 (0x00002504) Direct3D11 vs_5_0 ps_5_0, D3D11)",
    "architecture": "ampere",
    "device": "NVIDIA GeForce RTX 3060"
  },
  "screen": {
    "w": 1920, "h": 1080, "dpr": 1,
    "colorDepth": 24, "pixelDepth": 24,
    "availW": 1920, "availH": 1032
  },
  "languages": ["en-US", "en"],
  "locale": "en-US",
  "timezone": "America/New_York"
}
```

The repo ships 8 source-verified real-device personas in
[`profile-db/personas/`](../../profile-db/personas/) and 3 minimal contract examples in
[`profile-db/fixtures/`](../../profile-db/fixtures/) — **start from one of these** rather than
authoring from scratch. Every persona is backed by a HIGH-confidence WebGL parameter bundle in
[`profile-db/webgl/webgl-gpu-params.json`](../../profile-db/webgl/webgl-gpu-params.json).

### 3.2 Field reference (frozen v1 — names never change within major v1)

| Field | Type | JS surface | Rules |
|---|---|---|---|
| `schemaVersion` | int **const 1** | — | Unknown major ⇒ hard fail (profile stays INACTIVE, host values untouched). |
| `seed` | uint64 (number **or** decimal string) | — (internal only) | Drives **only** within-profile jitter (canvas LSB, audio fudge). **Never** an identity axis. Use a string if it exceeds JS `Number.MAX_SAFE_INTEGER`. |
| `os` | `windows` \| `macos` \| `linux` | — | Governs plausible GPU/platform. Must match the binary's OS. |
| `platform` | `Win32` \| `MacIntel` \| `Linux x86_64` | `navigator.platform` | Must agree with `os`. **`MacIntel` even on Apple Silicon** — Chrome never reports `arm`. |
| `chromeMajor` | int [140, 200] | UA + `Sec-CH-UA` | Track the binary milestone (150). |
| `hardwareConcurrency` | int [2, 256], **even** | `navigator.hardwareConcurrency` | Realistic core count. |
| `deviceMemory` | `{0.25,0.5,1,2,4,8}` | `navigator.deviceMemory` | Blink clamps to **≤ 8**; realistic personas use `4` or `8`. |
| `gpu.vendor` | string | `UNMASKED_VENDOR_WEBGL` | e.g. `Google Inc. (NVIDIA)`. |
| `gpu.renderer` | string | `UNMASKED_RENDERER_WEBGL` | Full ANGLE string. Must be plausible for `os` (no Direct3D off Windows, no Metal/Apple off macOS, no Mesa off Linux). |
| `gpu.architecture` | string | `GPUAdapterInfo.architecture` | e.g. `ampere`, `apple-gpu`, `gen-9`. |
| `gpu.device` | string | `GPUAdapterInfo.device` | e.g. `NVIDIA GeForce RTX 3060`. |
| `screen.{w,h}` | int | `screen.width/height` | logical px. |
| `screen.dpr` | number | `devicePixelRatio` | sane set `{1, 1.25, 1.5, 1.75, 2, 2.25, 2.5, 3}`. |
| `screen.{colorDepth,pixelDepth}` | `24` \| `30` | `screen.colorDepth/pixelDepth` | must be **equal**. |
| `screen.{availW,availH}` | int | `screen.availWidth/Height` | `availW ≤ w`, `availH ≤ h`. |
| `languages` | string[] (BCP-47) | `navigator.languages` | `languages[0]` is the **single source** for `Accept-Language`; must share `locale`'s primary subtag. |
| `locale` | BCP-47 `lang-REGION` | default locale | region must be plausible for `timezone`. |
| `timezone` | IANA tz name | tz + geo | **single source** for geolocation & timezone; must match `locale` region. |
| `extensions` | object (optional) | — | Forward-compat block for post-v1 additive fields; ignored by the v1 parser. |

### 3.3 Coherence — the real gate

Structural validity is not enough. The binary supports **only** descriptors that also pass
cross-axis coherence. The rules the validator enforces:

- `platform` ↔ `os` (exact mapping above).
- `gpu.*` ↔ `os` — the **host-OS/GPU-match** rule: no Apple/Metal off macOS, no Direct3D/D3D off
  Windows, no Mesa off Linux.
- `languages[0]` ↔ `locale` — same primary language subtag (and region if both carry one).
- `locale` region ↔ `timezone` — e.g. `en-US` ⇒ an `America/*` (or US Pacific) zone.
- `screen` — `availW ≤ w`, `availH ≤ h`, `colorDepth == pixelDepth ∈ {24,30}`, `dpr` in the sane set.
- `hardwareConcurrency` even and in `[2,256]`; `chromeMajor ≥ 140`.

### 3.4 Validate every descriptor before you launch

```bash
python3 profile-db/validate.py path/to/persona.json      # PASS or a list of FAIL reasons
python3 profile-db/validate.py --all profile-db/personas/ # batch; exit 0 = all pass
```

`validate.py` is **stdlib-only** (no pip, no venv) — vendor it into your build/CI and gate persona
authoring on it. Same rules run inside the C++ parser at launch, so a descriptor that fails here will
be rejected (INACTIVE) at runtime.

**Do / Don't**

- ✅ Reuse a shipped persona; change only what you must; re-validate.
- ✅ Keep `seed` stable per persona — it is what makes the fingerprint reproducible across restarts.
- ❌ Don't hand-derive identity axes from the seed; identity is verbatim, seed is jitter-only.
- ❌ Don't mix a macOS GPU with `os: windows` (or any cross-OS combo) — it fails coherence and, even
  if forced, would not render coherently (see §8 host-match).

---

## 4. Step 2 — Launch

### 4.1 CLI surface

| Switch | Meaning | Stability |
|---|---|---|
| `--fingerprint-profile=<path>` | Path to the descriptor JSON (§3). The **browser** reads + validates it once and propagates internally. **Primary interface.** | **STABLE** |
| `--user-data-dir=<path>` | Per-persona profile isolation (standard Chromium). **One data dir per persona.** | **STABLE** (Chromium) |
| `--fingerprint-ffmpeg=<path>` | *(Linux launcher only, `raven-launch.sh`)* install a licensed Chrome-branded `libffmpeg.so` to enable H.264/AAC. See §7. | STABLE (launcher) |

**Internal — never pass, never depend on:** `--fingerprint-profile-data` (the base64 blob the browser
injects into renderers). Passing it directly bypasses validation.

**Testing-only overrides (UNSTABLE — do NOT ship against these):** the thin per-field switches from
baseline patch `000` — `--fingerprint`, `--fingerprint-platform`, `--fingerprint-hardware-concurrency`,
`--timezone`, `--fingerprint-screen-width/height`, etc. Precedence is
**`default < descriptor < per-field switch`**, so these override the descriptor. Use only for manual
debugging.

### 4.2 Recommended launch flags

```
<binary> \
  --fingerprint-profile=/persona/store/acct-42/descriptor.json \
  --user-data-dir=/persona/store/acct-42/udd \
  --no-first-run \
  --no-default-browser-check
```

**Flags to AVOID** (they leak "this is automation" and break guarantee #3):

- ❌ `--enable-automation` — adds the "controlled by automated test software" infobar and sets
  `navigator.webdriver = true`.
- ❌ `--headless=old` — the legacy headless leaks `HeadlessChrome` in the UA. If you need headless,
  use **`--headless=new`** (the fork's scrubbing keeps the UA clean; validated against bot.sannysoft).
- ⚠️ For maximum fidelity (real WebGL rendered pixels — see §8), prefer **headful** on a host with a
  real GPU (Linux: run under Xvfb/real X only if a GPU is present).

### 4.3 Per-OS launch

- **Windows:** `chrome.exe --fingerprint-profile=… --user-data-dir=…`
- **macOS:** `"<Bundle>.app/Contents/MacOS/<exe>" --fingerprint-profile=… --user-data-dir=…`
- **Linux (codecs off / default):** `./chrome --fingerprint-profile=… --user-data-dir=…`
- **Linux (codecs on):** `./raven-launch.sh --fingerprint-ffmpeg=/path/chrome-libffmpeg.so --fingerprint-profile=… --user-data-dir=…` (see §7).

---

## 5. Step 3 — Drive it (DevTools Protocol)

Raven Chromium is standard Chromium underneath, so you drive it with the **Chrome DevTools Protocol
(CDP)** exactly as you would stock Chrome. The recommended pattern preserves the no-leak guarantee:
**your app launches the binary with the controlled flag set above, then attaches a CDP client** —
rather than letting an automation library launch with its own (leaky) default flags.

### 5.1 Open a debugging endpoint

Add one of:

- `--remote-debugging-port=<port>` — TCP; discover the WebSocket URL from
  `http://127.0.0.1:<port>/json/version` → `webSocketDebuggerUrl`. Bind to loopback only.
- `--remote-debugging-pipe` — file-descriptor pipe (no open port; preferred for hardened setups).

> CDP itself does **not** set `navigator.webdriver` — only `--enable-automation` / legacy headless do.
> Attaching over CDP to a normally-launched instance keeps the persona clean.

### 5.2 Attach (Playwright / Puppeteer — `connectOverCDP`)

```js
// You launched ./chrome (or raven-launch.sh) yourself with --remote-debugging-port=9222
const { chromium } = require('playwright');           // puppeteer-core is equivalent
const browser = await chromium.connectOverCDP('http://127.0.0.1:9222');
const ctx = browser.contexts()[0] ?? await browser.newContext();
const page = await ctx.newPage();
await page.goto('https://example.com');
// ... your automation ...
await browser.close();  // detaches; your launched process still owns lifecycle (see §10)
```

### 5.3 Attach (raw, stdlib-ish)

```python
import json, urllib.request
port = 9222
ver = json.load(urllib.request.urlopen(f"http://127.0.0.1:{port}/json/version"))
ws_url = ver["webSocketDebuggerUrl"]        # feed to any WebSocket CDP client
# then: Target.createTarget → Page.navigate → Runtime.evaluate, etc.
```

---

## 6. Descriptor delivery & lifetime

- **You write the file; you own its lifecycle.** A per-launch temp file under the persona's
  `--user-data-dir` is recommended.
- The browser reads + base64-encodes the descriptor and forwards it to each renderer via the internal
  `--fingerprint-profile-data` switch; the renderer decodes it once into the process-global
  `fingerprint::Profile`. Identity axes are read verbatim; `seed` drives only jitter.
- **Lifetime rule:** the file **must remain readable for the entire lifetime of the browser process.**
  The encoded descriptor is cached on first renderer spawn, but renderers can spawn at any time.
  Delete it only **after** the browser process exits.

---

## 7. Codecs (H.264 / AAC)

Per-OS model — this is the one axis where the three platforms differ operationally:

| OS | Out of the box | To enable H.264/AAC |
|---|---|---|
| **Windows / macOS** | Decoders **bundled** (`ffmpeg_branding="Chrome"`). `canPlayType`/`MediaCapabilities`/playback report real Chrome support. | Nothing — already on. |
| **Linux** | Ships a **swappable `libffmpeg.so` with no patented decoder.** By default H.264/AAC report **unsupported** — *coherently*: a runtime `avcodec_find_decoder` probe gates `canPlayType`, so the browser never claims a codec it can't decode. | Install a licensed Chrome-branded `libffmpeg.so` via the launcher. |

**Linux enable path (validated end-to-end):**

```bash
./raven-launch.sh \
  --fingerprint-ffmpeg=/path/to/chrome-libffmpeg.so \
  --fingerprint-profile=/persona/…/descriptor.json \
  --user-data-dir=/persona/…/udd
```

The launcher copies your lib to `$ORIGIN/libffmpeg.so` (next to `chrome`) and `exec`s the browser. A
raw `--path`-style switch is impossible: `libffmpeg` is a `DT_NEEDED` library resolved by `ld.so`
**before `main`**, so the file-swap is the only mechanism. The lib must match the shipped ffmpeg ABI
(build it from the same Chromium/ffmpeg tag with `ffmpeg_branding="Chrome"` + `is_component_ffmpeg=true`).

> **Guarantee:** the browser advertises H.264/AAC **iff** it can actually decode them — codec probing
> never produces a contradiction, on any OS. The patent license for a lib you install rests with its
> source, not with Raven Chromium.

**Behavioral contrast (same binary, same file, only the `.so` differs):**

| | Default Linux lib | Chrome lib installed |
|---|---|---|
| `canPlayType('…avc1…')` | `""` | `"probably"` |
| `mediaCapabilities.decodingInfo` | `supported:false` | `supported:true` |
| Load an `avc1` MP4 | error `code 4` (SRC_NOT_SUPPORTED) | `readyState 4`, no error |

---

## 8. Host-match: what a persona can and cannot spoof (v1)

Read this before you assume a persona is undetectable on any machine.

- **Metadata is spoofed regardless of host** — UA, `navigator.*`, screen, languages, timezone, WebGL
  **UNMASKED vendor/renderer strings + all `getParameter` caps + extension list**, WebGPU adapter
  info. These follow the descriptor on any host.
- **WebGL *rendered pixels* are host-GPU-bound.** The actual pixels a shader draws come from the real
  GPU. A persona reaches full fidelity only on a host whose **OS and GPU class match** the persona
  (v1 constraint). Corollary: you can **hide** extensions/values but cannot **add** a capability the
  host GPU lacks.
- **Practical rule for your fleet:** pair each persona to a **matching-OS, matching-GPU-class host**.
  A Windows-NVIDIA persona belongs on a Windows-NVIDIA (or equivalent-ANGLE) host; running it on a
  GPU-less/SwiftShader box spoofs the strings but not the drawn pixels.

Also host-bound (not code): font-metric fidelity for a cross-host persona, and exact macOS GPU
WebGL2 caps for some Apple parts (flagged for live capture).

---

## 9. Guarantees your app can rely on

From the contract (§5–§6). Build against these; they are stable within contract major v1.

1. **Persistence** — same descriptor ⇒ byte-identical fingerprint across restarts.
2. **Coherence** — only `validate.py`-passing descriptors are supported; identity axes co-vary;
   single-source axes never contradict (`languages ↔ Accept-Language`, `UA ↔ Client-Hints`,
   `timezone ↔ geo`).
3. **No branding leak** — presents as **stock Chrome**: no `Raven`/`Chromium`/`Headless` in
   `navigator.userAgent`, `userAgentData`, `appName/appVersion/vendor`, WebGL renderer, or any
   JS-visible field.
4. **WebRTC absence** — with an active profile, `new RTCPeerConnection()` throws `NotSupportedError`.
   **Your app MUST NOT depend on WebRTC** (anti-IP-leak).
5. **OS/GPU-class match** — a persona is valid **only** on the matching-OS binary; pair each
   descriptor to the correct per-OS artifact (no cross-OS personas in v1).
6. **Geolocation** — `navigator.geolocation` returns the descriptor's coordinates, permission-gated.
7. **Codecs** — advertises H.264/AAC iff decodable (§7).

---

## 10. Lifecycle & operations

- **One `--user-data-dir` per persona.** Never share a data dir between two live personas; profile
  state (storage, cookies, GPU cache) must not cross.
- **Process ownership.** *You* own the browser process lifecycle. If you attached via CDP,
  `browser.close()` from a client only detaches — terminate the process you launched, then (and only
  then) delete the descriptor file (§6).
- **Concurrency.** Each persona = one process + one data dir + one descriptor file + (optionally) one
  debugging endpoint on a distinct loopback port.
- **Teardown order:** stop CDP clients → terminate the browser process → wait for exit → delete the
  descriptor + any per-launch temp files.

---

## 11. Failure modes & error handling

| Situation | Behavior | Your handling |
|---|---|---|
| Descriptor fails schema/coherence | Profile stays **INACTIVE**; host values are used unchanged; **the browser never crashes**. | Validate with `validate.py` **before** launch; treat "persona did not apply" as a config error. |
| `schemaVersion` unknown major | **Hard fail** of the profile (INACTIVE). | Pin the contract major; regenerate descriptors on a major bump. |
| Cross-OS persona (e.g. macOS GPU + `os: windows`) | Fails coherence → INACTIVE; even if forced via test switches, pixels won't render coherently. | Never cross OS; pick the persona for the binary's OS. |
| Descriptor file deleted while running | Renderers spawned later cannot re-read it. | Honor the §6 lifetime rule — delete only after process exit. |
| Linux, codecs expected but off | H.264/AAC report unsupported (coherent, not a bug). | Install a licensed lib via `--fingerprint-ffmpeg` (§7). |
| `--enable-automation` / `--headless=old` passed | `navigator.webdriver=true` / `HeadlessChrome` leak | Remove them; use `--headless=new` if headless is required. |

---

## 12. Versioning & compatibility policy

- Every descriptor carries `schemaVersion` (**1** for this contract).
- **Additive optional fields** ⇒ minor revision (same major, back-compatible; new fields go under
  `extensions`). **Field rename/removal or semantic change** ⇒ major bump + a new
  `launch-contract-v<N>.md` + migration notes.
- Your app **pins the contract major** it targets and the exact binary `<version>` (`build/PINS`
  `chromium_tag`). Do not mix majors.

---

## 13. Reference: minimal end-to-end launcher (Python)

Illustrative; adapt to your process manager. Assumes a validated `descriptor.json`.

```python
import json, os, shutil, socket, subprocess, sys, tempfile, time, urllib.request

BINARY = "/opt/raven-chromium/chrome"          # or .../raven-launch.sh on Linux+codecs
DESCRIPTOR = "/personas/acct-42/descriptor.json"

def free_loopback_port():
    s = socket.socket(); s.bind(("127.0.0.1", 0)); p = s.getsockname()[1]; s.close(); return p

def launch(descriptor, extra=()):
    udd = tempfile.mkdtemp(prefix="raven-udd-")
    port = free_loopback_port()
    argv = [BINARY,
            f"--fingerprint-profile={descriptor}",
            f"--user-data-dir={udd}",
            f"--remote-debugging-port={port}",
            "--no-first-run", "--no-default-browser-check", *extra]
    proc = subprocess.Popen(argv)
    ws = wait_for_cdp(port)                     # discover webSocketDebuggerUrl
    return proc, udd, port, ws

def wait_for_cdp(port, timeout=30):
    url = f"http://127.0.0.1:{port}/json/version"
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            return json.load(urllib.request.urlopen(url))["webSocketDebuggerUrl"]
        except Exception:
            time.sleep(0.2)
    raise RuntimeError("CDP endpoint did not come up")

def teardown(proc, udd):
    proc.terminate()
    try: proc.wait(timeout=15)
    except subprocess.TimeoutExpired: proc.kill(); proc.wait()
    shutil.rmtree(udd, ignore_errors=True)     # descriptor deleted by the owner AFTER exit

if __name__ == "__main__":
    proc, udd, port, ws = launch(DESCRIPTOR)
    print("CDP:", ws)                          # hand ws/port to your automation client
    try:
        # ... connect a CDP client (Playwright connectOverCDP, puppeteer, raw WS) and drive ...
        pass
    finally:
        teardown(proc, udd)
```

---

## 14. Pre-flight checklist

- [ ] Binary artifact **signature + SHA256** verified (§2.2).
- [ ] Binary `<version>` matches the version your app pins (`build/PINS`).
- [ ] Descriptor passes `python3 profile-db/validate.py <file>` (§3.4).
- [ ] Persona `os` matches the **binary's OS**; GPU class matches the **host** (§8).
- [ ] `--user-data-dir` is unique per persona; descriptor path is stable for the process lifetime (§6).
- [ ] No `--enable-automation`; headless (if any) is `--headless=new` (§4.2).
- [ ] Not depending on WebRTC (guarantee #4).
- [ ] Linux + codecs: licensed `libffmpeg.so` installed via `--fingerprint-ffmpeg` (§7).
- [ ] Teardown terminates the process, then deletes the descriptor + temp dirs (§10).

---

## Appendix A — Per-OS example descriptors

Pull ready-made, source-verified personas from [`profile-db/personas/`](../../profile-db/personas/):

| OS | Personas |
|---|---|
| Windows | `win-nvidia-rtx3060-desktop`, `win-nvidia-rtx4060-laptop`, `win-intel-uhd630-desktop`, `win-intel-irisxe-laptop`, `win-amd-rx6600-desktop` |
| macOS | `macos-apple-m1-air`, `macos-apple-m3pro-14` |
| Linux | `linux-nvidia-rtx3060-desktop` |

## Appendix B — Switch quick reference

| Switch | Who | Stability |
|---|---|---|
| `--fingerprint-profile=<path>` | you | STABLE |
| `--user-data-dir=<path>` | you | STABLE (Chromium) |
| `--fingerprint-ffmpeg=<path>` (via `raven-launch.sh`) | you, Linux | STABLE (launcher) |
| `--remote-debugging-port` / `--remote-debugging-pipe` | you | STABLE (Chromium) |
| `--headless=new`, `--no-first-run`, `--no-default-browser-check` | you (optional) | STABLE (Chromium) |
| `--fingerprint-profile-data=<b64>` | **internal — never pass** | volatile |
| `--fingerprint`, `--fingerprint-platform`, `--timezone`, `--fingerprint-screen-*`, … | testing only | UNSTABLE |
| `--enable-automation`, `--headless=old` | **avoid** — leaks the tool | — |

---

*Normative contract: [`docs/contract/launch-contract-v1.md`](../contract/launch-contract-v1.md).
Where this guide and the contract disagree, the contract wins.*
