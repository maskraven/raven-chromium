# third_party/lifted — provenance ledger

Files lifted (copied, with upstream license header preserved) into Raven-Chromium.
Each row records upstream project, path, pinned commit, license, and where it enters
our patch series. **Lifted files MUST keep their original license header verbatim.**

| File | Upstream | Upstream path | Commit / version | License | Lifted in |
|---|---|---|---|---|---|
| `farbling_prng.h` | brave-core | `components/brave_shields/core/common/farbling_prng.h` | `d1ce6ee2` (v1.94.64) | MPL-2.0 | Plan 02 / `patches/core/100` |
| `siphash.h`, `siphash.cc` | SipHash reference impl (Aumasson & Bernstein, 2012) | reference C implementation | — | public domain (CC0) | Plan 02 / `patches/core/100` |

## Adaptations
- **`farbling_prng.h`** — MPL-2.0 header preserved verbatim. Only the include guard
  (`THIRD_PARTY_LIFTED_FARBLING_PRNG_H_`) and the wrapping namespace (`brave_shields`
  → `fingerprint`) were changed. The `#include "third_party/abseil-cpp/absl/random/random.h"`
  is unchanged from upstream — `random.h` transitively provides
  `absl::random_internal::randen_engine`.
- **`siphash.{h,cc}`** — public-domain reference SipHash-2-4 placed in namespace
  `fingerprint`. Verified against the canonical SipHash-2-4 test vectors
  (len 0/8/15 → 726fdb47dd0e0e31 / 93f5f5799a932462 / a129ca6149be45e5).
  This is the **only** hash permitted in fingerprint derivation; BANNED there:
  `absl::Hash`, `base::RandUint64`, `base::Time::Now`, `std::hash`.

## Build wiring
- `DEPS` allowlists `+third_party/abseil-cpp/absl/random` (the repo-global DEPS denies it).
- `BUILD.gn` target `:lifted` (public headers + `siphash.cc`) has
  `public_deps = [ "//third_party/abseil-cpp/absl/random:random" ]` (public abseil target;
  no abseil visibility edit required — mirrors Brave).
