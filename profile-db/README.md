# profile-db/ — descriptor schema, validator, and PUBLIC fixtures

The **real-device DB stays proprietary in Raven Browser** (README §4, spec §11.2). This repo ships
only:

- `schema/descriptor.schema.json` — the JSON descriptor schema (defined in Plan 02).
- `validate.py` — schema + cross-axis **coherence** checks, run in CI (grows through Plan 02/04).
- `fixtures/` — a few PUBLIC sample profiles for tests only (no captured real-device data).

Run the validator under the repo venv (per user prefs): `source .venv/bin/activate && python profile-db/validate.py`.
