# build/ — how Raven-Chromium is synced, patched, and built

All scripts are driven by the pin in [`PINS`](PINS): `chromium_tag=150.0.7871.114`,
`ungoogled_tag=150.0.7871.114-1`. Do not bump the pin without a full Plan 01 rebase + Plan 04
revalidation.

## Pipeline

```
build/sync.sh --mode gclient|tarball   # fetch Chromium @ pin, apply ungoogled series
build/apply-patches.sh                 # apply patches/series (our core/ + fingerprint/) — empty in Plan 00
build/gen-and-build.sh [platform]      # gn gen (common.gni + <platform>.gn) → autoninja chrome
```

- **`sync.sh`** — two acquisition paths (T0.2). `--mode gclient` (Path A) = full-history checkout
  for dev iteration; `--mode tarball` (Path B) = official source tarball for reproducible CI.
  Both then apply the ungoogled patch series (giving `components/ungoogled/ungoogled_switches`,
  which our patch `000` extends). Per-mode defaults: gclient skips prune/domain-sub, tarball runs
  both. Paths configurable via env (`CHROMIUM_SRC`, `WORK`, …).
- **`apply-patches.sh`** — reads `patches/series`, `git apply --3way` each patch, stops on first
  reject. `REVERSE=1` un-applies (for rebase resets).
- **`gen-and-build.sh`** — **concatenates** `args/common.gni` + `args/<platform>.gn` into the gn
  args (it does *not* use gn `import()`, because our args live outside the chromium src tree).

## gn args (`args/`)

`common.gni` = ungoogled `flags.gn` (verbatim, @ ungoogled_tag) + Raven dev toggles (non-official,
release-like, DCHECKs on, no RBE). Per-platform files add only `target_os`/`target_cpu`.

## Build executor decision (T0.1)

Default **`siso` local** (dispatched by `autoninja`), `use_remoteexec=false`. Wire reclient/RBE or
a distributed cache only if iteration time hurts (spec §7.6). Keep a warm `out/` + siso cache;
cold builds are the tax, incremental Blink edits are cheap.

## Hosts (README §5 constraint)

A build can only ship personas whose **OS + GPU class match the build/validation host**.
- **Linux x64** — the `raven` VPS (24 vCPU): baseline + Linux target + CI/reference.
- **macOS arm64** — this dev Mac (needs Xcode 26.5 / 17F42, SDK 26.5 per PINS): macOS personas.
- **Windows x64** — a matching Windows host, added in Plan 05.
