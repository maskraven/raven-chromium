// SipHash-2-4 — public-domain reference implementation (see siphash.h).

#include "third_party/lifted/siphash.h"

#include <cstring>

namespace fingerprint {
namespace {

inline uint64_t RotL(uint64_t x, int b) {
  return (x << b) | (x >> (64 - b));
}

// Little-endian 64-bit load. All Chromium target architectures are
// little-endian; if a big-endian target is ever added, byte-swap here.
inline uint64_t Load64LE(const uint8_t* p) {
  uint64_t v;
  std::memcpy(&v, p, sizeof(v));
  return v;
}

#define SIPROUND()                              \
  do {                                          \
    v0 += v1;                                   \
    v1 = RotL(v1, 13);                          \
    v1 ^= v0;                                   \
    v0 = RotL(v0, 32);                          \
    v2 += v3;                                   \
    v3 = RotL(v3, 16);                          \
    v3 ^= v2;                                   \
    v0 += v3;                                   \
    v3 = RotL(v3, 21);                          \
    v3 ^= v0;                                   \
    v2 += v1;                                   \
    v1 = RotL(v1, 17);                          \
    v1 ^= v2;                                   \
    v2 = RotL(v2, 32);                          \
  } while (0)

}  // namespace

uint64_t SipHash24(const uint8_t key[16], const uint8_t* data, size_t len) {
  const uint64_t k0 = Load64LE(key);
  const uint64_t k1 = Load64LE(key + 8);

  uint64_t v0 = 0x736f6d6570736575ULL ^ k0;
  uint64_t v1 = 0x646f72616e646f6dULL ^ k1;
  uint64_t v2 = 0x6c7967656e657261ULL ^ k0;
  uint64_t v3 = 0x7465646279746573ULL ^ k1;

  const uint8_t* const end = data + (len - (len % 8));
  const int left = static_cast<int>(len & 7);
  uint64_t b = static_cast<uint64_t>(len) << 56;

  for (; data != end; data += 8) {
    const uint64_t m = Load64LE(data);
    v3 ^= m;
    SIPROUND();
    SIPROUND();
    v0 ^= m;
  }

  for (int i = 0; i < left; ++i) {
    b |= static_cast<uint64_t>(data[i]) << (8 * i);
  }

  v3 ^= b;
  SIPROUND();
  SIPROUND();
  v0 ^= b;

  v2 ^= 0xff;
  SIPROUND();
  SIPROUND();
  SIPROUND();
  SIPROUND();

  return v0 ^ v1 ^ v2 ^ v3;
}

#undef SIPROUND

uint64_t SipHash24Tag(const uint8_t key[16], const char* tag) {
  return SipHash24(key, reinterpret_cast<const uint8_t*>(tag), std::strlen(tag));
}

}  // namespace fingerprint
