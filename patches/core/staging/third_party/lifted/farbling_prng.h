// Copyright (c) 2026 The Brave Authors. All rights reserved.
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this file,
// You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Lifted into Raven-Chromium from brave-core @ d1ce6ee2 (v1.94.64), path
// components/brave_shields/core/common/farbling_prng.h. The MPL-2.0 header
// above is preserved verbatim per the provenance policy; only the include
// guard and the wrapping namespace (brave_shields -> fingerprint) were
// adapted. The include of absl/random/random.h is unchanged from upstream:
// random.h transitively provides absl::random_internal::randen_engine.
// See third_party/lifted/README.md.

#ifndef THIRD_PARTY_LIFTED_FARBLING_PRNG_H_
#define THIRD_PARTY_LIFTED_FARBLING_PRNG_H_

#include "third_party/abseil-cpp/absl/random/random.h"

namespace fingerprint {

// Seeded, deterministic PRNG (AES-based RANDEN CSPRNG exposed as a std-style
// engine). Constructed from a single uint64 seed; callers pull draws with
// operator(). This is the terminal stage of Raven's derivation chain:
//   surface_seed = SipHash24(key128, surface_tag);  FarblingPRNG prng(surface_seed);
using FarblingPRNG = absl::random_internal::randen_engine<uint64_t>;

}  // namespace fingerprint

#endif  // THIRD_PARTY_LIFTED_FARBLING_PRNG_H_
