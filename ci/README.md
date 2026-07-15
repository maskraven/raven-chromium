# ci/ — compile + regression jobs (Plan 00 T0.6, grown in Plan 04/05)

Bring-up target: one `build-linux` job (`sync.sh --mode tarball` → `apply-patches.sh` →
`gen-and-build.sh linux-x64`) that stays the compile gate for every later patch. Per-OS release
jobs and the regression/coherence jobs are added in Plans 04–05. Matching-OS runners are required
to validate macOS/Windows personas (README §5).
