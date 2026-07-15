# R12 root cause — "fork suppresses CDP auto-attach under `--fingerprint-profile`"

**Status:** resolved fork-side (2026-07-15). Fix folded into patch `core/102`
(profile plumbing). Regression-guarded by
[`test/cdp/r12_auto_attach_regression.py`](../../test/cdp/r12_auto_attach_regression.py).

## Reported symptom

Launched with `--fingerprint-profile=<desc>`, a CDP client that does
`Target.setAutoAttach{autoAttach:true, flatten:true}` at the browser target then
`Target.createTarget{url}` "never receives the `Target.attachedToTarget` event";
stock go-rod `Browser.Page()` fails with `EOF`. Without the flag, auto-attach
fires normally. It was filed as *the fork suppresses the auto-attach event*.

## That description was wrong — the event is not suppressed

Measured against the live fork (`out/Default/chrome`, Chromium 150.0.7871.114):

- Raw CDP `setAutoAttach{flatten:true}` + `createTarget` under `--fingerprint-profile`
  **does** deliver `attachedToTarget` (with `waitForDebuggerOnStart:true` too).
- A **real Puppeteer** (`puppeteer-core`) `connect()` + `newPage()` under
  `--fingerprint-profile` **succeeds** (UA `Chrome/150` Linux, `webdriver=false`).
- Explicit `Target.attachToTarget{flatten:true}` works.

Static analysis of the DevTools backend confirms why: **no fork patch touches
`content/browser/devtools/`** (`grep -r fingerprint` there is empty), and the
browser process never holds an active `fingerprint::Profile` (all `Profile::
active()` gating is renderer-side blink). The `Target.createTarget` →
`GetOrCreateFor(contents)` → `RenderFrameDevToolsAgentHost` ctor (registers the
frame-tree-node **before** `NotifyCreated`) → `BrowserAutoAttacher` →
`TargetHandler::AutoAttach` → `frontend_->AttachedToTarget` path is **fully
synchronous with `createTarget` and byte-identical in both modes**. It cannot be
skipped by fingerprint state.

## Actual root cause — a browser crash on a UI-thread blocking read

Stock **go-rod** (and chromedp) *do* fail, but for a different reason. go-rod's
launcher starts the browser with **zero initial page targets** and its
`Browser.Page()` issues:

```
Target.setDiscoverTargets{discover:true}   -> ok
Target.createTarget{url:"about:blank"}     -> (no response; websocket EOF)
```

With `--enable-logging=stderr --v=1`, that `createTarget` produces a **fatal
browser abort**:

```
[FATAL:base/threading/thread_restrictions.cc:62] DCHECK failed: !tls_blocking_disallowed.
  Function marked as blocking was called from a scope that disallows blocking!
  #7  base::OpenFile()
  #8  base::ReadFileToStringWithMaxSize()
  #9  RenderProcessHostImpl::PropagateBrowserCommandLineToRenderer()::$_0  render_process_host_impl.cc:4021
  #11 RenderProcessHostImpl::AppendRendererCommandLine()
  #12 RenderProcessHostImpl::Init()
  <- Target.createTarget <- ChromeDevToolsSession::HandleCommand <- OnWebSocketMessage
```

Patch `core/102` forwarded the descriptor to renderers by reading the file with
`base::ReadFileToString` inside a lazy `static NoDestructor` in
`PropagateBrowserCommandLineToRenderer` — i.e. **on the UI thread, at renderer
`Init`**. The blocking-disallowed TLS flag is set for the browser's whole
post-startup lifetime by `BrowserMainLoop::PreMainMessageLoopRun ->
base::DisallowUnresponsiveTasks()`. So:

- If the **first** fingerprint renderer spawns **during startup** (blocking still
  allowed), the read succeeds and caches — subsequent spawns hit the cache, no
  read, no crash.
- If the **first** fingerprint renderer spawns **after startup** — exactly a cold
  go-rod/chromedp `createTarget` — the read runs in a disallow-blocking scope →
  fatal `DCHECK` → the browser process aborts → the CDP websocket EOFs.

### Why it was masked for everyone except go-rod/chromedp

Anything that pre-warms a renderer during startup reads+caches the descriptor
while blocking is allowed, so the later `createTarget` never re-reads:

- launching with an initial `about:blank` positional URL (our raw harness, the
  integration guide's examples),
- Puppeteer / any client that `setAutoAttach`s first (auto-attaches the initial
  page, spawning its renderer),
- explicit attach to the initial target.

go-rod/chromedp launch **cold** (no initial page) and open the first page via a
bare `createTarget`, so that createTarget is the first-ever renderer spawn — the
only path that triggers the crash. This is why CfT dev (no fingerprint) and early
raw-CDP spikes never surfaced it, and why the Raven spike's explicit-attach
"workaround" appeared to help (its variant attaches/navigates the **initial**
target first, pre-warming a renderer).

## Fix

Read + base64-encode the descriptor **once at startup**, where blocking is
allowed, and cache it; the renderer-spawn hot path only copies the cache. This
mirrors patch 219's accept-language startup read.

- New `components/ungoogled/fingerprint_profile_data.{cc,h}`:
  `InitFingerprintProfileData()` (blocking read + cache, idempotent) and
  `GetFingerprintProfileData()` (no I/O, any thread).
- `chrome/browser/chrome_browser_main.cc`: call `InitFingerprintProfileData()` in
  `PreCreateThreadsImpl()`, right after `InitFingerprintAcceptLanguages()`.
- `content/browser/renderer_host/render_process_host_impl.cc`:
  `PropagateBrowserCommandLineToRenderer` now copies
  `ungoogled::GetFingerprintProfileData()` instead of reading the file.
- `components/ungoogled/BUILD.gn`: add the new sources.

No devtools/target code changed; plain-mode behavior unchanged; nothing
page-visible changed (the fix is browser-side startup I/O only).

## Verification

| Client (under `--fingerprint-profile`) | Before | After |
|---|---|---|
| stock go-rod `Browser.Page()` (cold) | `EOF` (crash) | opens page, UA `Chrome/150`, `webdriver=false` |
| stock Puppeteer `newPage()` | ok | ok |
| raw `setDiscoverTargets`+`createTarget` (cold) | connection EOF | `createTarget` returns, browser alive |
| plain mode (no flag) | ok | ok |
| stealth (`webdriver`, UA, WebRTC throws, branding) | ok | ok (unchanged) |

## Minimal repro

```bash
# cold browser (0 pre-warmed pages) + bare createTarget = the crash trigger
chrome --headless=new --no-sandbox --disable-gpu --remote-debugging-port=9222 \
  --fingerprint-profile=profile-db/personas/linux-nvidia-rtx3060-desktop.json \
  --user-data-dir=/tmp/udd &                # NOTE: no positional URL
# then, on the browser websocket:  Target.setDiscoverTargets{discover:true}
#                                  Target.createTarget{url:"about:blank"}
# pre-fix: fatal DCHECK -> browser aborts -> websocket EOF.
# post-fix: createTarget returns a targetId; browser stays alive.
```

See `test/cdp/r12_auto_attach_regression.py` for the automated guard.
