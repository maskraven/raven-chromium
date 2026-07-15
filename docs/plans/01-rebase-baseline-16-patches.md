# Plan 01 — Rebase the 16 Baseline Patches (144 → 150)

**Goal:** the fingerprint-chromium 144 patch set (spec §3.2) applies on the pinned
ungoogled-chromium-150 tree and produces a `chrome` that reproduces the *baseline* spoofing
semantics — before we upgrade the PRNG (doc 02) or add surfaces (doc 03). This is the
"treadmill" the upstream project stopped running at 148 (spec §7.2); budget real time.

**Exit criteria**
- [ ] All 16 patches in `patches/series`, applied by `build/apply-patches.sh` with zero rejects.
- [ ] Tree builds (`gen-and-build.sh`) and runs.
- [ ] Baseline behavior confirmed: `--fingerprint=<int>` changes canvas/webgl/audio/UA outputs;
      same int reproduces byte-identical outputs across restarts (first data point for doc 04).
- [ ] Known dead switches (spec §3.3) documented as *still dead at this stage* — do **not** fix
      them here; they are doc 03's work (screen → S2, geolocation → S12).

---

## Method (per patch)

Work **in `patches/series` order**. For each baseline patch:

1. **Copy** the 144 patch into `patches/fingerprint/<nnn>-<name>.patch`; add its name to
   `patches/series`.
2. **Try apply:** `git -C $CHROMIUM_SRC apply --3way patches/fingerprint/<nnn>-<name>.patch`.
   - Clean → move on.
   - Rejects → open the `.rej` and the target file at 150, re-anchor the hunk **by intent, not by
     line number**. The DOM/Blink API being patched usually still exists; only surrounding code
     moved. Re-derive the minimal change.
3. **Re-check the top-of-file comment**: purpose, spec §, switches, `VERIFY@150` targets (README
   §5). Update paths that moved.
4. **Build incrementally** after each risky patch (canvas/webgl/v8) rather than all-at-once —
   smaller blast radius when something fails to compile.
5. **Smoke-test** the specific surface (probe snippet) before moving on.

> Keep patches minimal and intent-preserving. Do **not** refactor to `randen_engine` yet — that's
> doc 02 and it touches every derivation site. Rebase first, refactor second, so a rebase failure
> and a design change never tangle in the same diff.

---

## The 16 patches — rebase notes

Numbers/names/paths from spec §3.2 (144 tree). Every path is **`VERIFY@150`**. "Churn" = how
likely the target file moved between 144 and 150.

| # | Patch | Primary target(s) | Churn | Rebase watch-outs |
|---|---|---|---|---|
| 000 | add-fingerprint-switches | `components/ungoogled/ungoogled_switches.{h,cc}`, `content/browser/renderer_host/render_process_host_impl.cc` | Med | Switch-registration boilerplate is stable; the **browser→renderer propagation** call site in `RenderProcessHostImpl` (where child cmdline is assembled) is the fragile part. Find the current `AppendRendererCommandLine`/`PropagateBrowserCommandLineToRenderer` and re-anchor. Doc 02 extends this exact site. |
| 001 | disable-runtime.enable | `v8/src/inspector/v8-runtime-agent-impl.{h,cc}` | **High** | V8 inspector churns. Re-find where `Runtime.enable` wires the agent; neuter the same path. Confirm against doc 03's CDP-leak caveat (spec §6.4) — this only closes the `Runtime.enable` leak, not all CDP leaks. |
| 002 | user-agent-fingerprint | UA + Client Hints assembly (`components/embedder_support/user_agent_utils.cc` and/or Blink UA) | **High** | UA/Client-Hints code is heavily refactored across milestones (reduced-UA work). Ensure UA string **and** UA-CH low/high-entropy hints both derive from the same fields (coherence). This patch is superseded/expanded by doc 02's descriptor — keep it faithful now, re-point in 02. |
| 003 | audio-fingerprint | `third_party/blink/renderer/modules/webaudio/offline_audio_context.cc` | Low | Seeded ±0.01 noise on sample rate + frame count. Localized; usually applies with an offset. **Note:** doc 02 T2.5 re-points this to `FarbleAudioChannel` (PCM-buffer noise) — a *different* hook and a *different* observable than sampleRate/frameCount. The standard audio-fingerprint test hashes the rendered buffer, so decide which observable 003 owns before refactoring (doc 02 T2.5). |
| 005 | hardware-concurrency | `.../core/frame/navigator_concurrent_hardware.cc`, `navigator_device_memory.cc` | Low | Note the baseline **hardcodes `deviceMemory` to 8** (spec §3.2). Preserve behavior now; doc 02/03 make it descriptor-driven. |
| 006 | font-fingerprint | font matching / enumeration | Med | Font stack moves around. This is the *seeded* baseline; doc 03 replaces the model with an OS-allowlist (Brave `AllowFontFamily`). Keep it applying for now even if thin. |
| 007 | shadow-root | `.../core/dom/element.{h,cc}` | Med | Adds `fakeShadowRoot` for closed-shadow access (automation). `Element` churns; re-anchor the accessor. Keep (spec §6.4). |
| 009 | webdriver | `.../core/frame/navigator.cc` | Low | Removes forced `navigator.webdriver === true`. Small, stable. Keep (spec §6.4). |
| 010 | headless | `headless/lib/browser/headless_browser_impl.cc` | Med | Renames `HeadlessChrome`→`Chrome` in UA. Verify the UA assembly path didn't move the string. Keep (spec §6.4). |
| 011 | gpu-info | GPU info / WebGL `UNMASKED_VENDOR/RENDERER` | Med | Spoofs WebGL unmasked strings. Must later agree with WebGPU (doc 03 surface 4) — leave a `TODO(coherence): keep in sync with webgpu` marker. **Strings only:** the WebGL extension list, `MAX_*` parameters, and shader-precision formats still come from the *host* GPU/driver and are hashed by fingerprinters. Under the host-GPU-class constraint (README) that's acceptable, but a persona must never claim a GPU outside the host's class or the string contradicts the real parameter set (doc 03 §S4). |
| 012 | canvas-get-image-data | `.../modules/canvas/canvas2d/base_rendering_context_2d.cc`, `.../platform/graphics/static_bitmap_image.cc` | **High** | Deterministic LSB perturbation of ≤10 edge pixels keyed by `hash(seed+coords)`. Canvas2D is a top-churn file (spec §7.2). Expect to re-derive the hunk. This is a prime doc-02 refactor target (swap the hash). |
| 013 | canvas-toDataURL | encode path (near 012's files) | **High** | Same noise on `toDataURL`. Rebase alongside 012. |
| 014 | client-rects | `getClientRects`/`getBoundingClientRect` path | Med | Noise on rects. Re-anchor the layout-to-DOMRect conversion site. |
| 015 | canvas-measure-text | `.../canvas2d/base_rendering_context_2d.cc` | **High** | Noise on `measureText` metrics; shares the 012 file. Must stay consistent with the font surface (doc 03). |
| 016 | webgl-readPixels | `.../modules/webgl/webgl_rendering_context_base.cc` | **High** | Applies canvas noise to WebGL `readPixels`. Big, churny file. |
| 018 | timezone | `.../core/timezone/timezone_controller.cc` (+ V8 notify) | Med | `--timezone` overrides ICU zone and notifies V8. Verify the ICU + V8 `DateTimeConfigurationChangeNotification` path. Coherence: timezone must later match descriptor locale (doc 02/03). |

(004, 008, 017 are unused numbers — 16 files total, spec §3.2.)

**Batching suggestion:** rebase in three passes so failures cluster by subsystem:
1. Plumbing + automation: `000, 001, 007, 009, 010` (get switches + hiding working).
2. Cheap surfaces: `003, 005, 006, 011, 018, 002` (mostly localized).
3. High-churn graphics: `012, 013, 015, 016, 014` (budget the most time here).

---

## Baseline behavior verification (before declaring 01 done)

Stand up the **minimum probe** now (full harness is doc 04):

1. A local `test/probe/probe.html` that reads and JSON-dumps: canvas `toDataURL` hash, WebGL
   `getImageData`/`readPixels` hash, `UNMASKED_VENDOR/RENDERER`, `AudioContext` fingerprint,
   `navigator.hardwareConcurrency`, `navigator.deviceMemory`, UA + `userAgentData`,
   `Intl.DateTimeFormat().resolvedOptions().timeZone`, `navigator.webdriver`.
2. Launch `chrome --fingerprint=4815162342 --timezone=America/New_York`, load the probe, save
   `test/snapshots/baseline-4815162342.json`.
3. Restart, reload → **byte-identical** (persistence, spec §8.1). If not, a patch is reading
   something non-deterministic — fix before proceeding.
4. Change to `--fingerprint=1234567890` → outputs change; back to the first → outputs return.
5. **Record the known-dead switches** (`--fingerprint-screen-width/-height/`
   `-device-scale-factor`, `--fingerprint-location`, spec §3.3) as producing *no effect*. This is
   expected; doc 03 implements them. Add an xfail note to the snapshot.

---

## Definition of done

- 16 patches applied + building + running on pinned 150.
- Persistence smoke test green; dead switches documented as dead.
- Each patch's header updated with confirmed 150 paths (remove `VERIFY@150` where confirmed,
  keep where you had to guess).
- CI `build-linux` green with the full baseline series.

## Handoff to doc 02

The tree now behaves like fingerprint-chromium 144 on a 150 base, using the weak
`std::hash & 1` derivation. Doc 02 replaces that derivation with Brave's `randen_engine` + a
keyed per-surface seed, and introduces the JSON descriptor — touching many of the sites you just
rebased. Land 01 cleanly first so 02's diff is purely the design change.
