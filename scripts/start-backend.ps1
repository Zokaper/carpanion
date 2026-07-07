# Starts the local Carpanion backend (socket.io relay + passenger PWA) on port 3000.
# Serves the PWA at http://localhost:3000 and relays passenger <-> dashboard events.
#
# Usage:  .\scripts\start-backend.ps1
# Stop:   Ctrl+C

$ErrorActionPreference = "Stop"

# Make sure node is on PATH even in a fresh shell (winget installs to Machine PATH).
$env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" +
            [System.Environment]::GetEnvironmentVariable("Path", "User")

$backend = Join-Path $PSScriptRoot "..\backend"
Set-Location $backend

Write-Host "Starting Carpanion backend on http://localhost:3000 ..." -ForegroundColor Cyan
Write-Host "Passenger PWA:  http://localhost:3000/?session=<SESSION_CODE>" -ForegroundColor Cyan
Write-Host "(SESSION_CODE is shown on the dashboard's Collab/Queue tab)`n" -ForegroundColor DarkGray

node server.js
