#!/usr/bin/env python3
# Copyright (c) 2020 The ungoogled-chromium Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.
#
# R12 regression + CDP auto-attach conformance test (stdlib only, no deps).
#
# Context
# -------
# Defect R12: launched with --fingerprint-profile, the fork crashed the browser
# process the first time a fingerprint renderer was spawned *after* startup,
# because patch core/102 read the descriptor with base::ReadFileToString on the
# UI thread (a disallow-blocking scope post-startup) -> fatal DCHECK -> the CDP
# websocket EOFed with no response. It only reproduced when NO renderer was
# pre-warmed at startup (stock go-rod / chromedp launch with zero initial pages
# and issue a bare Target.createTarget); Puppeteer and any client that touches
# the initial page first masked it. The fix reads+caches the descriptor once at
# startup (ungoogled::InitFingerprintProfileData), so the hot path does no I/O.
#
# This test launches a COLD browser (no positional URL => zero pre-warmed page
# renderers, exactly go-rod's condition) under --fingerprint-profile and drives
# it over raw CDP:
#   T1  bare createTarget from cold  -> must return a targetId, ws must stay open,
#       browser process must stay alive   (guards the crash regression)
#   T2  setAutoAttach{waitForDebuggerOnStart:true,flatten:true} + createTarget
#       -> must deliver Target.attachedToTarget with a sessionId
#       (locks in the browser<->driver auto-attach contract)
#   T3  on that session: identity is the fork's spoof, not a leak
#       (navigator.userAgent ~ Chrome/150 on Linux, no "Headless";
#        navigator.webdriver === false)
#
# Exit 0 iff all tests pass. Any crash/EOF fails T1.
#
# Usage:
#   python3 r12_auto_attach_regression.py \
#       --chrome ~/chromium/src/out/Default/chrome \
#       --persona ~/raven/profile-db/personas/linux-nvidia-rtx3060-desktop.json \
#       [--port 0] [--headless new]

import argparse
import base64
import json
import os
import select
import shutil
import socket
import struct
import subprocess
import sys
import tempfile
import time
import urllib.request

# ---------------------------------------------------------------- ws (RFC6455)

def ws_connect(url, timeout=10):
    assert url.startswith("ws://"), url
    hostport, _, path = url[5:].partition("/")
    path = "/" + path
    host, _, port = hostport.partition(":")
    s = socket.create_connection((host, int(port)), timeout=timeout)
    key = base64.b64encode(os.urandom(16)).decode()
    s.sendall(
        (
            f"GET {path} HTTP/1.1\r\nHost: {host}:{port}\r\n"
            f"Upgrade: websocket\r\nConnection: Upgrade\r\n"
            f"Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n"
        ).encode()
    )
    buf = b""
    while b"\r\n\r\n" not in buf:
        chunk = s.recv(4096)
        if not chunk:
            raise EOFError("handshake closed")
        buf += chunk
    return s


def ws_send(s, obj):
    data = json.dumps(obj).encode()
    mask = os.urandom(4)
    n = len(data)
    header = b"\x81"
    if n < 126:
        header += bytes([0x80 | n])
    elif n < 65536:
        header += bytes([0x80 | 126]) + struct.pack(">H", n)
    else:
        header += bytes([0x80 | 127]) + struct.pack(">Q", n)
    s.sendall(header + mask + bytes(b ^ mask[i % 4] for i, b in enumerate(data)))


def _rx(s, n):
    buf = b""
    while len(buf) < n:
        chunk = s.recv(n - len(buf))
        if not chunk:
            raise EOFError("connection closed (EOF)")
        buf += chunk
    return buf


def ws_recv(s, timeout):
    """Return the next JSON message, or None on timeout. Raises EOFError on close."""
    r, _, _ = select.select([s], [], [], timeout)
    if not r:
        return None
    b0, b1 = _rx(s, 2)
    ln = b1 & 0x7F
    if ln == 126:
        ln = struct.unpack(">H", _rx(s, 2))[0]
    elif ln == 127:
        ln = struct.unpack(">Q", _rx(s, 8))[0]
    if b1 & 0x80:  # server frames are never masked, but be tolerant
        mask = _rx(s, 4)
        payload = bytes(b ^ mask[i % 4] for i, b in enumerate(_rx(s, ln)))
    else:
        payload = _rx(s, ln)
    return json.loads(payload.decode())


# ---------------------------------------------------------------- CDP driver

class CDP:
    def __init__(self, s):
        self.s = s
        self._id = 0
        self.events = []

    def call(self, method, params=None, session_id=None, timeout=8):
        self._id += 1
        msg = {"id": self._id, "method": method, "params": params or {}}
        if session_id:
            msg["sessionId"] = session_id
        ws_send(self.s, msg)
        deadline = time.time() + timeout
        while time.time() < deadline:
            m = ws_recv(self.s, deadline - time.time())
            if m is None:
                continue
            if "id" in m and m["id"] == self._id:
                if "error" in m:
                    raise RuntimeError(f"{method} error: {m['error']}")
                return m.get("result", {})
            if "method" in m:
                self.events.append(m)
        raise TimeoutError(f"no response to {method}")

    def wait_event(self, method, timeout=8):
        for e in self.events:
            if e.get("method") == method:
                return e
        deadline = time.time() + timeout
        while time.time() < deadline:
            m = ws_recv(self.s, deadline - time.time())
            if m is None:
                continue
            if m.get("method") == method:
                return m
            if "method" in m or "id" in m:
                self.events.append(m)
        return None


# ---------------------------------------------------------------- harness

def launch_cold(chrome, persona, port, headless, udd):
    """Launch a COLD browser (no positional URL => 0 pre-warmed page renderers)."""
    args = [
        chrome,
        f"--headless={headless}",
        "--no-sandbox",
        "--disable-gpu",
        f"--remote-debugging-port={port}",
        f"--fingerprint-profile={persona}",
        f"--user-data-dir={udd}",
        # NOTE: deliberately NO positional URL (no about:blank) so the browser
        # starts with zero page targets -- this is what triggers R12.
    ]
    proc = subprocess.Popen(args, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return proc


def browser_ws(port, proc, timeout=20):
    deadline = time.time() + timeout
    while time.time() < deadline:
        if proc.poll() is not None:
            raise RuntimeError(f"chrome exited early (code {proc.returncode})")
        try:
            with urllib.request.urlopen(
                f"http://127.0.0.1:{port}/json/version", timeout=1
            ) as r:
                return json.load(r)["webSocketDebuggerUrl"]
        except Exception:
            time.sleep(0.2)
    raise TimeoutError("devtools endpoint never came up")


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    p = s.getsockname()[1]
    s.close()
    return p


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--chrome", default=os.environ.get("CHROME_BIN"))
    ap.add_argument("--persona", default=os.environ.get("PERSONA"))
    ap.add_argument("--port", type=int, default=0)
    ap.add_argument("--headless", default="new")
    args = ap.parse_args()

    if not args.chrome or not os.path.exists(args.chrome):
        print(f"FAIL: --chrome not found: {args.chrome}", file=sys.stderr)
        return 2
    if not args.persona or not os.path.exists(args.persona):
        print(f"FAIL: --persona not found: {args.persona}", file=sys.stderr)
        return 2

    port = args.port or free_port()
    udd = tempfile.mkdtemp(prefix="r12-udd-")
    proc = None
    results = []

    def record(name, ok, detail=""):
        results.append((name, ok, detail))
        print(f"[{'PASS' if ok else 'FAIL'}] {name}" + (f" — {detail}" if detail else ""))

    try:
        proc = launch_cold(args.chrome, args.persona, port, args.headless, udd)
        ws_url = browser_ws(port, proc)
        cdp = CDP(ws_connect(ws_url))

        # T1 — the crash regression: bare createTarget from a COLD browser.
        try:
            cdp.call("Target.setDiscoverTargets", {"discover": True})
            res = cdp.call("Target.createTarget", {"url": "about:blank"})
            tid = res.get("targetId")
            alive = proc.poll() is None
            record(
                "T1_cold_createTarget_no_crash",
                bool(tid) and alive,
                f"targetId={'yes' if tid else 'none'} browser_alive={alive}",
            )
        except (EOFError, TimeoutError, RuntimeError, ConnectionError) as e:
            crashed = proc.poll() is not None
            record(
                "T1_cold_createTarget_no_crash",
                False,
                f"{type(e).__name__}: {e} (browser_crashed={crashed}) — R12 REGRESSED",
            )
            # connection is dead; cannot continue T2/T3
            raise SystemExit(_finish(results))

        # T2 — auto-attach contract (Puppeteer-style waitForDebuggerOnStart).
        try:
            cdp.call(
                "Target.setAutoAttach",
                {"autoAttach": True, "waitForDebuggerOnStart": True, "flatten": True},
            )
            res = cdp.call("Target.createTarget", {"url": "about:blank"})
            tid2 = res.get("targetId")
            ev = cdp.wait_event("Target.attachedToTarget", timeout=8)
            sess = ev["params"]["sessionId"] if ev else None
            record(
                "T2_setAutoAttach_delivers_attachedToTarget",
                bool(sess),
                f"sessionId={'yes' if sess else 'MISSING'} targetId={'yes' if tid2 else 'none'}",
            )
        except (EOFError, TimeoutError, RuntimeError, ConnectionError) as e:
            record("T2_setAutoAttach_delivers_attachedToTarget", False, f"{type(e).__name__}: {e}")
            sess = None

        # T3 — identity is the fork's spoof, no automation/branding leak.
        if sess:
            try:
                cdp.call("Runtime.runIfWaitingForDebugger", session_id=sess)
                ua = cdp.call(
                    "Runtime.evaluate",
                    {"expression": "navigator.userAgent", "returnByValue": True},
                    session_id=sess,
                )["result"]["value"]
                wd = cdp.call(
                    "Runtime.evaluate",
                    {"expression": "navigator.webdriver", "returnByValue": True},
                    session_id=sess,
                )["result"]["value"]
                ok = ("Chrome/150" in ua) and ("Headless" not in ua) and (wd is False)
                record("T3_identity_no_leak", ok, f"ua={ua!r} webdriver={wd!r}")
            except (EOFError, TimeoutError, RuntimeError, ConnectionError) as e:
                record("T3_identity_no_leak", False, f"{type(e).__name__}: {e}")
        else:
            record("T3_identity_no_leak", False, "skipped (no session from T2)")

    except SystemExit:
        raise
    except Exception as e:  # launch/endpoint failure
        record("harness", False, f"{type(e).__name__}: {e}")
    finally:
        if proc and proc.poll() is None:
            proc.terminate()
            try:
                proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                proc.kill()
        shutil.rmtree(udd, ignore_errors=True)

    return _finish(results)


def _finish(results):
    passed = sum(1 for _, ok, _ in results if ok)
    total = len(results)
    print(f"\n{passed}/{total} checks passed")
    return 0 if passed == total and total > 0 else 1


if __name__ == "__main__":
    sys.exit(main())
