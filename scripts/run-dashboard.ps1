# Runs the Carpanion dashboard on the Android emulator, pointed at the LOCAL backend.
#
# The emulator reaches the host laptop's localhost via the special IP 10.0.2.2,
# so the dashboard connects to http://10.0.2.2:3000 (where start-backend.ps1 listens).
#
# Usage:  .\scripts\run-dashboard.ps1            # launches the dev_phone emulator if needed
#         .\scripts\run-dashboard.ps1 -Emulator "Pixel_7"
#
# Prereqs: backend already running (see start-backend.ps1), puro installed.

param(
    # S25plus AVD matches the real phone exactly: 1080x2340 @ 450dpi
    # (landscape 2340x1080, ~832x384 dp) so layout checks reflect the actual device.
    [string]$Emulator = "S25plus",
    [string]$BackendUrl = "http://10.0.2.2:3000"
)

$ErrorActionPreference = "Stop"

$repo = Join-Path $PSScriptRoot ".."
Set-Location $repo

# Is an emulator/device already connected?
$devices = puro flutter devices 2>&1 | Out-String
if ($devices -notmatch "emulator-") {
    Write-Host "Launching emulator '$Emulator' ..." -ForegroundColor Cyan
    puro flutter emulators --launch $Emulator
    Write-Host "Waiting for the emulator to finish booting ..." -ForegroundColor DarkGray
    Start-Sleep -Seconds 25
} else {
    Write-Host "Emulator already running." -ForegroundColor Green
}

Write-Host "Running dashboard with BACKEND_URL=$BackendUrl ..." -ForegroundColor Cyan
# Collab has no sign-in gate — its mechanics are anonymous. Google sign-in is
# optional (Settings -> Media & Collab) and only powers the "demo" YouTube search.
puro flutter run --dart-define=BACKEND_URL=$BackendUrl
