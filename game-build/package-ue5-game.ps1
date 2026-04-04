# Package UE5 Game for Distribution
# This creates a fully self-contained game package that doesn't need the .uproject file

param(
    [string]$UE5Path = ($env:UE5_PATH ?? "D:\UE_5.7"),
    [string]$ProjectPath = (Join-Path (Split-Path -Parent $PSScriptRoot) "ue5_client\RTSGame"),
    [string]$OutputPath = (Join-Path (Split-Path -Parent $PSScriptRoot) "build\RTSGame_Package"),
    [string]$BuildConfig = "Shipping"  # "Shipping" for distribution, "Development" for local testing
)

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "UE5 Game Packaging Script" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

# Validate paths
if (-not (Test-Path $UE5Path)) {
    Write-Host "ERROR: UE5 installation not found at: $UE5Path" -ForegroundColor Red
    exit 1
}

if (-not (Test-Path "$ProjectPath\RTSGame.uproject")) {
    Write-Host "ERROR: Project file not found at: $ProjectPath\RTSGame.uproject" -ForegroundColor Red
    exit 1
}

$RunUATBat = "$UE5Path\Engine\Build\BatchFiles\RunUAT.bat"
if (-not (Test-Path $RunUATBat)) {
    Write-Host "ERROR: RunUAT.bat not found at: $RunUATBat" -ForegroundColor Red
    exit 1
}

Write-Host "UE5 Path: $UE5Path" -ForegroundColor Green
Write-Host "Project Path: $ProjectPath" -ForegroundColor Green
Write-Host "Output Path: $OutputPath" -ForegroundColor Green
Write-Host "Build Configuration: $BuildConfig" -ForegroundColor Green
Write-Host ""

# Clean previous build output to avoid stale loose files mixing with pak files
if (Test-Path $OutputPath) {
    Write-Host "Cleaning previous build output..." -ForegroundColor Yellow
    Remove-Item -Path $OutputPath -Recurse -Force
}
New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null

# Build shared simulation DLL so the package includes the latest game instance logic
Write-Host "Building shared simulation DLL..." -ForegroundColor Cyan
& "$PSScriptRoot\build-shared-simulation.ps1"
if ($LASTEXITCODE -ne 0) {
    Write-Host "ERROR: shared_simulation build failed!" -ForegroundColor Red
    exit 1
}
Write-Host ""

Write-Host "Starting UE5 packaging process..." -ForegroundColor Cyan
Write-Host "This may take 10-30 minutes depending on your hardware..." -ForegroundColor Yellow
Write-Host ""

# Run UAT BuildCookRun command — pipe stdout+stderr to a log so we can inspect cook errors
$CookLog = "$ProjectPath\Saved\Logs\CookRun.log"
& $RunUATBat BuildCookRun `
    -project="$ProjectPath\RTSGame.uproject" `
    -platform=Win64 `
    -clientconfig="$BuildConfig" `
    -serverconfig="$BuildConfig" `
    -clean `
    -cook `
    -stage `
    -pak `
    -package `
    -build `
    -archive `
    -archivedirectory="$OutputPath" `
    -noP4 `
    -utf8output `
    -verbose 2>&1 | Tee-Object -FilePath $CookLog
Write-Host "Cook log saved to: $CookLog" -ForegroundColor Cyan

if ($LASTEXITCODE -eq 0) {
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Green
    Write-Host "Packaging completed successfully!" -ForegroundColor Green
    Write-Host "========================================" -ForegroundColor Green
    Write-Host ""
    Write-Host "Packaged game location: $OutputPath\Windows" -ForegroundColor Cyan
    Write-Host ""

    # Count files in output to verify pak-only distribution
    $fileCount = (Get-ChildItem -Path "$OutputPath\Windows" -Recurse -File).Count
    Write-Host "Total files in package: $fileCount" -ForegroundColor Cyan

    # Check if the packaged game exists (Shipping uses root bootstrap exe, Development uses Binaries subfolder)
    if ($BuildConfig -eq "Shipping") {
        $PackagedGamePath = "$OutputPath\Windows\RTSGame.exe"
    } else {
        $PackagedGamePath = "$OutputPath\Windows\RTSGame\Binaries\Win64\RTSGame.exe"
    }
    if (Test-Path $PackagedGamePath) {
        Write-Host "Game executable found at: $PackagedGamePath" -ForegroundColor Green

        # Choose output directory based on build config
        $BuildRoot = Join-Path (Split-Path -Parent $PSScriptRoot) "build"
        if ($BuildConfig -eq "Shipping") {
            $TargetDir = Join-Path $BuildRoot "RTSGame_Release\game"
        } else {
            $TargetDir = Join-Path $BuildRoot "RTSGame_DevTest\game"
        }

        Write-Host ""
        Write-Host "Moving packaged game to: $TargetDir" -ForegroundColor Cyan

        if (Test-Path $TargetDir) {
            Remove-Item -Path $TargetDir -Recurse -Force
        }

        Move-Item -Path "$OutputPath\Windows\*" -Destination $TargetDir -Force

        # Development builds need extra engine references that Shipping builds bundle
        if ($BuildConfig -ne "Shipping") {
            # Development builds need the .uproject descriptor
            Copy-Item -Path "$ProjectPath\RTSGame.uproject" -Destination (Join-Path $TargetDir "RTSGame\RTSGame.uproject") -Force

            # Development builds reference engine ThirdParty DLLs via ../../../Engine/Binaries/
            # Create a junction to the UE5 installation's Engine\Binaries
            $EngineBinDest = Join-Path $TargetDir "Engine\Binaries"
            $EngineBinSource = Join-Path $UE5Path "Engine\Binaries"
            if (-not (Test-Path $EngineBinDest)) {
                New-Item -ItemType Directory -Path (Join-Path $TargetDir "Engine") -Force | Out-Null
                cmd /c mklink /J "$EngineBinDest" "$EngineBinSource"
                Write-Host "Created junction: $EngineBinDest -> $EngineBinSource" -ForegroundColor Green
            }
        }

        # Copy shared_simulation.dll into packaged binaries
        $SharedSimDll = Join-Path $ProjectPath "Binaries\Win64\shared_simulation.dll"
        $SharedSimDest = Join-Path $TargetDir "RTSGame\Binaries\Win64"
        if (Test-Path $SharedSimDll) {
            Copy-Item $SharedSimDll $SharedSimDest -Force
            Write-Host "Copied shared_simulation.dll to package" -ForegroundColor Green
        } else {
            Write-Host "Warning: shared_simulation.dll not found at $SharedSimDll" -ForegroundColor Yellow
        }

        # Copy runtime config files (FPaths::ProjectConfigDir() -> RTSGame/Config/)
        $ConfigSource = Join-Path $ProjectPath "Config"
        $ConfigDest = Join-Path $TargetDir "RTSGame\Config"
        if (Test-Path $ConfigSource) {
            New-Item -ItemType Directory -Path $ConfigDest -Force | Out-Null
            Copy-Item (Join-Path $ConfigSource "*") $ConfigDest -Recurse -Force
            Write-Host "Copied Config/ to package" -ForegroundColor Green
        }

        Write-Host "Packaged game moved to: $TargetDir" -ForegroundColor Green
        Write-Host ""
        if ($BuildConfig -eq "Shipping") {
            Write-Host "Release build ready for distribution at: $TargetDir" -ForegroundColor Cyan
        } else {
            Write-Host "You can now test the launcher at: $(Join-Path $BuildRoot 'RTSGame_DevTest\RTSGame.exe')" -ForegroundColor Cyan
        }
    } else {
        Write-Host "WARNING: Could not find packaged game executable" -ForegroundColor Yellow
    }
} else {
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Red
    Write-Host "Packaging failed with exit code: $LASTEXITCODE" -ForegroundColor Red
    Write-Host "========================================" -ForegroundColor Red
    exit $LASTEXITCODE
}
