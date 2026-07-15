// Copyright 2026 The Raven Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license.
//
// fingerprint::Profile — the ONE process-global source of spoofed identity.
//
// Raven's design (docs/plans/02-ratified-design.md) inverts Brave: the seed is
// FIXED + per-profile (fix-to-impersonate), not random + per-domain. Brave's
// ExecutionContext-scoped Supplement (BraveSessionCache) therefore collapses
// into a lazily-initialized, process-global singleton that every blink
// renderer surface (canvas/webgl/audio/navigator/screen across core, modules
// and platform) reads through Profile::Get().
//
// This lives in blink's platform layer — the lowest blink layer, depended on
// by both core and modules — so all surfaces can reach it, mirroring where
// Brave keeps its lowest-layer farbling primitive (BraveAudioFarblingHelper,
// third_party/blink/renderer/platform/). See WIRING.md.

#ifndef THIRD_PARTY_BLINK_RENDERER_PLATFORM_FINGERPRINT_PROFILE_H_
#define THIRD_PARTY_BLINK_RENDERER_PLATFORM_FINGERPRINT_PROFILE_H_

#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

#include "third_party/blink/renderer/platform/platform_export.h"
#include "third_party/lifted/farbling_prng.h"

namespace base {
template <typename T>
class NoDestructor;
}  // namespace base

namespace fingerprint {

// Frozen v1 descriptor. Fields mirror descriptor.schema.json / design §6 D1
// exactly (JSON keys = JS-observable names). Identity axes are read verbatim;
// the seed drives only within-profile jitter and is never an identity axis.
struct PLATFORM_EXPORT Descriptor {
  Descriptor();
  Descriptor(const Descriptor&);
  Descriptor& operator=(const Descriptor&);
  ~Descriptor();

  struct Gpu {
    std::string vendor;        // gpu.vendor  (UNMASKED_VENDOR_WEBGL)
    std::string renderer;      // gpu.renderer (UNMASKED_RENDERER_WEBGL)
    std::string architecture;  // gpu.architecture (WebGPU adapter)
    std::string device;        // gpu.device       (WebGPU adapter)
  };

  struct Screen {
    int w = 0;             // screen.width
    int h = 0;             // screen.height
    double dpr = 1.0;      // window.devicePixelRatio
    int color_depth = 24;  // screen.colorDepth
    int pixel_depth = 24;  // screen.pixelDepth
    int avail_w = 0;       // screen.availWidth
    int avail_h = 0;       // screen.availHeight
  };

  int schema_version = 0;              // schemaVersion (== 1 for v1)
  uint64_t seed = 0;                   // seed (u64; jitter only)
  std::string os;                      // os: "windows" | "macos" | "linux"
  std::string platform;                // navigator.platform
  int chrome_major = 0;                // chromeMajor
  int hardware_concurrency = 0;        // navigator.hardwareConcurrency
  double device_memory = 0.0;          // navigator.deviceMemory (GiB)
  Gpu gpu;                             // gpu.{vendor,renderer,architecture,device}
  Screen screen;                       // screen.{w,h,dpr,...}
  std::vector<std::string> languages;  // navigator.languages
  std::string locale;                  // default locale (BCP-47)
  std::string timezone;                // IANA tz name
};

// Closed set of jitter surfaces. A typo cannot silently spawn a new PRNG
// stream because the enum is exhaustive and each value maps to a stable tag.
// kMaxValue aliases the last real value (Chromium histogram convention).
enum class Surface {
  kCanvas,
  kAudio,
  kFonts,
  kWebgl,
  kInteger,
  kMediaDevices,
  kScreen,
  kSpeech,
  kLanguages,
  kWebgpu,
  kPlugins,
  kMaxValue = kPlugins,
};

// Stable ASCII tag per surface — the SipHash message in the derivation chain.
// Tags are frozen: changing one silently re-rolls that surface's stream.
constexpr const char* SurfaceTag(Surface s) {
  switch (s) {
    case Surface::kCanvas:
      return "canvas";
    case Surface::kAudio:
      return "audio";
    case Surface::kFonts:
      return "fonts";
    case Surface::kWebgl:
      return "webgl";
    case Surface::kInteger:
      return "integer";
    case Surface::kMediaDevices:
      return "media-devices";
    case Surface::kScreen:
      return "screen";
    case Surface::kSpeech:
      return "speech";
    case Surface::kLanguages:
      return "languages";
    case Surface::kWebgpu:
      return "webgpu";
    case Surface::kPlugins:
      return "plugins";
  }
  return "";
}

// The ONE place identity is read. Process-global, lazily initialized on first
// Get(), thread-safe (magic-static). On first use it decodes the renderer's
// --fingerprint-profile-data switch (base64(compact-json)) into descriptor_ +
// seed_. If the switch is absent or invalid, the profile is INACTIVE: active()
// is false and accessors return host-neutral defaults — it never crashes.
class PLATFORM_EXPORT Profile {
 public:
  Profile(const Profile&) = delete;
  Profile& operator=(const Profile&) = delete;

  // Returns the immutable process singleton. Safe to call from any thread; the
  // descriptor is populated once at construction and never mutated afterward.
  static Profile& Get();

  // True iff a valid descriptor was decoded. Surfaces MUST check this before
  // spoofing; when false, leave host values untouched.
  bool active() const { return active_; }

  // Verbatim identity axes (valid only when active()).
  const Descriptor& descriptor() const { return descriptor_; }

  // Per-profile jitter seed (0 when inactive).
  uint64_t seed() const { return seed_; }

 private:
  Profile();
  ~Profile();
  friend class base::NoDestructor<Profile>;

  bool active_ = false;
  uint64_t seed_ = 0;
  Descriptor descriptor_;
};

// The ONE factory for per-surface jitter streams (design §1):
//   key128       = splitmix64_expand(seed)          // two fixed-const steps
//   surface_seed = SipHash-2-4(key128, SurfaceTag(s))
//   return FarblingPRNG(surface_seed)
// Statistically independent streams per surface from a single seed.
PLATFORM_EXPORT FarblingPRNG SurfacePrng(uint64_t seed, Surface s);

// Canvas content-coupled variant (design §3). Depends on BOTH the profile seed
// AND the canvas pixel bytes, so identical canvases on different profiles — and
// different canvases on one profile — perturb differently, without HMAC:
//   canvas_key128 = splitmix64_expand(SurfacePrng-seed for kCanvas)
//   noise_seed    = SipHash-2-4(canvas_key128, bytes)
//   return FarblingPRNG(noise_seed)
PLATFORM_EXPORT FarblingPRNG CanvasPrng(uint64_t seed,
                                        const uint8_t* bytes,
                                        size_t len);

}  // namespace fingerprint

#endif  // THIRD_PARTY_BLINK_RENDERER_PLATFORM_FINGERPRINT_PROFILE_H_
