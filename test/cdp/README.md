# CDP conformance / regression tests

Self-contained (stdlib-only) tests that drive a **built** fork binary over the
Chrome DevTools Protocol. They exist because the browser↔driver CDP surface is
not exercised by the JS-probe conformance suite (that suite asserts *page-visible*
identity; these assert the *driver-visible* control channel behaves like stock
Chrome).

## `r12_auto_attach_regression.py`

Guards **R12** and the CDP auto-attach contract. R12 was a fork bug: under
`--fingerprint-profile`, patch `core/102` read the descriptor with
`base::ReadFileToString` **on the UI thread** inside
`RenderProcessHostImpl::PropagateBrowserCommandLineToRenderer`. After startup the
UI thread disallows blocking, so the **first fingerprint-renderer spawned after
startup** hit a fatal `DCHECK` and aborted the browser — the CDP websocket EOFed
with no response. It only reproduced when *no* renderer was pre-warmed at startup
(stock **go-rod** / **chromedp** launch with zero initial pages, then issue a bare
`Target.createTarget`); Puppeteer and anything that touched the initial page first
masked it. Fixed by reading+caching the descriptor once at startup
(`ungoogled::InitFingerprintProfileData`), so the hot path does no I/O.

The test launches a **cold** browser (no positional URL ⇒ zero pre-warmed page
renderers, exactly go-rod's condition) under `--fingerprint-profile` and checks:

- **T1** — a bare `Target.createTarget` from cold returns a `targetId`, the
  websocket stays open, and the browser process stays alive. *(Fails hard —
  `EOF`/crash — if the UI-thread blocking read ever returns.)*
- **T2** — `Target.setAutoAttach{waitForDebuggerOnStart:true, flatten:true}` +
  `createTarget` delivers `Target.attachedToTarget` with a `sessionId` (the
  browser↔driver auto-attach contract stock clients rely on).
- **T3** — on that session the identity is the fork's spoof, not a leak:
  `navigator.userAgent` ≈ `…X11; Linux x86_64… Chrome/150…`, no `Headless`;
  `navigator.webdriver === false`.

Exit code is `0` iff all checks pass.

### Run

```bash
# on the raven host (or any host with a built fork binary + a Linux persona)
python3 test/cdp/r12_auto_attach_regression.py \
    --chrome ~/chromium/src/out/Default/chrome \
    --persona profile-db/personas/linux-nvidia-rtx3060-desktop.json
```

`--chrome`/`--persona` also read from `CHROME_BIN` / `PERSONA`. Headless is
required on a display-less host (default `--headless=new`).
