# Plan 04 — Validation & Regression Harness

**Goal:** implement the spec §8 validation ladder as automation. Stand it up right after doc 01
and grow it through docs 02–03. Order matters — "most builds pass 1–2 and fail 3" (spec §8): the
**coherence** test is the real bar.

**Exit criteria**
- [ ] `test/probe/` produces a deterministic JSON fingerprint dump for a running build.
- [ ] Persistence check: same descriptor across restarts → byte-identical dump (CI-automated).
- [ ] Coverage: scripted runs against CreepJS / browserleaks / amiunique / EFF CYT / Brave
      farbling page / fingerprint.com demo, results captured.
- [ ] Coherence: CreepJS "lies"/entropy detector reports **zero** contradictions per shipped
      profile.
- [ ] Regression: per-profile snapshots; CI fails on drift after any Chromium rebase.

---

## T4.1 — The probe (foundation for everything)

`test/probe/probe.html` + a small JS collector that reads **every** spoofed surface and emits one
canonical JSON blob (sorted keys, fixed float formatting) to stdout / a file via a driver.

Cover, at minimum (grows with doc 03):
- Canvas `toDataURL` + `getImageData` hash; WebGL `readPixels` hash; `UNMASKED_VENDOR/RENDERER`.
- WebGPU `adapter.info` (S4). AudioContext fingerprint (003). `getClientRects` (014),
  `measureText` (015).
- `navigator`: `hardwareConcurrency`, `deviceMemory`, `languages`, `language`, `platform`,
  `userAgent`, `userAgentData` (+ high-entropy hints), `webdriver`, `plugins`, `mimeTypes` (S6),
  `usb.getDevices` (S10), `mediaDevices.enumerateDevices` (S3), `keyboard.getLayoutMap` (S7).
- `screen.*` + `devicePixelRatio` + `matchMedia('(resolution:…)')` (S2 — probe both to catch a
  DPR/matchMedia desync); `speechSynthesis.getVoices` (S1);
  `matchMedia` color-scheme/reduced-motion (S8); font-probe set (S9);
  `Intl.DateTimeFormat().resolvedOptions().timeZone` (018); `RTCPeerConnection` presence (S11);
  `geolocation.getCurrentPosition` coords (S12, permission pre-granted);
  Accept-Language and `Sec-CH-UA-*` request headers via a loopback echo endpoint (S5 + UA-CH).

**Driver:** serve the probe over loopback HTTP (not `file://` — some APIs differ) and drive the
build headfully. Use CDP/Puppeteer *or* a `--dump-dom`-style flag. **Caveat (spec §6.4):** if
driving via CDP, additional CDP leaks beyond `Runtime.enable` exist — run at least one probe pass
**without** an automation driver (manual or via a non-CDP launcher) so the harness itself doesn't
mask a leak. Record which mode produced each snapshot.

## T4.2 — Persistence (spec §8.1) — automate first

The cheapest, highest-value gate. CI job `persistence`:

> **Before doc 02 lands**, `--fingerprint-profile` doesn't exist yet — run this early harness with
> the baseline `--fingerprint=<int>` (as in doc 01's smoke test) so the net goes up "right after
> 01" (README §1). Switch to the descriptor below once doc 02 is in.
>
> **Host-OS constraint (README):** persistence snapshots are **per-platform** — because personas
> are host-OS/GPU-class-constrained, generate and validate each persona on a **matching-OS
> runner** (a Linux runner cannot produce a valid Win11 snapshot). CI needs one runner per shipped
> OS (doc 05 T5.1).

1. Launch with a fixed `--fingerprint-profile=fixtures/win11-nvidia-enus.json` **on a matching-OS
   runner**, capture `dump_A.json`.
2. Kill, relaunch same descriptor, capture `dump_B.json`.
3. Assert `dump_A == dump_B` **byte-for-byte**. Any diff = a surface read something
   non-deterministic (time, host state, `absl::Hash`, RNG) — block the merge.
4. Cross-restart *and* cross-run on a clean profile dir. Also assert **two different descriptors →
   different dumps** (no accidental constant).

This subsumes doc 01's smoke test and the doc 02 `SurfacePrng` golden-vector test at the
end-to-end level.

## T4.3 — Coverage (spec §8.2)

Scripted or checklist-driven runs, results archived under `test/coverage/<date>/`:
- **CreepJS** — the primary tool (also feeds T4.4).
- **browserleaks.com** (canvas, webgl, webrtc, fonts, screen, audio), **amiunique.org**,
  **EFF Cover Your Tracks**, **Brave farbling test page**, **fingerprint.com demo**.
- Assert each surface in spec §6.3 **moves** with the descriptor (no dead switch survives — §3.3).
  A coverage failure = a switch registered but not consumed.

Automate what's automatable (browserleaks JSON endpoints, self-hosted CreepJS); keep a manual
checklist for the rest with screenshots archived.

## T4.4 — Coherence (spec §8.3) — the real test

CreepJS's **lies / entropy** detector must flag **zero** contradictions for each shipped profile.
Known contradiction classes to drive out (mirror doc 02's `validate.py` rules, but here observed
live):
- UA/platform says Windows but WebGL/WebGPU renderer says Apple/other (S4↔011↔UA).
- `devicePixelRatio` inconsistent with screen size / OS (S2).
- `navigator.languages` ≠ `Accept-Language` header ordering (S5).
- Fonts present in enumeration but rendering with fallback metrics (S9↔015).
- Timezone inconsistent with locale, or **geolocation coords outside the timezone region**
  (018↔S5↔S12).
- `userAgentData` high-entropy values inconsistent with the `Sec-CH-UA-*` request headers (UA-CH).
- `deviceMemory`/`hardwareConcurrency` outside real ranges or contradicting the persona tier.

**Loop:** run CreepJS → read each flagged lie → trace to the offending surface → fix descriptor
*or* patch → re-run. A profile ships only when clean (spec §8.3, §6 DoD). This is iterative;
budget for it (README §3).

## T4.5 — Regression snapshots (spec §8.4) — rebase survival

The safety net for the §9 "rebase maintenance is the dominant ongoing cost" risk.
1. `test/snapshots/<profile>.json` — the frozen expected probe output per shipped profile.
2. CI job `regression`: build → run probe for each fixture → diff against snapshot → fail on drift.
3. After an intentional Chromium rebase (doc 01 re-run) that legitimately changes a value,
   **regenerate** snapshots in a reviewed commit (`make update-snapshots`) so the diff is explicit
   and audited — never auto-overwrite.
4. Include a **negative** fixture (deliberately contradictory) that `validate.py` must reject, so
   the validator itself is tested.

## T4.6 — CI wiring

Extend the doc-00 CI:
- `build-linux` (compile gate) — already exists.
- `validate-db` — `validate.py` over `profile-db/fixtures/` (schema + coherence). Fast; runs on
  every PR. *(Python — activate the repo venv first per the user's global rule.)*
- `persistence` + `regression` — need a built binary; run on merge to main / nightly (they're
  build-gated and slow). Cache `out/` + siso cache.
- `coherence` (CreepJS) — nightly / pre-release; self-host CreepJS for determinism where possible.

Gate merges on `build-linux` + `validate-db` + `persistence`; gate releases on the full set
including `coherence`.

---

## Definition of done

- Probe covers every §6.3 surface; persistence CI byte-identical; coverage archived; **CreepJS
  zero lies** per shipped profile; regression snapshots frozen + rebase-regeneration flow
  documented; negative fixture rejected.

## Handoff to doc 05

With green persistence + coherence + regression, the build is shippable. Doc 05 signs, packages
per-OS, and formalizes the versioned launch/descriptor contract Raven Browser consumes.
