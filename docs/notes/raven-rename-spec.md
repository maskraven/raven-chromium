# Rename spec — Mynah-Chromium → Raven-Chromium

Status: refactor spec (2026-07-15). This document is the **single source of truth** for
renaming the project from **Mynah** to **Raven**. Every automated edit run must read this
file first and apply exactly these rules. Scope: repository content only (this is the Mac
content mirror; the physical `chromium/src` tree is not in this repo).

> **UPDATE 2026-07-15 (host renamed too):** The physical build server's SSH alias **and**
> key were subsequently renamed `mynah` → `raven` (`Host raven`, `IdentityFile
> ~/.ssh/raven_ed25519`; `HostName 192.168.100.200` unchanged; the machine's OS-level
> hostname is still literally `Mynah`). This **supersedes the "keep `mynah`" guidance in §B
> and §C item 4** — all host references in the repo are now `raven`, and repo residual
> `mynah` is zero (outside this spec). The remote host was refactored to match: git branches
> `mynah-base`/`mynah-patched` → `raven-base`/`raven-patched` and the mirror dir `~/mynah` →
> `~/raven`.

## Guiding principle

Rename **logical project identity** (branding, product names, logical env-var/script/
artifact/branch/file names, test-harness constants, project URLs). **Do not** rename
**physical machine identity** (the build server is literally named `mynah`) or the exact
absolute path of the live checkout that tooling is currently running against.

The fork's **compiled identity is unaffected**: no C++ namespace, type, function, macro,
header guard, include path, or command-line switch contains `mynah` (they are
`fingerprint` / `ungoogled` / `blink` / `webgl_persona` and `--fingerprint-*`). Therefore
**no `.patch` may change any compiled identifier**, and no rebuild/revalidation of the fork
is implied by this rename.

## A. Canonical renames — ALWAYS apply

| Old | New | Where |
|-----|-----|-------|
| `Mynah-Chromium` | `Raven-Chromium` | prose / branding (project full name) |
| `Mynah Chromium` | `Raven Chromium` | product name, DMG volume label |
| `Mynah Browser` | `Raven Browser` | host-application product prose |
| `Mynah` (standalone brand word) | `Raven` | prose |
| `The Mynah Authors` | `The Raven Authors` | copyright lines |
| `MYNAH patch series`, `Mynah series` | `RAVEN patch series`, `Raven series` | comments, CI step name "Apply Mynah series" → "Apply Raven series" |
| `MYNAH_ROOT` | `RAVEN_ROOT` | shell var (`sync.sh`, `apply-patches.sh`, `gen-and-build.sh`) |
| `MYNAH_CHROME` | `RAVEN_CHROME` | shell var (`raven-launch.sh`) |
| `MYNAH_FORK_BIN`, `MYNAH_FORK_ROOT`, `MYNAH_FORK_REMOTE`, `MYNAH_E2E`, `MYNAH_HEADLESS`, `MYNAH_R1_LIVE`, and any other `MYNAH_*` env var | `RAVEN_*` (same suffix) | docs/contract integration-testing |
| `__MYNAH_FP__` | `__RAVEN_FP__` | probe automation global (JS) + all refs (compare.py, READMEs, docs) |
| `mynah-launch.sh` (filename) + `mynah-launch:` log prefix | `raven-launch.sh` + `raven-launch:` | rename the file; update all references |
| `mynah-integration-testing.md` (filename) | `raven-integration-testing.md` | rename the file; update all links to it |
| `mynah-base` (git branch) | `raven-base` | CI YAML + docs — see §C required host action |
| `mynah-patched` (git branch) | `raven-patched` | docs — see §C required host action |
| `mynah-chromium-<ver>-<plat>` (artifact basename) | `raven-chromium-<ver>-<plat>` | package-{linux,macos}.sh, package-windows.ps1 |
| `MYNAH-RELEASE.txt` | `RAVEN-RELEASE.txt` | staged release-notes file |
| `/tmp/mynah-validate` | `/tmp/raven-validate` | validate-persona.sh default OUT |
| `/opt/mynah-chromium` | `/opt/raven-chromium` | install-path convention (docs) |
| forbidden-leak terms `"mynah"` / `"Mynah"` | `"raven"` / `"Raven"` | validate-persona.sh branding scrub (the guard that asserts the project name never leaks into JS-visible fields) |
| `"mynah-fingerprint-probe"` | `"raven-fingerprint-probe"` | probe `schema.probe` value + its comment |
| `Mynah ❤ fingerprint 0123` | `Raven ❤ fingerprint 0123` | probe canvas `fillText` string |
| `https://mynah.browser/...` | `https://raven.browser/...` | descriptor.schema.json `$id`, title/description |
| host-mirror dirs `~/mynah`, `~/Mynah`, `mynah:~/Mynah/`, `~/Projects/Mynah` | `~/raven`, `mynah:~/raven/`, `~/Projects/Raven` | docs — the **host alias `mynah:` prefix stays**, only the project dir path changes — see §C |
| `../Mynah` (relative parent-dir ref) | `../Raven` | README (forward-looking; see §C optional) |
| default path `.../Mynah-Chromium/...` | `.../Raven-Chromium/...` | gen_webgl_table.py default (overridable convenience) |

## B. KEEP AS-IS — do NOT rename

These name a **physical machine** or the **live checkout path**, not the project:

- SSH host alias **`mynah`**, `ssh mynah`, the `mynah:` command prefix (the host part), the
  SSH key `mynah_ed25519`, `HostName`/`User` SSH-config lines, and the IP `192.168.100.200`.
- Prose that refers to the **build server / VPS / host** named `mynah` (e.g. "the `mynah`
  host has no GPU", "run on `mynah`"). It is a real machine; leave the machine name.
- Non-project paths on the host: `~/chromium/src`, `out/Default`, `~/chrome-libffmpeg*`, etc.
- The live Mac checkout absolute path `/Users/antonio/Projects/Mynah-Chromium` — do **not**
  edit any string equal to this exact absolute path (tooling runs against it). (Renaming the
  physical Mac directory is an optional §C follow-up, out of scope for automated edits.)
- Any C++ namespace/type/function/macro/switch (none contain `mynah` regardless).

Heuristic when ambiguous: **lowercase bare `mynah` / `mynah:` = the machine (keep)**;
**everything that is the project's name = Raven (rename)**. Git branch names and the
host-mirror *directory* are project artifacts and DO get renamed (with the §C host action),
even though they live on the `mynah` machine.

## C. Out-of-repo actions this rename REQUIRES (checklist, not automated here)

1. **Git branches** on every build/runner checkout of `chromium/src`:
   `git branch -m mynah-base raven-base` and `git branch -m mynah-patched raven-patched`.
   (CI now checks out `raven-base`; without this the workflow fails.)
2. **Host project-mirror dir**: `mv ~/mynah ~/raven` (a.k.a. `~/Mynah`) on the build host,
   so `mynah:~/raven/` paths in the docs resolve.
3. **Local Mac project dir**: `mv ~/Projects/Mynah-Chromium ~/Projects/Raven-Chromium` —
   **DONE 2026-07-15** (folder renamed; `gen_webgl_table.py`'s default path already resolves to `.../Raven-Chromium/...`).
4. **SSH host alias (optional)**: renaming the machine/alias `mynah` itself is independent
   infrastructure; not required for the rename and intentionally left as-is.
5. **GitHub Actions vars/secrets**: `CHROMIUM_SRC`, `CHROMIUM_SRC_MAC`, `CHROMIUM_SRC_WIN`,
   `GPG_KEY_ID`, `MACOS_IDENTITY`, `MACOS_TEAM_ID`, `NOTARY_PROFILE`, `WIN_CERT_THUMBPRINT`
   — none contain `mynah`; **no change**.
6. **External automation / env vars — NO control-plane change (confirmed 2026-07-15).** The
   MaskRaven control-plane (`maskraven/maskraven`) owns its `MASKRAVEN_*` env vars (own protected
   namespace, already migrated from `MYNAH_*`), and its conformance suite detects the fork via
   `ProbeBrandingJS` (userAgentData brands / chrome shape / navigator.webdriver), **not** a JS
   sentinel — so `window.__RAVEN_FP__` is fork-side probe tooling only (`test/probe/*`). This
   doc's example commands were corrected `RAVEN_*` → `MASKRAVEN_*` to match the real consumer;
   `RAVEN_CHROME` (fork launcher) stays. Fork↔control-plane coupling is only the launch/descriptor
   contract (engine wire `raven-chromium`, manifest base `github.com/maskraven/raven-chromium`,
   descriptor schema) — all renamed and green.

## D. Patch-file safety rules (patches/*.patch)

All 81 `mynah` hits in `patches/` are comments / commit-message prose / copyright — **zero**
compiled identifiers. When editing a `.patch`:

- Only substitute the word `Mynah`→`Raven` / `MYNAH`→`RAVEN` inside **added lines
  (`+`-prefixed)** and **patch-description/header prose** (before `diff --git`).
- **Never** add or remove lines; **never** edit context lines (space-prefixed) or removed
  lines (`-`-prefixed); **never** touch `@@ ... @@` hunk headers or `diff --git`/`index`/
  `+++`/`---` path lines. Word-for-word in-line substitution only ⇒ hunk line counts stay
  valid ⇒ the patch still applies.
- Preserve `❤`/UTF-8 and exact surrounding whitespace.

## E. Verification (run after edits)

- No `mynah` remains except the §B keep-list (host alias `mynah`/`mynah:`/`mynah_ed25519`/
  IP, the exact Mac abs path, non-project host paths).
- Every `.patch` hunk header's `+`/`-`/context line counts still match its body.
- `python3 profile-db/validate.py --all profile-db/fixtures/` still passes.
- No new `mynah` introduced; `raven` naming is internally consistent (same suffix on env vars).
