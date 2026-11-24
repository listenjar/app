# Builds the release Windows app with WinSparkle's update key and packages
# it as build\release\ListenJar-X.Y.Z-windows-x64-setup.exe
# with Inno Setup 6 (tool/windows-installer.iss): the download and the update
# both. LISTENJAR_UPDATE_PUBLIC_KEY is the Ed25519 public key updates are
# signed with; packages/youtubei's MinGW GCC must be installed (its README).
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Set-Location (Split-Path $PSScriptRoot -Parent)

if (-not $env:LISTENJAR_UPDATE_PUBLIC_KEY) { throw 'Set LISTENJAR_UPDATE_PUBLIC_KEY, the Ed25519 public key updates are signed with.' }
$release = node tool/release.ts identity | ConvertFrom-Json
if ($LASTEXITCODE -ne 0) { throw 'pubspec.yaml has no release version.' }

Push-Location packages/desktop
flutter build windows --release
if ($LASTEXITCODE -ne 0) { throw 'flutter build windows failed.' }
Pop-Location

$payload = (Resolve-Path packages/desktop/build/windows/x64/runner/Release).Path
foreach ($file in 'listenjar.exe', 'WinSparkle.dll') {
    if (-not (Test-Path (Join-Path $payload $file))) { throw "The build has no $file." }
}
$compiler = Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6/ISCC.exe'
if (-not (Test-Path $compiler)) { throw 'Install Inno Setup 6.' }
& $compiler /Q "/DAppVersion=$($release.version)" "/DPayload=$payload" tool/windows-installer.iss
if ($LASTEXITCODE -ne 0) { throw 'Inno Setup failed.' }
Write-Output "build/release/ListenJar-$($release.version)-windows-x64-setup.exe"
