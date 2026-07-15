# Plan 03 — Surface implementation spec (execution plan)

Consolidates the VERIFY@150 recon map + descriptor schema (§6 D1) + ratified design (identity axes
read from descriptor; `SurfacePrng` only for within-profile jitter; coherence pairs single-sourced).
One worktree-isolated agent per surface in the Plan 03 workflow. Priority order per orchestrator:
**speech → screen/pointer → media devices → WebGPU → languages** first, then the rest.

Legend: **Src** = descriptor-driven identity (deterministic, no PRNG). **Jitter** = `SurfacePrng(seed, kX)`.
All paths VERIFY@150-confirmed. `fingerprint::Profile::Get()` (Plan 02) supplies descriptor + seed.

| # | Surface | 150 path(s) | Descriptor field(s) | Approach | Coherence pair |
|---|---|---|---|---|---|
| 1 | navigator.languages + **Accept-Language** | `core/frame/navigator_language.cc`; source `chrome/browser/renderer_preferences_util.cc` (`accept_languages`) | `languages[]`, `locale` | **Src** — set once at `RendererPreferences.accept_languages` (single source feeds BOTH JS + HTTP header) | languages↔Accept-Language↔locale↔timezone — **never double-derive** |
| 2 | speech voices | `modules/speech/speech_synthesis.cc` | `os`, `locale` | **Src** — replace platform voice list with canned OS+locale-appropriate set (real Win/mac/Linux voice tables) | voices↔os↔locale |
| 3 | screen / pointer / hover | `core/frame/screen.cc`; `core/css/media_query_evaluator.cc` | `screen.{w,h,dpr,colorDepth,pixelDepth,availW,availH}` | **Src** — feed screen dims; pointer=fine + hover=hover for desktop os. **ADD** `--fingerprint-screen-*` switches (recon: they do NOT exist in 150 — declare in `ungoogled_switches.*`) | screen↔dpr↔os; pointer/hover↔desktop os |
| 4 | media devices | `modules/mediastream/media_devices.cc` | `os` (+ seed) | **Src+Jitter** — canned plausible device set (counts by kind for os); stable per-profile `deviceId`s via `SurfacePrng(seed,kMediaDevices)`; labels empty pre-permission (spec) | device set↔os |
| 5 | WebGPU adapter info | `modules/webgpu/gpu_adapter_info.cc` | `gpu.{vendor,architecture,device}` | **Src** — report descriptor gpu; **MUST equal** WebGL UNMASKED renderer (patch 011) | WebGPU adapter↔WebGL renderer↔`gpu.*` |
| 6 | plugins / mimeTypes | `modules/plugins/{navigator_plugins,dom_plugin_array}.cc` | (canned) | **Src** — Chrome's fixed internal PDF plugin set; keep `pdfViewerEnabled` consistent | plugins↔pdfViewerEnabled↔os |
| 7 | keyboard layout | `modules/keyboard/keyboard_layout_map.cc` | `locale`, `os` | **Src** — layout map from locale/os | keyboard↔locale↔os |
| 8 | dark mode (prefers-color-scheme) | `core/css/media_query_evaluator.cc` + `core/frame/settings.json5` | `colorScheme` (add, optional; default light) | **Src** — stable preferred scheme per profile | stable per profile |
| 9 | fonts | `platform/fonts/font_cache.cc` (patch 006 extends) + `modules/font_access/font_access.cc` | `os` (host-derived metrics) | **Src** — OS-appropriate font list; v1 host-OS-matched (metrics are host-real). Two surfaces: enumeration + Local Font Access | fonts↔os (host match) |
| 10 | WebUSB | `modules/webusb/usb.cc` | — | **Src** — `getDevices()` → stable empty (no paired devices) | — |
| 11 | WebRTC hard-disable | `modules/peerconnection/rtc_peer_connection.cc`; `RendererPreferences.webrtc_ip_handling_policy` | — | **Disable** — gate the module + force IP-handling policy so no local/public IP leaks (builds on ungoogled WebRTC patches) | no IP leak vs geo/tz |
| 12 | geolocation | `core/geolocation/` (**RELOCATED** from modules/) | `timezone`, `locale` | **Src** — v1: deny by default OR coarse location coherent with timezone region | geo↔timezone↔locale |

## Cross-cutting (fold in during the above)
- **148 GPU param set** — extend patch 011 (gpu-info) + the WebGL surface beyond UNMASKED vendor/renderer
  to the full `getParameter`/extension set sourced from the descriptor's real captured device
  (`gpu.*`). WebGPU (#5), WebGL (011), and `gpu.*` MUST be mutually consistent (one real device).
- **deviceMemory** — already handled: descriptor-driven, spec-clamped ≤8 (see `02-ratified-design.md` §6 D1).
- **Native ungoogled noise** — ungoogled-150 carries bromite client-rects/canvas noise on `base::RandDouble`
  (see `01-rebase-status.md`). Surfaces touching canvas (012/013), client-rects (014), measure-text (015)
  must ensure the deterministic `SurfacePrng` path is the ONE active noise source (disable/replace the
  random layer), else double-perturbation.
- **Host-OS/GPU match** — no cross-OS personas in v1; every surface value must be real for the build/validation host's OS+GPU class.

## Series placement
New surfaces → `patches/fingerprint/2xx-<surface>.patch`, applied AFTER `core/1xx` (Profile) and the
rebased baseline `fingerprint/{b02,0xx}`. Each patch: VERIFY@150 path → read descriptor field via
`Profile::Get()` → enforce coherence with its paired axis → build-verify.
