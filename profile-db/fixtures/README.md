# profile-db/fixtures — PUBLIC contract fixtures

These three descriptors (`win11-nvidia-en-us`, `macos-arm-apple-en-us`,
`linux-intel-en-us`) are **public, illustrative** examples of the frozen v1
descriptor contract (Plan 02 §6 D1) — they exist only to exercise
`../schema/descriptor.schema.json` and `../validate.py` in CI and carry no
captured real-device data. The proprietary, curated persona DB lives in **Raven
Browser**, not this repo. v1 personas are **host-OS/GPU-matched** (no cross-OS
identities): each fixture's `platform`, `gpu`, `screen`, `languages`, `locale`,
and `timezone` co-vary as a single coherent machine, which is exactly what
`validate.py` asserts.
