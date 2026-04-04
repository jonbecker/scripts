# Build the shared simulation DLL for UE5 client integration
# This builds the Rust shared_simulation crate as a cdylib and copies
# the DLL + generated C header to the UE5 project.

param(
    [switch]$Release,
    [switch]$SkipCopy
)

$ErrorActionPreference = "Stop"
$ProjectRoot = Split-Path -Parent $PSScriptRoot

Write-Host "Building shared_simulation..." -ForegroundColor Cyan

# Build the crate
$BuildArgs = @("build", "-p", "shared_simulation")
if ($Release) {
    $BuildArgs += "--release"
    $Profile = "release"
} else {
    $Profile = "debug"
}

Push-Location $ProjectRoot
try {
    cargo @BuildArgs
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Build failed!" -ForegroundColor Red
        exit 1
    }

    Write-Host "Build succeeded." -ForegroundColor Green

    if (-not $SkipCopy) {
        $DllSource = Join-Path (Join-Path (Join-Path $ProjectRoot "target") $Profile) "shared_simulation.dll"
        $HeaderSource = Join-Path (Join-Path (Join-Path $ProjectRoot "shared_simulation") "include") "shared_simulation.h"
        $DllDest = Join-Path (Join-Path (Join-Path $ProjectRoot "ue5_client") "RTSGame") "Binaries\Win64"
        $HeaderDest = Join-Path (Join-Path (Join-Path (Join-Path $ProjectRoot "ue5_client") "RTSGame") "Source") "RTSGame\GameLogic"

        # Create destination directories if needed
        New-Item -ItemType Directory -Path $DllDest -Force | Out-Null
        New-Item -ItemType Directory -Path $HeaderDest -Force | Out-Null

        # Copy DLL
        if (Test-Path $DllSource) {
            Copy-Item $DllSource $DllDest -Force
            Write-Host "Copied DLL to $DllDest" -ForegroundColor Green
        } else {
            Write-Host "Warning: DLL not found at $DllSource" -ForegroundColor Yellow
        }

        # Copy header
        if (Test-Path $HeaderSource) {
            Copy-Item $HeaderSource $HeaderDest -Force
            Write-Host "Copied header to $HeaderDest" -ForegroundColor Green
        } else {
            Write-Host "Warning: Header not found at $HeaderSource (cbindgen may not have generated it)" -ForegroundColor Yellow
        }
    }
} finally {
    Pop-Location
}

Write-Host "Done." -ForegroundColor Cyan
