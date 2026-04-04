# Build Launcher with updater signing
# Usage: .\build-launcher-signed.ps1 -KeyPassword "pw" -Bump patch
#        .\build-launcher-signed.ps1 -KeyPassword "pw" -Version "1.2.3"
#        .\build-launcher-signed.ps1 -KeyPassword "pw"   (no version change)

param(
    [Parameter(Mandatory=$true)]
    [string]$KeyPassword,

    [Parameter(Mandatory=$false)]
    [string]$KeyFile = (Join-Path (Split-Path -Parent $PSScriptRoot) "keys\tauri-updater.key"),

    [Parameter(Mandatory=$false)]
    [ValidateSet("major", "minor", "patch")]
    [string]$Bump,

    [Parameter(Mandatory=$false)]
    [string]$Version
)

$ErrorActionPreference = "Stop"

# Bump version if specified
if ($Bump) {
    & "$PSScriptRoot\bump-launcher-version.ps1" -Bump $Bump
} elseif ($Version) {
    & "$PSScriptRoot\bump-launcher-version.ps1" -Version $Version
}

# Read key file and base64-encode it into a single line (the format TAURI_SIGNING_PRIVATE_KEY expects)
$keyBytes = [System.IO.File]::ReadAllBytes($KeyFile)
$env:TAURI_SIGNING_PRIVATE_KEY = [Convert]::ToBase64String($keyBytes)
$env:TAURI_SIGNING_PRIVATE_KEY_PASSWORD = $KeyPassword

Write-Host "Signing key: $KeyFile" -ForegroundColor Cyan
Write-Host "Password: set" -ForegroundColor Cyan

# Clean Vite cache to ensure version constants are fresh
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectRoot = Split-Path -Parent $ScriptDir
$DistPath = Join-Path $ProjectRoot "launcher\dist"
if (Test-Path $DistPath) {
    Write-Host "Cleaning Vite dist/ cache..." -ForegroundColor Yellow
    Remove-Item -Path $DistPath -Recurse -Force
}

# Run the main build script with -Bundle
& "$PSScriptRoot\build-launcher.ps1" -Bundle
