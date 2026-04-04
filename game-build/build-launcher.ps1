# Build Launcher Script
# This script builds the Tauri-based launcher for Windows

param(
    [Parameter(Mandatory=$false)]
    [ValidateSet("Debug", "Release")]
    [string]$Configuration = "Release",

    [Parameter(Mandatory=$false)]
    [string]$OutputPath = "",

    [Parameter(Mandatory=$false)]
    [switch]$Clean,

    [Parameter(Mandatory=$false)]
    [switch]$SkipTypeScript,

    [Parameter(Mandatory=$false)]
    [switch]$Bundle
)

# Set error action preference
$ErrorActionPreference = "Stop"

# Define paths
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectRoot = Split-Path -Parent $ScriptDir
$LauncherPath = Join-Path $ProjectRoot "launcher"

if ([string]::IsNullOrEmpty($OutputPath)) {
    $OutputPath = Join-Path $ProjectRoot "build\launcher_output"
}

Write-Host "========================================" -ForegroundColor Cyan
Write-Host " Launcher Build Script" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Configuration: $Configuration" -ForegroundColor Yellow
Write-Host "Launcher Path: $LauncherPath" -ForegroundColor Yellow
Write-Host "Output Path:   $OutputPath" -ForegroundColor Yellow
Write-Host ""

# Change to launcher directory
Push-Location $LauncherPath

try {
    # Check prerequisites
    Write-Host "Checking prerequisites..." -ForegroundColor Yellow

    # Check Node.js
    $NodeVersion = node --version 2>$null
    if (-not $NodeVersion) {
        Write-Error "Node.js is not installed. Please install Node.js 20 or later."
        exit 1
    }
    Write-Host "  Node.js: $NodeVersion" -ForegroundColor Green

    # Check npm
    $NpmVersion = npm --version 2>$null
    if (-not $NpmVersion) {
        Write-Error "npm is not installed."
        exit 1
    }
    Write-Host "  npm: $NpmVersion" -ForegroundColor Green

    # Check Rust
    $RustVersion = rustc --version 2>$null
    if (-not $RustVersion) {
        Write-Error "Rust is not installed. Please install Rust from https://rustup.rs/"
        exit 1
    }
    Write-Host "  Rust: $RustVersion" -ForegroundColor Green

    # Check Tauri CLI
    $TauriInstalled = npm list -g @tauri-apps/cli 2>$null
    if (-not $TauriInstalled -or $TauriInstalled -match "empty") {
        Write-Host "  Installing Tauri CLI globally..."
        npm install -g @tauri-apps/cli@latest
    } else {
        Write-Host "  Tauri CLI: Installed" -ForegroundColor Green
    }

    Write-Host ""

    # Clean if requested
    if ($Clean) {
        Write-Host "Cleaning previous build..." -ForegroundColor Yellow

        $DirsToClean = @(
            "dist",
            "src-tauri\target",
            "node_modules"
        )

        foreach ($Dir in $DirsToClean) {
            $FullPath = Join-Path $LauncherPath $Dir
            if (Test-Path $FullPath) {
                Write-Host "  Removing: $Dir"
                Remove-Item -Path $FullPath -Recurse -Force
            }
        }

        # Clean npm cache
        Write-Host "  Cleaning npm cache..."
        npm cache clean --force

        Write-Host "Clean complete." -ForegroundColor Green
        Write-Host ""
    }

    # Step 1: Install dependencies
    Write-Host "Step 1: Installing dependencies..." -ForegroundColor Cyan

    if (-not (Test-Path "node_modules")) {
        Write-Host "Running: npm ci"
        npm ci

        if ($LASTEXITCODE -ne 0) {
            Write-Host "npm ci failed, trying npm install..."
            npm install
        }
    } else {
        Write-Host "Dependencies already installed. Run with -Clean to reinstall."
    }

    Write-Host "Dependencies installed." -ForegroundColor Green
    Write-Host ""

    # Step 2: Build TypeScript (unless skipped)
    if (-not $SkipTypeScript) {
        Write-Host "Step 2: Building TypeScript..." -ForegroundColor Cyan

        # Run TypeScript compiler
        Write-Host "Running: npm run build"
        npm run build

        if ($LASTEXITCODE -ne 0) {
            Write-Error "TypeScript build failed"
            exit $LASTEXITCODE
        }

        Write-Host "TypeScript build complete." -ForegroundColor Green
        Write-Host ""
    } else {
        Write-Host "Step 2: Skipping TypeScript build." -ForegroundColor Yellow
        Write-Host ""
    }

    # Step 3: Build Tauri application
    Write-Host "Step 3: Building Tauri application..." -ForegroundColor Cyan

    # Prepare Tauri build command
    $TauriBuildCmd = "npm run tauri:build"

    if ($Configuration -eq "Debug") {
        $TauriBuildCmd += " -- --debug"
    }

    Write-Host "Running: $TauriBuildCmd"
    Invoke-Expression $TauriBuildCmd

    if ($LASTEXITCODE -ne 0) {
        Write-Error "Tauri build failed"
        exit $LASTEXITCODE
    }

    Write-Host "Tauri build complete." -ForegroundColor Green
    Write-Host ""

    # Step 4: Copy outputs
    Write-Host "Step 4: Copying build outputs..." -ForegroundColor Cyan

    # Create output directory
    if (-not (Test-Path $OutputPath)) {
        New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
    }

    # Determine build folder based on configuration
    $BuildFolder = if ($Configuration -eq "Debug") { "debug" } else { "release" }

    # Workspace builds output to root target/, not launcher/src-tauri/target/
    $TargetBase = Join-Path $ProjectRoot "target\$BuildFolder"

    # Copy executable
    $ExeSource = Join-Path $TargetBase "rts-launcher.exe"
    $ExeDest = Join-Path $OutputPath "rts-launcher.exe"

    if (Test-Path $ExeSource) {
        Write-Host "Copying launcher executable..."
        Copy-Item -Path $ExeSource -Destination $ExeDest -Force

        $FileInfo = Get-Item $ExeDest
        Write-Host "  Size: $([math]::Round($FileInfo.Length / 1MB, 2)) MB"
    } else {
        Write-Warning "Launcher executable not found at: $ExeSource"
    }

    # Copy WebView2 loader if it exists
    $WebView2Source = Join-Path $TargetBase "WebView2Loader.dll"
    if (Test-Path $WebView2Source) {
        Write-Host "Copying WebView2 loader..."
        Copy-Item -Path $WebView2Source -Destination $OutputPath -Force
    }

    # Copy bundle if requested and exists
    if ($Bundle) {
        $BundleSource = Join-Path $TargetBase "bundle"

        if (Test-Path $BundleSource) {
            Write-Host "Copying bundle files..."

            # Copy MSI installer
            $MsiFiles = Get-ChildItem -Path "$BundleSource\msi\*.msi" -ErrorAction SilentlyContinue
            if ($MsiFiles) {
                foreach ($Msi in $MsiFiles) {
                    Write-Host "  Copying MSI: $($Msi.Name)"
                    Copy-Item -Path $Msi.FullName -Destination $OutputPath -Force
                }
            }

            # Copy NSIS installer and signature with standardized naming
            $TauriConf = Get-Content (Join-Path $LauncherPath "src-tauri\tauri.conf.json") | ConvertFrom-Json
            $Version = $TauriConf.version
            $InstallerName = "launcher-v${Version}-windows-x86_64-setup"

            # Clean old NSIS artifacts to avoid picking stale versions
            $NsisDir = Join-Path $BundleSource "nsis"
            Get-ChildItem -Path "$NsisDir\*.exe" -ErrorAction SilentlyContinue | Where-Object {
                $_.Name -notmatch [regex]::Escape($Version)
            } | ForEach-Object {
                Write-Host "  Removing stale NSIS artifact: $($_.Name)" -ForegroundColor Yellow
                Remove-Item $_.FullName -Force
                $sigFile = "$($_.FullName).sig"
                if (Test-Path $sigFile) { Remove-Item $sigFile -Force }
            }

            # Find the installer matching the current version
            $VersionPattern = "*${Version}*"
            $NsisExe = Get-ChildItem -Path "$NsisDir\*.exe" -ErrorAction SilentlyContinue | Where-Object {
                $_.Name -like $VersionPattern -and $_.Name -notmatch '\.sig$'
            } | Select-Object -First 1
            if ($NsisExe) {
                $Dest = Join-Path $OutputPath "$InstallerName.exe"
                Write-Host "  Copying NSIS installer: $InstallerName.exe (from $($NsisExe.Name))"
                Copy-Item -Path $NsisExe.FullName -Destination $Dest -Force
            } else {
                Write-Warning "No NSIS installer found matching version $Version in $NsisDir"
            }

            $NsisSig = Get-ChildItem -Path "$NsisDir\*.exe.sig" -ErrorAction SilentlyContinue | Where-Object {
                $_.Name -like $VersionPattern
            } | Select-Object -First 1
            if ($NsisSig) {
                $Dest = Join-Path $OutputPath "$InstallerName.exe.sig"
                Write-Host "  Copying signature: $InstallerName.exe.sig"
                Copy-Item -Path $NsisSig.FullName -Destination $Dest -Force
            } else {
                Write-Warning "No NSIS signature found matching version $Version in $NsisDir"
            }
        } else {
            Write-Warning "Bundle not found. Run with default Tauri build to create installers."
        }
    }

    Write-Host "Build outputs copied." -ForegroundColor Green
    Write-Host ""

} finally {
    Pop-Location
}

# Summary
Write-Host "========================================" -ForegroundColor Green
Write-Host " Launcher Build Complete!" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green
Write-Host ""
Write-Host "Output directory: $OutputPath" -ForegroundColor Yellow

$ExePath = Join-Path $OutputPath "rts-launcher.exe"
if (Test-Path $ExePath) {
    Write-Host ""
    Write-Host "You can run the launcher with:" -ForegroundColor Yellow
    Write-Host "  & `"$ExePath`""
    Write-Host ""
    Write-Host "Or launch with developer tools:" -ForegroundColor Yellow
    Write-Host "  & `"$ExePath`" --dev"
}

# List all output files
Write-Host ""
Write-Host "Generated files:" -ForegroundColor Cyan
Get-ChildItem $OutputPath | ForEach-Object {
    $Size = if ($_.PSIsContainer) { "<DIR>" } else { "$([math]::Round($_.Length / 1MB, 2)) MB" }
    Write-Host ("  {0,-40} {1,10}" -f $_.Name, $Size)
}

exit 0