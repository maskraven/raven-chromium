# Plan 05 — Packaging & Release Contract

**Goal:** turn a validated build into **signed per-OS binaries** and formalize the **versioned
launch/descriptor contract** that the closed Raven Browser app consumes (README: "consumes Raven
Chromium's signed binaries via a versioned launch/descriptor contract — never its source").

**Exit criteria**
- [ ] Reproducible release build for macOS (arm64 + x64), Windows (x64), Linux (x64).
- [ ] Code-signed + (macOS) notarized artifacts; verifiable signatures.
- [ ] **No "Raven" string in the runtime fingerprint** — UA/branding report real Chrome
      (README, spec §1). Name lives only in repo/CLI/installer metadata.
- [ ] Published, versioned CLI + descriptor-schema contract doc for Raven Browser.
- [ ] Release CI produces artifacts + attaches probe snapshots + `validate-db` result.

---

## T5.1 — Release build configuration

- Per-platform `build/args/*.gn` promoted to release: `is_official_build = true` (or the
  ungoogled equivalent), `symbol_level = 1`, strip, `is_debug = false`,
  `dcheck_always_on = false`. Keep the ungoogled `flags.gn` base (doc 00).
- Targets: `mac-arm64`, `mac-x64` (or universal via `lipo`), `win-x64`, `linux-x64`. Match each
  platform SDK to the milestone pin (doc 00 T0.1).
- Build via the reproducible **tarball path** (doc 00 Path B) so releases are deterministic; keep
  `build/PINS` as the provenance record.
- **Persona ↔ artifact OS/GPU match (README constraint).** Each per-OS artifact ships only personas
  whose `os`/`gpu` class matches that artifact, and its persistence/coherence validation (doc 04)
  runs on a **matching-OS runner**. There is no cross-OS persona in v1 — a Win11 persona is only
  valid in (and validated against) the Windows build. Provision a build+validation runner per
  shipped OS.

## T5.2 — Branding scrub (must not leak into fingerprint)

The single most important packaging rule (README, spec §1): the running browser **is** real
Chrome to any detector.
- Confirm baseline `010 headless` + `002 user-agent` (doc 01) leave a **stock Chrome UA** and
  UA-CH — no "Raven", no "Chromium", no "Headless".
- App/product name, `CFBundleName`/`.desktop`/exe metadata, crash-reporter product tag may say
  "Raven Chromium" (installer/OS-level identity) **but** none of it may reach:
  `navigator.userAgent`, `userAgentData`, `navigator.appName/appVersion/vendor`, WebGL renderer,
  window title defaults, or JS-reachable branding.
- **Add a probe assertion** (doc 04): grep the full probe dump for `raven`/`chromium`/`headless`
  (case-insensitive) → fail the release if any appears in a JS-visible field.

## T5.3 — Signing & notarization

- **macOS:** `codesign` with a Developer ID (hardened runtime, entitlements matching Chromium's:
  JIT, unsigned-executable-memory, etc.), then `notarytool submit` + `stapler`. Sign the full
  `.app` bundle (frameworks, helpers) — Chromium has many nested Mach-O binaries; use the
  Chromium/`sign_chrome`-style recursive signing flow.
- **Windows:** Authenticode sign the exe + DLLs (EV cert recommended for SmartScreen reputation).
- **Linux:** ship a tarball / AppImage; detached GPG signature + published checksums.
- Store signing creds in CI secrets; never in-repo. Emit `SHA256SUMS` + signatures per artifact.

## T5.4 — The launch/descriptor contract (Raven Browser ↔ Raven Chromium)

This is the API boundary between the two separate projects. Publish it as
`docs/contract/launch-contract-v<N>.md` and version it.

Contents:
1. **CLI surface** — the stable switch set Raven Browser may pass:
   - `--fingerprint-profile=<path>` (primary; the JSON descriptor, doc 02 T2.4).
   - `--user-data-dir=<path>` (per-profile isolation).
   - The thin `--fingerprint*` / `--timezone` overrides (testing only; document as unstable).
   - Explicitly list switches Raven Browser must **not** rely on (internal/volatile).
2. **Descriptor schema** — reference `profile-db/schema/descriptor.schema.json` +
   `schemaVersion`. Raven Browser writes descriptors against this versioned schema. Document the
   compatibility policy (additive fields = minor bump; renames/removals = major bump + migration).
3. **Descriptor delivery** — resolve spec §11 open item: browser reads the JSON from a
   **temp file at launch** (`--fingerprint-profile`), then propagates internally (doc 02 T2.4).
   Document lifetime/cleanup expectations for the temp file.
4. **Binary handoff** — Raven Browser consumes **signed binaries only** (never source). Document
   artifact naming, per-OS layout, signature-verification steps Raven Browser should perform
   before launch, and the version-pinning scheme (which Raven Chromium build a given Raven Browser
   release expects).
5. **Guarantees** — persistence (same descriptor ⇒ same fingerprint), coherence (validated
   profiles only), the WebRTC-absence behavior (decision §11.3) so the app doesn't expect
   `RTCPeerConnection`, **the OS/GPU-class match** (a persona is only valid on the matching-OS
   binary — Raven Browser must pair descriptors to the right artifact), and geolocation returning
   the descriptor coordinates (permission-gated).

> Keep this contract **narrow and versioned**. It's the only thing coupling the open fork to the
> closed app; churn here breaks Raven Browser releases.

## T5.5 — Release CI

Extend doc 04's CI with a `release` workflow (tag-triggered):
1. Reproducible build per platform (T5.1) from the pinned tarball.
2. Sign + notarize (T5.3).
3. Run the full validation set (doc 04): `persistence`, `regression`, branding-scrub assertion
   (T5.2), `validate-db`.
4. Attach to the release: signed artifacts, `SHA256SUMS` + signatures, the probe snapshots for
   each shipped profile, the `build/PINS` provenance, and the current `launch-contract-v<N>.md`.
5. Do **not** publish the proprietary real-device DB (README, spec §11.2) — only schema +
   validator + public fixtures live in this repo.

## T5.6 — Rebase-maintenance runbook (the ongoing cost, spec §9)

Document the recurring cycle so it's a checklist, not tribal knowledge:
1. Bump `build/PINS` to the next ungoogled-150→15x tag.
2. Re-run doc 01 rebase (expect churn in canvas/webgl/v8-inspector).
3. Re-verify all `VERIFY@150` paths at the new milestone.
4. Run doc 04 full ladder; regenerate snapshots in a reviewed commit if values legitimately moved.
5. Re-run coherence (CreepJS) — new milestones can add/rename surfaces that create fresh lies.
6. Re-sign + release; bump the launch contract only if the CLI/schema changed.

---

## Definition of done

- Signed, notarized artifacts for all target OSes; branding scrub passes; launch/descriptor
  contract published + versioned; release CI green with validation + provenance attached; rebase
  runbook documented.

## Project-level definition of done (v1)

Ties back to [README §6](README.md): N curated real-device profiles each passing **persistence +
coverage + coherence + regression**, delivered as signed binaries behind a versioned contract,
with the rebase treadmill documented as an owned, recurring cost.
