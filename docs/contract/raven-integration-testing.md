# Raven Chromium — Integration & Conformance Testing Guide

**Status:** v1 (2026-07-15) · Audience: the **MaskRaven** control-plane (`maskraven/maskraven`, Go + Wails v3 + Svelte 5) running E2E / stealth / conformance tests against the real fork. Its env vars carry the consumer's own `MASKRAVEN_*` namespace (not part of the launch/descriptor contract); the fork's own launcher var stays `RAVEN_CHROME`. · Companion to the normative [`launch-contract-v1.md`](./launch-contract-v1.md) and [`third-party-integration-guide.md`](../guides/third-party-integration-guide.md).

Everything below is **measured against the live fork build** (Chromium `150.0.7871.114`, `out/Default/chrome` on the `raven` host), not assumed. Where a value is host-dependent it says so.

---

## 0. TL;DR / decision table

| You asked | Answer |
|---|---|
| Prebuilt binary for darwin/arm64? | **No.** No macOS build exists; a local macOS build is **not** feasible — don't chase it (§1). |
| Prebuilt Linux x86_64? | **Yes, one dev build** at `raven:~/chromium/src/out/Default/chrome` (unsigned, 2.1 GB). No signed release artifacts yet. |
| Is there a "Linux fork remote"? | **Yes — it's the `raven` host** (`192.168.100.200`, SSH). It is *not* a listening CDP endpoint; **you launch the fork yourself** (§2). |
| How do I run `go test` against it? | **Run where the fork is (Linux/`raven`)**: literal `go test` after a one-time Go install + repo rsync (Path A), or a cross-compiled test binary (Path B). No remote-attach code needed (§2). |
| Launch flags | `--fingerprint-profile=<path>` + `--user-data-dir=<path>`; codecs via `raven-launch.sh --fingerprint-ffmpeg=<path>`. Headless **required** on `raven` (no display) (§3). |
| Sample persona | `profile-db/personas/linux-nvidia-rtx3060-desktop.json` (§4). |
| Ed25519 `manifest.json` (decision #1)? | **Not implemented yet.** Ships `SHA256SUMS` + GPG `.asc` + `RAVEN-RELEASE.txt` instead (§6). |
| Pins | `chromium_tag=150.0.7871.114`, `schemaVersion 1`, contract `v1` — **aligned, no drift** (§7). |
| Can stock go-rod/Puppeteer drive the fork? | **Yes.** R12 (stock CDP page-open) is **fixed fork-side**; no driver workaround needed. Root cause was a browser crash on a UI-thread descriptor read, not auto-attach suppression (§8). |

---

## 1. Getting a runnable fork binary

**There is no prebuilt, signed release yet, and no macOS build at all.**

- **darwin/arm64 (your host):** nothing to run. A local macOS build of the fork is **infeasible for you to chase**: it needs a full `depot_tools` + ungoogled-chromium-150 checkout (~100 GB), the pinned Xcode/SDK (`build/PINS`: Xcode 26.5 / SDK 26.5), and a multi-hour build we have **not** validated on macOS. **Do not attempt a local macOS build for testing** — use the Linux fork remote (§2).
- **Linux x86_64:** one **dev build** exists in place at `raven:~/chromium/src/out/Default/chrome` — `Chromium 150.0.7871.114`, unsigned, ~2.1 GB. It is a non-relocatable dev build (needs its sibling `out/Default/*.pak`, `icudtl.dat`, `v8_context_snapshot.bin`, ANGLE libs, `libffmpeg.so`), so **don't copy just `chrome`** — either run it in place (§2) or produce a relocatable tarball:

  ```bash
  # On raven — produces raven-chromium-150.0.7871.114-linux-x64.tar.xz (relocatable, runs on any Linux x64)
  ssh raven 'cd ~/chromium/src && bash ~/raven/build/package-linux.sh \
      --src ~/chromium/src --out ~/dist --version 150.0.7871.114'
  ```

- **If you want to build your own Linux binary** (e.g. a CI box you control): on a Linux x64 host with `depot_tools`, run `build/sync.sh` → `build/apply-patches.sh` → `PLATFORM=linux-x64 build/gen-and-build.sh`. Cold build ≈ 80 min on the reference host. Output: `out/Default/chrome`. But for test purposes the existing `raven` build is the path of least resistance.

> Ask me to run `package-linux.sh` if you want a portable Linux tarball for your CI.

---

## 2. The "Linux fork remote" (fidelity oracle)

**It's a real host, reachable over SSH — not a conceptual placeholder, and not a listening CDP endpoint.**

- **Host:** `raven` → `HostName 192.168.100.200`, `port 22`, `User user`, `IdentityFile ~/.ssh/raven_ed25519` (already in your `~/.ssh/config`, same Mac). Private-LAN IP, so no tunnel needed to reach SSH.
- **What runs there:** the fork at `~/chromium/src/out/Default/chrome` (Linux x86_64). The repo mirror (personas, `build/PINS`, `raven-launch.sh`) is at `~/raven`.
- **There is NO pre-launched `ws://` CDP endpoint.** Nothing is listening; you must launch the fork and open a debug port yourself.

Your `ResolveBinary()` reads `MASKRAVEN_FORK_BIN` as a **local** path and go-rod launches it locally — so the tests must run **where the fork binary is** (Linux/`raven`), pointing `MASKRAVEN_FORK_BIN` at the in-place build. Two concrete ways; both give the exact same assertions (§5).

**Shared env** (used by both paths):

```bash
MASKRAVEN_FORK_BIN=$HOME/chromium/src/out/Default/chrome   # the real fork (ResolveBinary first key)
MASKRAVEN_FORK_ROOT=$HOME/raven                             # pin check reads ~/raven/build/PINS (150.0.7871.114)
MASKRAVEN_E2E=1                                             # unlock conformance suite
MASKRAVEN_HEADLESS=1                                        # REQUIRED on raven (no X display); omit only under xvfb-run
# add per run: MASKRAVEN_E2E_PANELS=1 (detector panels), MASKRAVEN_R1_LIVE=1 (your webdriver/probe loop)
```

#### Path A — literal `go test` on `raven` (matches your command exactly)

`raven` has **no Go toolchain yet**, so install one (user-local, no sudo) and rsync your repo:

```bash
# 1. one-time: install Go on raven (match your go.mod's `go` directive; example uses 1.23.5)
ssh raven 'mkdir -p ~/goroot && curl -sL https://go.dev/dl/go1.23.5.linux-amd64.tar.gz | tar -xz -C ~/goroot --strip-components=1 && ~/goroot/bin/go version'

# 2. each run: sync your repo up (module deps download on raven — it has outbound net)
rsync -a --delete --exclude .git ~/Projects/MaskRaven/ raven:~/maskraven/

# 3. run the literal command against the REAL fork:
ssh raven 'export PATH=$PATH:~/goroot/bin; cd ~/maskraven && \
  MASKRAVEN_FORK_BIN=$HOME/chromium/src/out/Default/chrome MASKRAVEN_FORK_ROOT=$HOME/raven \
  MASKRAVEN_E2E=1 MASKRAVEN_HEADLESS=1 \
  go test ./internal/browser/ -run TestConformance -v'
```

Headful instead of headless (real compositor; `xvfb-run` **is installed** on `raven`): drop `MASKRAVEN_HEADLESS=1` and wrap: `xvfb-run -a go test ./internal/browser/ -run TestConformance -v`.

#### Path B — no Go on `raven` (cross-compile the test binary on your Mac)

Fastest if you don't want to install Go / rsync. go-rod is pure-Go so cross-compilation is clean:

```bash
GOOS=linux GOARCH=amd64 CGO_ENABLED=0 go test -c ./internal/browser -o /tmp/conf.test && scp /tmp/conf.test raven:/tmp/
ssh raven 'MASKRAVEN_FORK_BIN=$HOME/chromium/src/out/Default/chrome MASKRAVEN_FORK_ROOT=$HOME/raven \
  MASKRAVEN_E2E=1 MASKRAVEN_HEADLESS=1 /tmp/conf.test -test.run TestConformance -test.v'
```

Caveat: a compiled test binary runs with `cwd` = wherever you invoke it, so any `testdata/` your tests resolve by relative path won't be found — if a test reads package-local `testdata`, use Path A. External paths via `MASKRAVEN_FORK_ROOT` (personas, PINS) work fine either way.

#### Your R1 live loop

```bash
ssh raven 'export PATH=$PATH:~/goroot/bin; cd ~/maskraven && \
  MASKRAVEN_FORK_BIN=$HOME/chromium/src/out/Default/chrome MASKRAVEN_FORK_ROOT=$HOME/raven \
  MASKRAVEN_R1_LIVE=1 MASKRAVEN_HEADLESS=1 \
  go test ./internal/browser/ -run TestR1 -v'   # adjust -run to your R1 test name
```

**R1 assertion against the fork:** `navigator.webdriver === false` (type `boolean`). Unlike system Chrome, the fork returns `false` **natively** (patch 009, unconditional) — you do **not** need `--disable-blink-features=AutomationControlled` here, though keeping it is harmless. If your loop ever sees `true` or `undefined` against the fork, that's a real regression.

### Alternative: remote-attach over an SSH tunnel (needs new code on your side)

If you'd rather keep driving from the Mac, launch the fork on `raven` with a **loopback** debug port and tunnel it. Chrome binds `--remote-debugging-port` to `127.0.0.1` only, so a tunnel is mandatory:

```bash
# Terminal A — launch the fork on raven with a loopback CDP port:
ssh raven 'cd ~/chromium/src && out/Default/chrome --headless=new --no-sandbox --disable-gpu \
  --remote-debugging-port=9222 \
  --fingerprint-profile=$HOME/raven/profile-db/personas/linux-nvidia-rtx3060-desktop.json \
  --user-data-dir=/tmp/udd-remote'
# Terminal B — forward it to the Mac:
ssh -N -L 9222:127.0.0.1:9222 raven
# Now http://127.0.0.1:9222/json/version → webSocketDebuggerUrl is reachable locally.
```

This requires you to add a **remote-attach path** (a `MASKRAVEN_FORK_REMOTE=ws://127.0.0.1:9222`-style control URL that connects via `rod.New().ControlURL(...)` instead of launching). Your manager today only does local-launch + loopback-debug, so **this is net-new code** — only build it if you specifically want to drive from macOS. For CI, the "run on `raven`" path above is simpler and has higher fidelity (no tunnel, real headful possible via xvfb). There is **no auth/token** on the debug port; the SSH boundary is the only auth, so never bind it to a public interface.

---

## 3. Launch contract specifics (confirmed against the build)

- **Apply a descriptor:** exactly `--fingerprint-profile=<abs path to descriptor.json>`. The browser reads + validates it once and propagates internally. Confirmed live: platform/screen/timezone/languages/hardwareConcurrency/deviceMemory/WebGL-renderer all follow the descriptor (§5).
- **Per-persona isolation:** `--user-data-dir=<abs path>`, one dir per persona. Fresh dir per launch is fine — identity is descriptor-driven, not stored (§5 persistence).
- **Do NOT pass** per-field `--fingerprint*` switches (you already don't) or `--fingerprint-profile-data` (internal). You're clean.
- **Headless vs headful:** `--headless=new` is clean (no `HeadlessChrome` leak — verified §5). Legacy `--headless=old` leaks; never use it. On `raven` (no display) headless is required; for headful use `xvfb-run -a`.
- **go-rod note:** the fork sets `navigator.webdriver=false` **natively** (patch `009`, unconditional) — so unlike system Chrome you do **not** need `--disable-blink-features=AutomationControlled` to get `false` here. Keeping that flag is harmless; just know the fork guarantees `false` on its own.
- **Codecs (H.264/AAC) enable path (Linux):** the default build reports H.264/AAC unsupported (coherent — no patented decoder). To test the enabled path, launch via the wrapper with a licensed Chrome-branded lib:

  ```bash
  ssh raven 'RAVEN_CHROME=~/chromium/src/out/Default/chrome bash ~/raven/build/raven-launch.sh \
    --fingerprint-ffmpeg=$HOME/chrome-libffmpeg-150.7871.114.so \
    --fingerprint-profile=$HOME/raven/profile-db/personas/linux-nvidia-rtx3060-desktop.json \
    --user-data-dir=/tmp/udd-codec --headless=new --no-sandbox --disable-gpu ...'
  ```
  A reference Chrome-branded `libffmpeg.so` (matching this build's ABI) is already staged at `raven:~/chrome-libffmpeg-150.7871.114.so`. Its patent license rests with the lib's source, not the fork.

---

## 4. Known-good descriptor + persona

**Safest for the Linux fork binary: `profile-db/personas/linux-nvidia-rtx3060-desktop.json`** — `os` matches the binary's OS, `schemaVersion 1`, passes `validate.py`. Full content (drop-in):

```json
{
  "schemaVersion": 1,
  "seed": 9012345678901234567,
  "os": "linux",
  "platform": "Linux x86_64",
  "chromeMajor": 150,
  "hardwareConcurrency": 12,
  "deviceMemory": 8,
  "gpu": {
    "vendor": "Google Inc. (NVIDIA Corporation)",
    "renderer": "ANGLE (NVIDIA Corporation, NVIDIA GeForce RTX 3060/PCIe/SSE2, OpenGL 4.6.0 NVIDIA 535.183.01)",
    "architecture": "ampere",
    "device": "NVIDIA GeForce RTX 3060/PCIe/SSE2"
  },
  "screen": { "w": 2560, "h": 1440, "dpr": 1, "colorDepth": 24, "pixelDepth": 24, "availW": 2560, "availH": 1413 },
  "languages": ["en-US", "en"],
  "locale": "en-US",
  "timezone": "America/Denver"
}
```

- Validate before use: `python3 profile-db/validate.py profile-db/personas/linux-nvidia-rtx3060-desktop.json` → `PASS`.
- Alternative (the descriptor `validate-persona.sh` uses as its gate): `profile-db/fixtures/linux-intel-en-us.json`.
- **Host caveat:** `raven` has no GPU (SwiftShader), so WebGL **rendered pixels** won't match a real RTX 3060 — but the WebGL **renderer string + all `getParameter` metadata** do follow the descriptor, and every conformance guarantee below (branding / WebRTC / persistence / coherence / codecs) is GPU-independent. Run on a real-NVIDIA Linux box only if you also need pixel-level WebGL fidelity.

---

## 5. Expected guarantee VALUES (live-captured, so your probes assert correctly)

Captured from `out/Default/chrome --headless=new` with the persona above, **run twice with fresh data-dirs → byte-identical** (see persistence). Assert against these:

| Probe | Expected value | Notes |
|---|---|---|
| `navigator.webdriver` | `false` (type `boolean`) | **Not** `true`, **not** `undefined`. Native (patch 009), regardless of launch flags. |
| `navigator.userAgent` | `Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/150.0.0.0 Safari/537.36` | Minor version reduced to `.0.0` (stock Chrome behavior). |
| `navigator.appVersion` | `5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/150.0.0.0 Safari/537.36` | |
| `navigator.appName` | `Netscape` | |
| `navigator.vendor` | `Google Inc.` | |
| `navigator.platform` | `Linux x86_64` | Follows descriptor. |
| `window.chrome` | `object`, keys = `loadTimes, csi, app` | Present (absence is itself a bot tell). |
| `RTCPeerConnection` | `typeof === "function"` **but** `new RTCPeerConnection()` **throws `NotSupportedError`** | **Defined-but-throws**, *not* `undefined`. Assert on the throw + `e.name`. |
| `navigator.userAgentData.brands` | `[{brand:"Not;A=Brand",version:"8"}, {brand:"Chromium",version:"150"}]`; `.mobile=false`; `.platform="Linux"` | See branding note below. |
| `navigator.languages` | `["en-US","en"]` | Follows descriptor. |
| `hardwareConcurrency` / `deviceMemory` | `12` / `8` | Follows descriptor. |
| `screen` `[w,h,availW,availH,dpr,colorDepth]` | `[2560,1440,2560,1413,1,24]` | Follows descriptor. |
| `Intl…timeZone` | `America/Denver` | Follows descriptor. |
| WebGL `UNMASKED_RENDERER_WEBGL` | `ANGLE (NVIDIA Corporation, NVIDIA GeForce RTX 3060/PCIe/SSE2, OpenGL 4.6.0 NVIDIA 535.183.01)` | Metadata follows descriptor even on SwiftShader host. |
| `canPlayType` | H.264 `""`, AAC `""`, VP9 `probably`, Opus `probably`, MP3 `probably`, AV1 `probably` | Linux **default**. With `raven-launch.sh --fingerprint-ffmpeg` → H.264/AAC flip to `probably` (§3). |

**Branding — forbidden vs allowed:**
- **Forbidden anywhere in `userAgent`/`appVersion`/`vendor`/`uaData`:** `Raven`, `Headless`, `HeadlessChrome`. **Absent** ✓.
- **`Chromium`:** must **not** appear in `navigator.userAgent` (it doesn't — UA says `Chrome`), but **does** appear in `Sec-CH-UA` / `uaData.brands` — which is **normal for real Chrome** and not a leak.
- **`Chrome`:** present (allowed) ✓.

> ⚠️ **Branding coherence item worth asserting (and a candidate fork-side hardening task):** the UA string says `Chrome`, but `uaData.brands` currently lists only `Not;A=Brand` + `Chromium` — it does **not** include a `Google Chrome` brand, which real Google Chrome emits. A strict UA↔UA-CH coherence check would flag this. Your `TestConformanceBrandingNoLeak` should assert the *actual* brands above; if you want the `Google Chrome` brand added for full coherence, flag it and I'll patch the fork side (it's a `patch 213` extension). Also verify the **HTTP `Sec-CH-UA` header** (not just the JS mirror) in your panel tests.

**Persistence (byte-identical across restarts):** confirmed live. Two launches with the same descriptor and *different* fresh `--user-data-dir`s produced identical output including a stable canvas hash (`canvasHash=7ecafb5` both runs). So identity is descriptor-driven, not profile-stored — your `TestConformancePersistenceAcrossRestarts` should see a byte-identical snapshot as long as the descriptor (esp. `seed`) is unchanged.

### Assertion cheat-sheet (per your conformance test, with the persona in §4)

- **`TestConformanceBrandingNoLeak`**
  - `userAgent == "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/150.0.0.0 Safari/537.36"`
  - `userAgent`/`appVersion`/`vendor`/`uaData` contain **none** of `"Raven"`, `"Headless"`, `"HeadlessChrome"`; `userAgent` does **not** contain `"Chromium"`.
  - `appName == "Netscape"`, `vendor == "Google Inc."`, `typeof window.chrome == "object"`.
  - Current `uaData.brands == [{"Not;A=Brand","8"},{"Chromium","150"}]` (assert this literal until the fork adds a `Google Chrome` brand — see coherence note above).
- **`TestConformanceWebRTCAbsence`** — `typeof RTCPeerConnection == "function"` **and** `new RTCPeerConnection()` throws with `err.name == "NotSupportedError"`. (Do **not** assert `undefined`.)
- **`TestConformancePersistenceAcrossRestarts`** — two launches, same descriptor, fresh `--user-data-dir` each → snapshots equal (canvas hash stable, e.g. `7ecafb5`). Flip a byte of `seed` ⇒ snapshot changes; changing only the data-dir ⇒ no change.
- **`TestConformanceCoherenceOnAppliedIdentity`** — all equal the descriptor: `platform=="Linux x86_64"`, `languages==["en-US","en"]`, `hardwareConcurrency==12`, `deviceMemory==8`, `screen==[2560,1440,2560,1413,1,24]`, `timezone=="America/Denver"`, WebGL `UNMASKED_RENDERER_WEBGL == gpu.renderer`.
- **`TestConformanceCodecsProbe`** — default fork: `canPlayType` H.264 `""`, AAC `""`, VP9/Opus/MP3/AV1 `"probably"`. Enabled path (`raven-launch.sh --fingerprint-ffmpeg=~/chrome-libffmpeg-150.7871.114.so`): H.264/AAC → `"probably"`.

---

## 6. BrowserProvider production path (decision #1) — **not implemented yet**

The fork does **not** yet ship the Ed25519 `manifest.json` + `manifest.json.sig` scheme your verify chain expects (schemaVersion/version/channel/sequence/minContractVersion/artifacts + raw Ed25519 over exact bytes). There is **no signing public key** published.

What the fork's packaging **actually** emits today (per `build/package-linux.sh` + contract §4):
- `raven-chromium-<version>-linux-x64.tar.xz` + `…​.sha256` (`SHA256SUMS`-style),
- an optional **detached GPG** signature `…​.tar.xz.asc` (Linux; codesign/notarization on macOS, Authenticode on Windows),
- a plaintext `RAVEN-RELEASE.txt` (version + base + contract pointer) — **not** a signed JSON manifest.

**So you cannot yet test your `sig → SHA-256 → OS code-signature → sequence-downgrade` chain against a real fork artifact.** This is a genuine **fork-side gap**, not something you're missing. To close it, the fork needs a task to: generate an Ed25519 keypair, extend `package-*.sh` to emit `manifest.json` (with your exact fields) + `manifest.json.sig`, and publish the public key. Tracking home: Plan 05 packaging/contract (T5.4/T5.5). **Say the word and I'll implement the manifest + signing on the fork side and hand you the public key + a sample signed manifest to test against** — that's the clean way to unblock decision #1.

---

## 7. Version alignment (no drift)

| Pin | Your target | Fork build (measured) | Status |
|---|---|---|---|
| `chromium_tag` | `150.0.7871.114` | `chrome --version` → `Chromium 150.0.7871.114`; `build/PINS` → `150.0.7871.114` | ✅ match |
| Descriptor `schemaVersion` | `1` | `profile-db/schema/descriptor.schema.json` → `"const": 1`; personas carry `schemaVersion: 1` | ✅ match |
| Contract major | `v1` | `docs/contract/launch-contract-v1.md` | ✅ match |

- The `--version` CLI prints `Chromium …` (the product string) — **do not assert on that**; it's not JS-visible. The JS-visible UA correctly presents as `Chrome` (§5).
- No drift as of 2026-07-15. If the fork rebases past 150, this table + `build/PINS` are the single source of truth; pin against `build/PINS` `chromium_tag` in CI.

---

## 8. CDP driving — R12 resolved fork-side (stock go-rod / Puppeteer / chromedp work)

**R12 is fixed in the fork.** Stock CDP clients now open and drive pages under `--fingerprint-profile`
with **no driver-side workaround**.

**The root cause was mis-described as "auto-attach event suppression" — it was actually a browser crash.**
Patch `core/102` read the descriptor with `base::ReadFileToString` **on the UI thread** inside
`RenderProcessHostImpl::PropagateBrowserCommandLineToRenderer`. After startup the UI thread disallows
blocking, so the **first fingerprint-renderer spawned after startup** hit a fatal `DCHECK`
(`thread_restrictions.cc: Function marked as blocking was called from a scope that disallows blocking`)
and **aborted the browser** — the CDP websocket EOFed with no `createTarget` response. It reproduced only
when **no renderer was pre-warmed at startup**: stock **go-rod**/**chromedp** launch with **zero** initial
pages and issue a bare `Target.createTarget`, so that createTarget *is* the first renderer spawn.
Puppeteer, raw clients that `setAutoAttach` (which auto-attaches the initial page), and any launch with an
initial `about:blank` tab all pre-warmed a renderer during startup (blocking still allowed) and so **masked
it** — which is why P0–P4 dev on CfT and early raw-CDP spikes never saw it, and why the auto-attach *event*
was in fact never suppressed (it fires normally; see contract §7).

**Fix:** the descriptor is now read + base64-encoded **once at startup** (`ungoogled::
InitFingerprintProfileData`, from `PreCreateThreadsImpl` where blocking is allowed) and cached; the
renderer-spawn hot path only copies the cached value — no UI-thread I/O. Mirrors patch 219's
accept-language startup read.

**Measured after the fix (raven host, `--fingerprint-profile` active):**

| Client | Before | After |
|---|---|---|
| stock go-rod `Browser.Page()` (cold launch) | `EOF` (browser crash) | **opens page** (UA `Chrome/150` Linux, `webdriver=false`) |
| stock Puppeteer `newPage()` | ok (masked) | ok |
| raw `setDiscoverTargets`+`createTarget` from cold | connection EOF | **`createTarget` returns, browser alive** |
| plain mode (no `--fingerprint-profile`) | ok | ok (no regression) |

**Action for the Raven control plane:**
- Flip `docs/residual-risk.md` **R12 → resolved (fork-side fix)**. The planned client-side explicit-
  `Target.attachToTarget` workaround is **no longer required** (harmless if kept; `NoDefaultDevice()` and
  the R1 launcher hardening remain correct and unrelated).
- Re-run the conformance suite (**Path B**, §2). `TestConformance*` `openPage` should stop EOFing and reach
  the real §5 assertions.
- The §5 stealth values are unchanged by this fix (it touches only browser-side startup I/O, nothing
  page-visible): `navigator.webdriver === false`, UA `Chrome/150`, `RTCPeerConnection` throws
  `NotSupportedError`, branding clean.

**Fork-side regression guard:** `test/cdp/r12_auto_attach_regression.py` — launches a *cold* browser (zero
pre-warmed pages) under `--fingerprint-profile` and fails if `createTarget` EOFs/crashes or if
`setAutoAttach` fails to deliver `attachedToTarget`.

## Appendix — one-shot smoke test

Literal `go test` on the real fork (Path A; assumes the one-time Go install + rsync from §2):

```bash
rsync -a --delete --exclude .git ~/Projects/MaskRaven/ raven:~/maskraven/
ssh raven 'export PATH=$PATH:~/goroot/bin; cd ~/maskraven && \
  MASKRAVEN_FORK_BIN=$HOME/chromium/src/out/Default/chrome MASKRAVEN_FORK_ROOT=$HOME/raven \
  MASKRAVEN_E2E=1 MASKRAVEN_HEADLESS=1 \
  go test ./internal/browser/ -run TestConformance -v'
```

No-install alternative (Path B, cross-compiled binary):

```bash
GOOS=linux GOARCH=amd64 CGO_ENABLED=0 go test -c ./internal/browser -o /tmp/c.test && scp /tmp/c.test raven:/tmp/
ssh raven 'MASKRAVEN_FORK_BIN=$HOME/chromium/src/out/Default/chrome MASKRAVEN_FORK_ROOT=$HOME/raven \
  MASKRAVEN_E2E=1 MASKRAVEN_HEADLESS=1 /tmp/c.test -test.run TestConformance -test.v'
```

*Where this guide and [`launch-contract-v1.md`](./launch-contract-v1.md) disagree, the contract wins.*
