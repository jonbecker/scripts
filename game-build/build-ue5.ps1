# Build UE5 Client Script
# This script builds the UE5 RTS Game client for Windows

param(
    [Parameter(Mandatory=$false)]
    [ValidateSet("Development", "Shipping", "Debug")]
    [string]$Configuration = "Shipping",

    [Parameter(Mandatory=$false)]
    [ValidateSet("Win64", "Win32")]
    [string]$Platform = "Win64",

    [Parameter(Mandatory=$false)]
    [string]$UE5Path = "C:\Program Files\Epic Games\UE_5.6",

    [Parameter(Mandatory=$false)]
    [string]$OutputPath = "",

    [Parameter(Mandatory=$false)]
    [switch]$Clean,

    [Parameter(Mandatory=$false)]
    [switch]$Cook,

    [Parameter(Mandatory=$false)]
    [switch]$Package
)

# Set error action preference
$ErrorActionPreference = "Stop"

# Define paths
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectRoot = Split-Path -Parent $ScriptDir
$UE5ClientPath = Join-Path $ProjectRoot "ue5_client\RTSGame"
$ProjectFile = Join-Path $UE5ClientPath "RTSGame.uproject"

if ([string]::IsNullOrEmpty($OutputPath)) {
    $OutputPath = Join-Path $ProjectRoot "build\ue5_output"
}

# Verify UE5 installation
if (-not (Test-Path "$UE5Path\Engine\Build\BatchFiles\Build.bat")) {
    Write-Error "Unreal Engine 5 not found at $UE5Path"
    exit 1
}

Write-Host "========================================" -ForegroundColor Cyan
Write-Host " UE5 Client Build Script" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Configuration: $Configuration" -ForegroundColor Yellow
Write-Host "Platform:      $Platform" -ForegroundColor Yellow
Write-Host "UE5 Path:      $UE5Path" -ForegroundColor Yellow
Write-Host "Project:       $ProjectFile" -ForegroundColor Yellow
Write-Host "Output:        $OutputPath" -ForegroundColor Yellow
Write-Host ""

# Clean previous build if requested
if ($Clean) {
    Write-Host "Cleaning previous build..." -ForegroundColor Yellow

    $DirsToClean = @(
        "$UE5ClientPath\Binaries",
        "$UE5ClientPath\Intermediate",
        "$UE5ClientPath\Saved\Cooked",
        "$OutputPath"
    )

    foreach ($Dir in $DirsToClean) {
        if (Test-Path $Dir) {
            Write-Host "  Removing: $Dir"
            Remove-Item -Path $Dir -Recurse -Force
        }
    }

    Write-Host "Clean complete." -ForegroundColor Green
    Write-Host ""
}

# Step 1: Generate project files
Write-Host "Step 1: Generating project files..." -ForegroundColor Cyan

$GenerateScript = Join-Path $UE5Path "Engine\Build\BatchFiles\GenerateProjectFiles.bat"
$GenerateArgs = @(
    "`"$ProjectFile`"",
    "-Game",
    "-Engine"
)

Write-Host "Running: $GenerateScript $($GenerateArgs -join ' ')"
& $GenerateScript $GenerateArgs

if ($LASTEXITCODE -ne 0) {
    Write-Error "Failed to generate project files (Exit code: $LASTEXITCODE)"
    exit $LASTEXITCODE
}

Write-Host "Project files generated successfully." -ForegroundColor Green
Write-Host ""

# Step 2: Build the game
Write-Host "Step 2: Building RTSGame..." -ForegroundColor Cyan

$BuildScript = Join-Path $UE5Path "Engine\Build\BatchFiles\Build.bat"
$BuildArgs = @(
    "RTSGame",
    $Platform,
    $Configuration,
    "-Project=`"$ProjectFile`"",
    "-WaitMutex",
    "-NoHotReload"
)

Write-Host "Running: $BuildScript $($BuildArgs -join ' ')"
& $BuildScript $BuildArgs

if ($LASTEXITCODE -ne 0) {
    Write-Error "Build failed (Exit code: $LASTEXITCODE)"
    exit $LASTEXITCODE
}

Write-Host "Build completed successfully." -ForegroundColor Green
Write-Host ""

# Step 3: Cook content (optional)
if ($Cook -or $Package) {
    Write-Host "Step 3: Cooking content..." -ForegroundColor Cyan

    $CookArgs = @(
        "BuildCookRun",
        "-project=`"$ProjectFile`"",
        "-platform=$Platform",
        "-clientconfig=$Configuration",
        "-cook"
    )

    # Add staging if packaging
    if ($Package) {
        $CookArgs += "-stage"
        $CookArgs += "-package"
        $CookArgs += "-pak"
        $CookArgs += "-compressed"
        $CookArgs += "-stagingdirectory=`"$OutputPath`""
        $CookArgs += "-prereqs"
        $CookArgs += "-distribution"
    }

    $CookArgs += "-build"

    $UATScript = Join-Path $UE5Path "Engine\Build\BatchFiles\RunUAT.bat"

    Write-Host "Running: $UATScript $($CookArgs -join ' ')"
    & $UATScript $CookArgs

    if ($LASTEXITCODE -ne 0) {
        Write-Error "Cook/Package failed (Exit code: $LASTEXITCODE)"
        exit $LASTEXITCODE
    }

    Write-Host "Cook/Package completed successfully." -ForegroundColor Green
}

# Step 4: Copy additional files
if ($Package) {
    Write-Host ""
    Write-Host "Step 4: Copying additional files..." -ForegroundColor Cyan

    # Copy certificates
    $CertsSource = Join-Path $ProjectRoot "certs\dev"
    $CertsTarget = Join-Path $OutputPath "Windows\certs"

    if (Test-Path $CertsSource) {
        Write-Host "Copying certificates..."
        New-Item -ItemType Directory -Path $CertsTarget -Force | Out-Null
        Copy-Item -Path "$CertsSource\*" -Destination $CertsTarget -Recurse
    }

    # Copy configuration files
    $ConfigSource = Join-Path $ProjectRoot "config"
    $ConfigTarget = Join-Path $OutputPath "Windows\config"

    if (Test-Path $ConfigSource) {
        Write-Host "Copying configuration files..."
        New-Item -ItemType Directory -Path $ConfigTarget -Force | Out-Null
        Copy-Item -Path "$ConfigSource\*.ron" -Destination $ConfigTarget
    }

    # Copy UE5 project runtime config files (rendering_style.json, etc.)
    # UE5 staging only includes .ini files; custom JSON configs need manual copy
    $UE5ConfigSource = Join-Path $UE5ClientPath "Config"
    $UE5ConfigTarget = Join-Path $OutputPath "Windows\RTSGame\Config"

    if (Test-Path $UE5ConfigSource) {
        Write-Host "Copying UE5 project config files..."
        New-Item -ItemType Directory -Path $UE5ConfigTarget -Force | Out-Null
        Copy-Item -Path "$UE5ConfigSource\*.json" -Destination $UE5ConfigTarget -Force -ErrorAction SilentlyContinue
        Write-Host "UE5 project config files copied." -ForegroundColor Green
    }

    # Copy shared_simulation.dll into packaged binaries
    $SharedSimDll = Join-Path $UE5ClientPath "Binaries\Win64\shared_simulation.dll"
    $SharedSimDest = Join-Path $OutputPath "Windows\RTSGame\Binaries\Win64"

    if (Test-Path $SharedSimDll) {
        Copy-Item $SharedSimDll $SharedSimDest -Force
        Write-Host "Copied shared_simulation.dll to package" -ForegroundColor Green
    }

    Write-Host "Additional files copied." -ForegroundColor Green
}

# Summary
Write-Host ""
Write-Host "========================================" -ForegroundColor Green
Write-Host " Build Complete!" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green

if ($Package) {
    $ExePath = Join-Path $OutputPath "Windows\RTSGame.exe"
    if (Test-Path $ExePath) {
        $FileInfo = Get-Item $ExePath
        Write-Host ""
        Write-Host "Executable: $ExePath"
        Write-Host "Size:       $([math]::Round($FileInfo.Length / 1MB, 2)) MB"
        Write-Host ""
        Write-Host "You can now run the game with:" -ForegroundColor Yellow
        Write-Host "  & `"$ExePath`" -game -windowed"
    }

    # Calculate total package size
    $TotalSize = (Get-ChildItem $OutputPath -Recurse | Measure-Object -Property Length -Sum).Sum
    Write-Host ""
    Write-Host "Total package size: $([math]::Round($TotalSize / 1MB, 2)) MB"
}

Write-Host ""
Write-Host "Build log saved to: $UE5ClientPath\Saved\Logs" -ForegroundColor Gray

exit 0