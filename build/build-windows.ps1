<#
build/build-windows.ps1 — download Chromium, apply the Raven series, and build
Raven-Chromium for Windows in BOTH arches — x64 (amd64) AND arm64 — on a
Windows x64 host (the Proxmox Windows VM).

win-x64 is the native build; win-arm64 is a cross-compile (host x64 -> target arm64);
gn detects host_cpu automatically. See Chromium's docs/win_cross.md.

Run from a normal PowerShell prompt (NOT git-bash). Native Windows paths throughout,
so nothing gets MSYS path-mangled. The ~150 GB tree lives at C:\raven by default (the
VM's own native NTFS disk); override with -Work <dir> for another native NTFS volume.

  .\build\build-windows.ps1                        # dev build both arches -> C:\raven (default)
  .\build\build-windows.ps1 -Release               # release build (LTO/official; hours)
  .\build\build-windows.ps1 -Arch win-x64          # just one arch
  .\build\build-windows.ps1 -Work E:\raven-build   # <-- ONLY if you add a 2nd NTFS disk; default is C:\raven

── ONE-TIME PREREQUISITES on the Windows VM (NOT scripted) ──────────────────────────
  1. Visual Studio 2022 + "Desktop development with C++", incl. MSVC x64/x86 build tools
     AND Microsoft.VisualStudio.Component.VC.Tools.ARM64 (for the arm64 cross), plus the
     Windows 11 SDK and the Debugging Tools for Windows (OptionId.WindowsDesktopDebuggers).
  2. Git for Windows + Python 3.
  3. ~150 GB free on the VM's native NTFS disk (C: by default).

STORAGE - where the tree lives (-Work):
  The ~150 GB checkout MUST sit on a native NTFS volume — the Proxmox VM's own virtual
  disk (C:\raven by default). depot_tools/gclient/ninja rely on symlinks, case-sensitivity
  and fast small-file I/O that a network share (\\host\...) can't provide, so never point
  -Work at a mapped or UNC network path.
#>
[CmdletBinding()]
param(
  [string]$Work,
  [switch]$Release,
  [ValidateSet('both','win-x64','win-arm64')][string]$Arch = 'both'
)

$ErrorActionPreference = 'Stop'

function Log($m) { Write-Host "`n[win-build] $m" -ForegroundColor Cyan }
function Die($m) { Write-Host "`n[win-build:FAIL] $m" -ForegroundColor Red; exit 1 }
function Run($exe) {
  Write-Host "  + $exe $args" -ForegroundColor DarkGray
  # $ErrorActionPreference='Stop' turns ANY native stderr write into a terminating
  # NativeCommandError — but git/gclient/ninja all stream progress and warnings to
  # stderr, so that aborts the build on non-errors ("WARNING:root:depot_tools
  # recommends..."). Drop to Continue for the call, merge stderr into stdout so the
  # lines just print, and judge success ONLY by the exit code.
  $prev = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try { & $exe @args 2>&1 | ForEach-Object { Write-Host $_ } }
  finally { $ErrorActionPreference = $prev }
  if ($LASTEXITCODE -ne 0) { Die "command failed ($LASTEXITCODE): $exe $args" }
}

# ---- resolve the build directory ----
# Default to C:\raven — the Proxmox Windows VM's own native NTFS disk. Override with
# -Work <path> only if you keep the ~150 GB tree on another native NTFS volume. Never
# a network/UNC path (see the STORAGE note above).
$RavenRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
if (-not $Work) { $Work = 'C:\raven' }
$Work = [System.IO.Path]::GetFullPath($Work)   # normalize relative / . / .. paths
$DepotTools  = Join-Path $Work 'depot_tools'
$ChromiumDir = Join-Path $Work 'chromium'
$ChromiumSrc = Join-Path $ChromiumDir 'src'
$UgcDir      = Join-Path $Work 'ungoogled-chromium'

$env:DEPOT_TOOLS_WIN_TOOLCHAIN = '0'   # use the LOCAL Visual Studio, not the google-internal toolchain

# ---- 0. preflight ----
if (-not (Get-Command git -ErrorAction SilentlyContinue)) { Die "git not found (install Git for Windows)" }
# Chromium's tree busts MAX_PATH. Without core.longpaths git dies mid-clone/checkout with
# "Filename too long" (exit 128). Set it for this user; the machine-wide NTFS switch
# (HKLM\...\FileSystem\LongPathsEnabled=1) still has to be on — see the setup doc.
# (`git config --get` exits 1 when unset — harmless here, but keep it quiet.)
if ((& git config --global core.longpaths 2>$null) -ne 'true') {
  Log "setting git core.longpaths=true (Chromium paths exceed MAX_PATH)"
  Run git config --global core.longpaths true
}
if (-not (Get-Command python -ErrorAction SilentlyContinue) -and
    -not (Get-Command python3 -ErrorAction SilentlyContinue)) { Die "python 3 not found" }
$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
if (-not (Test-Path $vswhere)) { Log "WARN: Visual Studio / vswhere not found — build needs VS with C++ + ARM64 tools." }
$dbg = "${env:ProgramFiles(x86)}\Windows Kits\10\Debuggers\x64"
if (-not (Test-Path $dbg)) { Log "WARN: missing '$dbg' — the x64 build needs it; copy Debuggers\x64 from an x64 Windows box." }
New-Item -ItemType Directory -Force -Path $Work | Out-Null
Log "Work=$Work  Release=$Release  Arch=$Arch"

# ---- read pins ----
$pinsFile    = Join-Path $RavenRoot 'build\PINS'
# .Trim() guards against a stray CR/space leaking into a git ref (refs/tags/<tag>\r fails cryptically).
$ChromiumTag = (Select-String -Path $pinsFile -Pattern '^chromium_tag=(.+)$').Matches[0].Groups[1].Value.Trim()
$UgcTag      = (Select-String -Path $pinsFile -Pattern '^ungoogled_tag=(.+)$').Matches[0].Groups[1].Value.Trim()
if (-not $ChromiumTag -or -not $UgcTag) { Die "could not read chromium_tag/ungoogled_tag from build/PINS" }
Log "pins: chromium=$ChromiumTag ungoogled=$UgcTag"

# ---- 1. depot_tools ----
if (-not (Test-Path (Join-Path $DepotTools '.git'))) {
  Log "clone depot_tools -> $DepotTools"
  Run git clone https://chromium.googlesource.com/chromium/tools/depot_tools.git $DepotTools
}
$env:PATH = "$DepotTools;$env:PATH"   # depot_tools MUST be first on PATH

# ---- 2. download + ungoogle the tree ----
New-Item -ItemType Directory -Force -Path $ChromiumDir | Out-Null
# A .gclient with NO populated src/ means a previous `fetch` was interrupted after writing
# .gclient but before the checkout existed. Everything below assumes src/ is a real git
# checkout (it runs `git -C $ChromiumSrc fetch`), so guard on the checkout, not just on
# .gclient — otherwise a re-run hands gclient a half-made tree and it shunts src into
# _bad_scm\. `fetch` refuses to run when a .gclient already exists, so drop the stale one.
if (-not (Test-Path (Join-Path $ChromiumDir '.gclient')) -or
    -not (Test-Path (Join-Path $ChromiumSrc '.git'))) {
  if (Test-Path (Join-Path $ChromiumDir '.gclient')) {
    Log "stale .gclient without a src\ checkout — removing and re-fetching"
    Remove-Item -Force (Join-Path $ChromiumDir '.gclient')
  }
  # Leftovers from a failed gclient sync; they only confuse the next run.
  Get-ChildItem -Path $ChromiumDir -Directory -Filter '_gclient_src_*' -ErrorAction SilentlyContinue |
    ForEach-Object { Log "removing stale temp clone $($_.FullName)"; Remove-Item -Recurse -Force $_.FullName }
  Log "fetch --nohooks chromium (long, ~tens of GB)"
  Push-Location $ChromiumDir
  try { Run fetch --nohooks chromium } finally { Pop-Location }
}
# Fetch ONLY the pinned tag (never `git fetch --tags`: it enumerates all of chromium's
# tags and deadlocks against googlesource).
Run git -C $ChromiumSrc fetch origin ("+refs/tags/{0}:refs/tags/{0}" -f $ChromiumTag)
# Make re-runs idempotent: reset the superproject AND the v8 gitlink to a pristine pinned tag,
# then drop untracked patch-added files, so ungoogled + the raven series re-apply onto a clean
# tree. A superproject reset does NOT touch submodule working trees, and raven patches edit v8,
# so reset v8 explicitly. gclient deps are gitignored, so `clean -fd` keeps them. (2>&1|Out-Null
# because these emit stderr notices that would trip $ErrorActionPreference='Stop'.)
$ErrorActionPreference = 'Continue'
Run git -C $ChromiumSrc checkout -f ("refs/tags/{0}" -f $ChromiumTag)
& git -C $ChromiumSrc reset --hard ("refs/tags/{0}" -f $ChromiumTag) 2>&1 | Out-Null
& git -C $ChromiumSrc submodule update --checkout --force v8 2>&1 | Out-Null
& git -C "$ChromiumSrc\v8" reset --hard 2>&1 | Out-Null
& git -C "$ChromiumSrc\v8" clean -fd 2>&1 | Out-Null
& git -C $ChromiumSrc clean -fd 2>&1 | Out-Null
$ErrorActionPreference = 'Stop'
Log "gclient sync -> src@$ChromiumTag (deps + hooks; long)"
# Do NOT pass --with_branch_heads/--with_tags: they add all-tags refspecs and `git fetch`
# then deadlocks enumerating chromium's tags. --revision pins src to the tag. --reset reverts
# local modifications in EVERY dep (not just src/v8), so a re-run re-applies ungoogled onto a
# pristine tree — ungoogled patches touch deps like third_party/search_engines_data, which the
# superproject reset above can't reach ("Reversed (or previously applied) patch detected" otherwise).
Push-Location $ChromiumSrc
try { Run gclient sync -D --reset --revision ("src@refs/tags/{0}" -f $ChromiumTag) } finally { Pop-Location }

# ungoogled baseline (patch series onto the tree)
if (-not (Test-Path (Join-Path $UgcDir '.git'))) {
  Run git clone --depth 1 --branch $UgcTag https://github.com/ungoogled-software/ungoogled-chromium.git $UgcDir
}
$py = if (Get-Command python -ErrorAction SilentlyContinue) { 'python' } else { 'python3' }
# ungoogled's utils/patches.py needs the GNU `patch` binary, which Windows lacks. Git for
# Windows ships one at <GitRoot>\usr\bin\patch.exe; patches.py honors $env:PATCH_BIN, so
# point it there. Step 3 (the raven series) reuses the same PATCH_BIN — see the note there.
if (-not $env:PATCH_BIN) {
  $patchExe = (Get-Command patch.exe -ErrorAction SilentlyContinue).Source
  if (-not $patchExe) {
    $gitRoot = Split-Path -Parent (Split-Path -Parent (Get-Command git).Source)  # ...\Git\cmd\git.exe -> ...\Git
    foreach ($p in @((Join-Path $gitRoot 'usr\bin\patch.exe'),
                     "$env:ProgramFiles\Git\usr\bin\patch.exe",
                     "${env:ProgramFiles(x86)}\Git\usr\bin\patch.exe")) {
      if (Test-Path $p) { $patchExe = $p; break }
    }
  }
  if (-not $patchExe) { Die "GNU 'patch' not found (ungoogled patches.py needs it). It ships with Git for Windows at <GitRoot>\usr\bin\patch.exe — install it or set `$env:PATCH_BIN." }
  $env:PATCH_BIN = $patchExe
}
Log "apply ungoogled series (PATCH_BIN=$env:PATCH_BIN)"
Run $py (Join-Path $UgcDir 'utils\patches.py') apply $ChromiumSrc (Join-Path $UgcDir 'patches')

# ---- 3. apply the Raven fingerprint series ----
# Apply with GNU patch (PATCH_BIN), NOT `git apply`. This box has core.autocrlf=true, so gclient
# deps (e.g. third_party/abseil-cpp/absl.gni) check out CRLF while the raven .patch files are LF.
# `git apply` then fails ("patch does not apply") because the trailing CRs make every context line
# differ; --whitespace=nowarn only silences warnings, it can't reconcile the endings. GNU patch
# auto-strips CRs from the patch and matches leniently against a CRLF tree (the same reason
# ungoogled's patches.py works on this box), and it edits files inside the v8 submodule with no
# gitlink/--3way dance. All 41 raven patches are plain content/new-file diffs (no renames/binaries),
# which GNU patch applies cleanly. PowerShell would turn patch's stderr into a terminating
# NativeCommandError under 'Stop', so run with 'Continue', capture 2>&1, and gate on $LASTEXITCODE.
Log "apply Raven series (patches/series) via GNU patch ($env:PATCH_BIN)"
# Trim first (kills stray CR/whitespace), THEN drop blank + comment lines — mirrors the bash
# reader's `grep -vE '^[[:space:]]*(#|$)'` so a whitespace-only line can't become a bogus patch path.
$series = Get-Content (Join-Path $RavenRoot 'patches\series') |
          ForEach-Object { $_.Trim() } | Where-Object { $_ -and $_ -notmatch '^#' }
$eapSaved = $ErrorActionPreference
Push-Location $ChromiumSrc
try {
  foreach ($name in $series) {
    $patch = Join-Path $RavenRoot ('patches\' + ($name -replace '/','\'))
    if (-not (Test-Path $patch)) { Die "patch not found: $patch" }
    Write-Host "  [apply] $name"
    $ErrorActionPreference = 'Continue'
    # -p1 strips a/ b/; --forward refuses reverse/already-applied hunks (a clean reset never has any,
    # so this only fires if a prior reset silently failed); --no-backup-if-mismatch keeps the tree tidy.
    $out = & $env:PATCH_BIN -p1 --forward --no-backup-if-mismatch -i $patch 2>&1
    $rc = $LASTEXITCODE
    $ErrorActionPreference = $eapSaved
    if ($rc -ne 0) { $out | Write-Host; Die "failed to apply $name (patch rc=$rc)" }
  }
} finally { Pop-Location; $ErrorActionPreference = $eapSaved }

# ---- 4. build the requested arch(es) ----
function Build-Arch($plat, $out) {
  $gnArgs = (Get-Content (Join-Path $RavenRoot 'build\args\common.gni') -Raw) + "`n" +
            (Get-Content (Join-Path $RavenRoot ('build\args\{0}.gn' -f $plat)) -Raw)
  if ($Release) { $gnArgs += "`n" + (Get-Content (Join-Path $RavenRoot 'build\args\release.gni') -Raw) }
  $outDir = Join-Path $ChromiumSrc $out
  New-Item -ItemType Directory -Force -Path $outDir | Out-Null
  [System.IO.File]::WriteAllText((Join-Path $outDir 'args.gn'), $gnArgs)   # UTF-8, no BOM (gn-friendly)
  Log "gn gen $out  (plat=$plat release=$Release)"
  Push-Location $ChromiumSrc
  try {
    Run gn gen $out
    Log "autoninja -C $out chrome"
    Run autoninja -C $out chrome
  } finally { Pop-Location }
}

$targets = switch ($Arch) {
  'both'      { ,@('win-x64','out\win-x64') + ,@('win-arm64','out\win-arm64') }  # x64 native first, then arm64 cross
  'win-arm64' { ,@('win-arm64','out\win-arm64') }
  'win-x64'   { ,@('win-x64','out\win-x64') }
}
foreach ($t in $targets) { Build-Arch $t[0] $t[1] }

Log "DONE — built:"
foreach ($t in $targets) { Write-Host ("  {0} : {1}\{2}\chrome.exe" -f $t[0], $ChromiumSrc, $t[1]) }
