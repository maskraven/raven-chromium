// SipHash-2-4 keyed PRF — public-domain reference implementation.
//
// Reference: Jean-Philippe Aumasson and Daniel J. Bernstein, "SipHash: a fast
// short-input PRF" (2012). The reference C implementation was released to the
// public domain (CC0). Adapted into Raven-Chromium under namespace
// `fingerprint`; see third_party/lifted/README.md.
//
// Raven uses SipHash-2-4 as the keyed derivation step feeding
// fingerprint::FarblingPRNG:
//   surface_seed = SipHash24(key128, surface_tag)
// This is the ONLY hash permitted in fingerprint derivation. BANNED in the
// derivation path: absl::Hash, base::RandUint64, base::Time::Now, std::hash.

#ifndef THIRD_PARTY_LIFTED_SIPHASH_H_
#define THIRD_PARTY_LIFTED_SIPHASH_H_

#include <cstddef>
#include <cstdint>

namespace fingerprint {

// Computes SipHash-2-4 of [data, data+len) under the 128-bit |key| (16 bytes,
// interpreted little-endian as k0 || k1). Deterministic across platforms.
uint64_t SipHash24(const uint8_t key[16], const uint8_t* data, size_t len);

// Convenience overload: hash a NUL-terminated ASCII surface tag.
uint64_t SipHash24Tag(const uint8_t key[16], const char* tag);

}  // namespace fingerprint

#endif  // THIRD_PARTY_LIFTED_SIPHASH_H_
