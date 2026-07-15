// Copyright 2026 The Raven Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license.

#include "third_party/blink/renderer/platform/fingerprint/profile.h"

#include <cstring>
#include <optional>
#include <string>
#include <string_view>
#include <vector>

#include "base/base64.h"
#include "base/command_line.h"
#include "base/json/json_reader.h"
#include "base/no_destructor.h"
#include "base/strings/string_number_conversions.h"
#include "base/values.h"
#include "third_party/lifted/siphash.h"

namespace fingerprint {

namespace {

// Renderer switch carrying base64(compact-json) of the descriptor. Registered
// browser-side by patches/core/102 in components/ungoogled/ungoogled_switches
// and allowlisted onto the child cmdline (design §4/§8). Kept as a literal here
// so the platform layer needs no dependency on //components/ungoogled; 102 may
// swap this for switches::kFingerprintProfileData.
constexpr char kProfileDataSwitch[] = "fingerprint-profile-data";

// Accepted contract major (design §6 D1). Unknown major => hard fail (inactive).
constexpr int kSchemaVersion = 1;

// One splitmix64 step: a fixed-constant integer mixer (NOT a banned primitive —
// no absl::Hash / base::RandUint64 / Time::Now / std::hash). Advances |state|
// and returns the mixed output.
uint64_t SplitMix64(uint64_t* state) {
  uint64_t z = (*state += 0x9E3779B97F4A7C15ULL);
  z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9ULL;
  z = (z ^ (z >> 27)) * 0x94D049BB133111EBULL;
  return z ^ (z >> 31);
}

// splitmix64_expand: two fixed-const splitmix64 steps expand a u64 seed into a
// 128-bit SipHash key, written little-endian as k0 || k1 (matching how
// siphash.cc's Load64LE reads key[0..7] and key[8..15]).
void SplitMix64Expand(uint64_t seed, uint8_t key128[16]) {
  uint64_t state = seed;
  const uint64_t k0 = SplitMix64(&state);
  const uint64_t k1 = SplitMix64(&state);
  std::memcpy(key128, &k0, sizeof(k0));
  std::memcpy(key128 + 8, &k1, sizeof(k1));
}

// Reads a u64 seed that may be encoded as a decimal string (canonical, so it
// survives values beyond the JS safe-integer range) or a JSON number.
uint64_t ParseSeed(const base::Value::Dict& dict) {
  if (const std::string* s = dict.FindString("seed")) {
    uint64_t out = 0;
    if (base::StringToUint64(*s, &out)) {
      return out;
    }
    return 0;
  }
  if (std::optional<double> d = dict.FindDouble("seed")) {
    if (*d >= 0.0) {
      return static_cast<uint64_t>(*d);
    }
  }
  return 0;
}

void ParseGpu(const base::Value::Dict& dict, Descriptor::Gpu* gpu) {
  if (const std::string* v = dict.FindString("vendor")) {
    gpu->vendor = *v;
  }
  if (const std::string* v = dict.FindString("renderer")) {
    gpu->renderer = *v;
  }
  if (const std::string* v = dict.FindString("architecture")) {
    gpu->architecture = *v;
  }
  if (const std::string* v = dict.FindString("device")) {
    gpu->device = *v;
  }
}

void ParseScreen(const base::Value::Dict& dict, Descriptor::Screen* screen) {
  screen->w = dict.FindInt("w").value_or(screen->w);
  screen->h = dict.FindInt("h").value_or(screen->h);
  screen->dpr = dict.FindDouble("dpr").value_or(screen->dpr);
  screen->color_depth = dict.FindInt("colorDepth").value_or(screen->color_depth);
  screen->pixel_depth = dict.FindInt("pixelDepth").value_or(screen->pixel_depth);
  screen->avail_w = dict.FindInt("availW").value_or(screen->avail_w);
  screen->avail_h = dict.FindInt("availH").value_or(screen->avail_h);
}

// Parses the compact-JSON descriptor. Returns true and fills |out| on success;
// on any structural failure returns false and leaves the profile inactive.
bool ParseDescriptor(std::string_view json, Descriptor* out) {
  std::optional<base::Value::Dict> root =
      base::JSONReader::ReadDict(json, base::JSON_PARSE_RFC);
  if (!root) {
    return false;
  }

  // schemaVersion gate: unknown major is a hard fail.
  std::optional<int> version = root->FindInt("schemaVersion");
  if (!version || *version != kSchemaVersion) {
    return false;
  }
  out->schema_version = *version;
  out->seed = ParseSeed(*root);

  if (const std::string* s = root->FindString("os")) {
    out->os = *s;
  }
  if (const std::string* s = root->FindString("platform")) {
    out->platform = *s;
  }
  out->chrome_major = root->FindInt("chromeMajor").value_or(0);
  out->hardware_concurrency = root->FindInt("hardwareConcurrency").value_or(0);
  out->device_memory = root->FindDouble("deviceMemory").value_or(0.0);

  if (const base::Value::Dict* gpu = root->FindDict("gpu")) {
    ParseGpu(*gpu, &out->gpu);
  }
  if (const base::Value::Dict* screen = root->FindDict("screen")) {
    ParseScreen(*screen, &out->screen);
  }
  if (const base::Value::List* langs = root->FindList("languages")) {
    for (const base::Value& item : *langs) {
      if (const std::string* tag = item.GetIfString()) {
        out->languages.push_back(*tag);
      }
    }
  }
  if (const std::string* s = root->FindString("locale")) {
    out->locale = *s;
  }
  if (const std::string* s = root->FindString("timezone")) {
    out->timezone = *s;
  }
  return true;
}

}  // namespace

Descriptor::Descriptor() = default;
Descriptor::Descriptor(const Descriptor&) = default;
Descriptor& Descriptor::operator=(const Descriptor&) = default;
Descriptor::~Descriptor() = default;

Profile::Profile() {
  const base::CommandLine* command_line =
      base::CommandLine::ForCurrentProcess();
  if (!command_line || !command_line->HasSwitch(kProfileDataSwitch)) {
    return;  // Inactive: no switch — leave host defaults, active_ == false.
  }

  const std::string encoded =
      command_line->GetSwitchValueASCII(kProfileDataSwitch);
  std::optional<std::vector<uint8_t>> decoded = base::Base64Decode(encoded);
  if (!decoded) {
    return;  // Inactive: malformed base64.
  }

  const std::string_view json(reinterpret_cast<const char*>(decoded->data()),
                              decoded->size());
  Descriptor parsed;
  if (!ParseDescriptor(json, &parsed)) {
    return;  // Inactive: malformed / wrong-version descriptor.
  }

  descriptor_ = std::move(parsed);
  seed_ = descriptor_.seed;
  active_ = true;
}

Profile::~Profile() = default;

// static
Profile& Profile::Get() {
  // Magic-static: thread-safe one-time construction (C++11). The descriptor is
  // immutable afterward, so concurrent reads from renderer threads are safe.
  static base::NoDestructor<Profile> instance;
  return *instance;
}

FarblingPRNG SurfacePrng(uint64_t seed, Surface s) {
  uint8_t key128[16];
  SplitMix64Expand(seed, key128);
  const uint64_t surface_seed = SipHash24Tag(key128, SurfaceTag(s));
  return FarblingPRNG(surface_seed);
}

FarblingPRNG CanvasPrng(uint64_t seed, const uint8_t* bytes, size_t len) {
  // canvas_key128 = splitmix64_expand( canvas-surface seed ), i.e. the profile
  // seed folded through the kCanvas tag, then expanded to a 128-bit key.
  uint8_t base_key[16];
  SplitMix64Expand(seed, base_key);
  const uint64_t canvas_seed =
      SipHash24Tag(base_key, SurfaceTag(Surface::kCanvas));

  uint8_t canvas_key128[16];
  SplitMix64Expand(canvas_seed, canvas_key128);

  // noise_seed depends on BOTH the profile seed and the canvas contents (§3).
  const uint64_t noise_seed = SipHash24(canvas_key128, bytes, len);
  return FarblingPRNG(noise_seed);
}

}  // namespace fingerprint
