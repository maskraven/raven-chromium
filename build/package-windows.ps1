<#
  build/package-windows.ps1 — Plan 05 T5.1/T5.3/T5.5 (Windows).
  Authenticode-signs chrome.exe + all shipped DLLs and packages a checksummed zip,
  GATED on Plan 04 validation. MUST run on a Windows host (matching the persona
  OS/GPU class) with signtool.exe (Windows SDK) and a code-signing cert
  (EV recommended for SmartScreen reputation).

  Usage:
    package-windows.ps1 -Src <chromium\src> -Out <dist> -Version <v> `
      -Thumbprint <certThumbprint> -Profile <host-matched.json> -Probe <probe.html> `
      [-TimestampUrl http://timestamp.digicert.com] [-SkipValidate]
#>
param(
  [Parameter(Mandatory=$true)][string]$Src,
  [Parameter(Mandatory=$true)][string]$Out,
  [Parameter(Mandatory=$true)][string]$Version,
  [Parameter(Mandatory=$true)][string]$Thumbprint,
  [string]$Profile, [string]$Probe,
  [string]$OutDir = "out\Default",
  [string]$TimestampUrl = "http://timestamp.digicert.com",
  [switch]$SkipValidate
)
$ErrorActionPreference = "Stop"
$build = Join-Path $Src $OutDir
$chrome = Join-Path $build "chrome.exe"
if (-not (Test-Path $chrome)) { throw "package-windows: no chrome.exe at $chrome" }
$self = Split-Path -Parent $MyInvocation.MyCommand.Path

# --- 1. Plan 04 validation gate ---
if (-not $SkipValidate -and $Profile -and $Probe) {
  Write-Host "== [1/5] validation gate =="
  # validate-persona.sh is bash; run via Git-Bash/WSL on the runner.
  & bash "$self/validate-persona.sh" --chrome $chrome --probe $Probe --profile $Profile --runs 3
  if ($LASTEXITCODE -ne 0) { throw "package-windows: VALIDATION FAILED" }
}

# --- 2. Authenticode sign exe + DLLs ---
Write-Host "== [2/5] signtool =="
$signtool = (Get-ChildItem "${env:ProgramFiles(x86)}\Windows Kits\10\bin\*\x64\signtool.exe" |
             Sort-Object FullName -Descending | Select-Object -First 1).FullName
if (-not $signtool) { throw "signtool.exe not found (install the Windows SDK)" }
$targets = Get-ChildItem -Path $build -Recurse -Include *.exe,*.dll |
           Where-Object { $_.FullName -notmatch '\\(obj|gen)\\' }
foreach ($t in $targets) {
  & $signtool sign /sha1 $Thumbprint /fd SHA256 /tr $TimestampUrl /td SHA256 /q $t.FullName
  if ($LASTEXITCODE -ne 0) { throw "signtool failed on $($t.FullName)" }
}
& $signtool verify /pa /q $chrome

# --- 3. stage runtime set (gn runtime_deps) ---
Write-Host "== [3/5] stage =="
$arch = "x64"
$name = "raven-chromium-$Version-windows-$arch"
$stage = Join-Path $Out $name
if (Test-Path $stage) { Remove-Item -Recurse -Force $stage }
New-Item -ItemType Directory -Force -Path $stage | Out-Null
$env:PATH = "$env:USERPROFILE\depot_tools;$env:PATH"
Push-Location $Src
$deps = & gn desc $OutDir //chrome:chrome runtime_deps 2>$null
Pop-Location
if (-not $deps) { $deps = @("chrome.exe","chrome.dll","chrome_elf.dll","icudtl.dat",
  "v8_context_snapshot.bin","resources.pak","chrome_100_percent.pak","chrome_200_percent.pak","locales") }
foreach ($rel in $deps) {
  if ($rel -match '^(#|obj/|gen/)') { continue }
  $rel = $rel -replace '/','\'
  $f = Join-Path $build $rel
  if (Test-Path $f) {
    $dest = Join-Path $stage $rel
    New-Item -ItemType Directory -Force -Path (Split-Path $dest) | Out-Null
    Copy-Item -Recurse -Force $f $dest
  }
}

# --- 4. zip + checksum ---
Write-Host "== [4/5] zip + sha256 =="
$zip = Join-Path $Out "$name.zip"
if (Test-Path $zip) { Remove-Item -Force $zip }
Compress-Archive -Path "$stage\*" -DestinationPath $zip
(Get-FileHash $zip -Algorithm SHA256).Hash | Out-File -Encoding ascii "$zip.sha256"

Write-Host "== [5/5] done =="
Write-Host "PACKAGED (signed): $zip"
