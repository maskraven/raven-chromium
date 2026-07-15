# Curated real-device personas

Source-verified, coherent descriptors representing popular real devices (one file per
device class). All pass `profile-db/validate.py` (structural + cross-axis coherence).
Distinct from `../fixtures/` (the 3 minimal *contract* examples) — these are the v1
curated DB Raven Browser pairs to matching-OS signed binaries (persona↔host OS/GPU match).

Classes: Windows+{NVIDIA,Intel,AMD}, macOS+{Apple-silicon}, Linux+{NVIDIA}. **8 personas**, each
backed by a HIGH-confidence WebGL parameter bundle in `../webgl/webgl-gpu-params.json`. Two niche
devices (macOS-Intel Iris Plus, Linux-Intel Iris Xe/Mesa) were dropped in favour of a uniformly
HIGH-confidence set — every remaining GPU's full WebGL param bundle is real-capture or large-corpus
sourced, not inferred.

## Provenance
`gpu.renderer` strings are the exact ANGLE `UNMASKED_RENDERER_WEBGL` values per OS backend
(D3D11 + hex device-ID on Windows; `ANGLE Metal Renderer` on macOS; `Mesa …`/`…/PCIe/SSE2,
OpenGL … NVIDIA` on Linux), from public WebGL-renderer corpora + PCI device-ID DBs; screen
res/dpr, CPU thread counts, and locale/timezone triples from hardware-share stats.

macOS Apple-Silicon WebGL bundles are a direct Chrome-150 ANGLE-Metal capture (family-constant across
M1/M2/M3/M4 — only the renderer chip string differs); Windows/Linux bundles are large-corpus sourced
(web3dsurvey). Per the detection research, a coherent whole-device bundle is sufficient — exact-host
capture is not required (see [[raven-webgl-dataset-strategy]]).

## Verify-before-shipping (flagged by research; confirm against a live capture on the target)
- `gpu.vendor` on Linux-NVIDIA (`Google Inc. (NVIDIA Corporation)`).
- WebGPU `gpu.architecture`/`gpu.device` (Dawn may report `""`; validator doesn't check these).
- GPU hex device-IDs (desktop vs mobile variants) match the intended device.
- macOS Retina `colorDepth`/`pixelDepth` = 30 (P3 wide-gamut) on the target display.
