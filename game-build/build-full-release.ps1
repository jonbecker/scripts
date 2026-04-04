# Full Release Build Script
# Builds both launcher and UE5 client, then packages them together

param(
    [Parameter(Mandatory=$false)]
    [ValidateSet("Development", "Shipping")]
    [string]$Configuration = "Shipping",

    [Parameter(Mandatory=$false)]
    [string]$Version = "1.0.0",

    [Parameter(Mandatory=$false)]
    [string]$UE5Path = "C:\Program Files\Epic Games\UE_5.6",

    [Parameter(Mandatory=$false)]
    [string]$OutputPath = "",

    [Parameter(Mandatory=$false)]
    [switch]$Clean,

    [Parameter(Mandatory=$false)]
    [switch]$SignBinaries,

    [Parameter(Mandatory=$false)]
    [string]$CertificatePath = "",

    [Parameter(Mandatory=$false)]
    [string]$CertificatePassword = "",

    [Parameter(Mandatory=$false)]
    [switch]$CreateInstaller
)

# Set error action preference
$ErrorActionPreference = "Stop"

# Define paths
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectRoot = Split-Path -Parent $ScriptDir

if ([string]::IsNullOrEmpty($OutputPath)) {
    $OutputPath = Join-Path $ProjectRoot "build\release"
}

$LauncherOutputPath = Join-Path $OutputPath "launcher"
$UE5OutputPath = Join-Path $OutputPath "game"
$InstallerOutputPath = Join-Path $OutputPath "installer"

Write-Host "========================================" -ForegroundColor Cyan
Write-Host " Full Release Build Script" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Version:       $Version" -ForegroundColor Yellow
Write-Host "Configuration: $Configuration" -ForegroundColor Yellow
Write-Host "Output Path:   $OutputPath" -ForegroundColor Yellow
Write-Host ""

# Create output directory
if (-not (Test-Path $OutputPath)) {
    New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
}

# Save start time
$StartTime = Get-Date

# Step 1: Update version numbers
Write-Host "Step 1: Updating version numbers to $Version..." -ForegroundColor Cyan

# Update launcher package.json
$PackageJsonPath = Join-Path $ProjectRoot "launcher\package.json"
if (Test-Path $PackageJsonPath) {
    Write-Host "  Updating launcher/package.json..."
    $PackageJson = Get-Content $PackageJsonPath -Raw | ConvertFrom-Json
    $PackageJson.version = $Version
    $PackageJson | ConvertTo-Json -Depth 10 | Set-Content $PackageJsonPath
}

# Update Tauri config
$TauriConfigPath = Join-Path $ProjectRoot "launcher\src-tauri\tauri.conf.json"
if (Test-Path $TauriConfigPath) {
    Write-Host "  Updating launcher/src-tauri/tauri.conf.json..."
    $TauriConfig = Get-Content $TauriConfigPath -Raw | ConvertFrom-Json
    $TauriConfig.package.version = $Version
    $TauriConfig | ConvertTo-Json -Depth 10 | Set-Content $TauriConfigPath
}

# Update UE5 project version
$DefaultGamePath = Join-Path $ProjectRoot "ue5_client\RTSGame\Config\DefaultGame.ini"
if (Test-Path $DefaultGamePath) {
    Write-Host "  Updating ue5_client/RTSGame/Config/DefaultGame.ini..."
    $DefaultGame = Get-Content $DefaultGamePath
    $DefaultGame = $DefaultGame -replace 'ProjectVersion=.*', "ProjectVersion=$Version"
    Set-Content $DefaultGamePath $DefaultGame
}

Write-Host "Version numbers updated." -ForegroundColor Green
Write-Host ""

# Step 1b: Build Download Server + Release Tool (Plan 63)
Write-Host "Step 1b: Building Download Server and Release Tool..." -ForegroundColor Cyan

Push-Location $ProjectRoot
& cargo build -p download_server --release
if ($LASTEXITCODE -ne 0) {
    Write-Error "download_server build failed"
    exit $LASTEXITCODE
}
Pop-Location

Write-Host "Download server and release tool built." -ForegroundColor Green
Write-Host ""

# Step 2: Build Launcher
Write-Host "Step 2: Building Launcher..." -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Gray

$LauncherBuildScript = Join-Path $ScriptDir "build-launcher.ps1"
$LauncherArgs = @(
    "-Configuration", "Release",
    "-OutputPath", $LauncherOutputPath
)

if ($Clean) {
    $LauncherArgs += "-Clean"
}

& $LauncherBuildScript @LauncherArgs

if ($LASTEXITCODE -ne 0) {
    Write-Error "Launcher build failed"
    exit $LASTEXITCODE
}

Write-Host "========================================" -ForegroundColor Gray
Write-Host "Launcher build complete." -ForegroundColor Green
Write-Host ""

# Step 3: Build UE5 Client
Write-Host "Step 3: Building UE5 Client..." -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Gray

$UE5BuildScript = Join-Path $ScriptDir "build-ue5.ps1"
$UE5Args = @(
    "-Configuration", $Configuration,
    "-UE5Path", $UE5Path,
    "-OutputPath", $UE5OutputPath,
    "-Package"
)

if ($Clean) {
    $UE5Args += "-Clean"
}

& $UE5BuildScript @UE5Args

if ($LASTEXITCODE -ne 0) {
    Write-Error "UE5 build failed"
    exit $LASTEXITCODE
}

Write-Host "========================================" -ForegroundColor Gray
Write-Host "UE5 client build complete." -ForegroundColor Green
Write-Host ""

# Step 4: Organize release structure
Write-Host "Step 4: Organizing release structure..." -ForegroundColor Cyan

$ReleasePath = Join-Path $OutputPath "RTSGame-$Version"

if (Test-Path $ReleasePath) {
    Write-Host "  Removing existing release directory..."
    Remove-Item -Path $ReleasePath -Recurse -Force
}

Write-Host "  Creating release structure..."
New-Item -ItemType Directory -Path $ReleasePath -Force | Out-Null

# Copy launcher
Write-Host "  Copying launcher..."
$LauncherExe = Join-Path $LauncherOutputPath "launcher.exe"
if (Test-Path $LauncherExe) {
    Copy-Item -Path $LauncherExe -Destination "$ReleasePath\RTSGame.exe" -Force
}

$WebView2Dll = Join-Path $LauncherOutputPath "WebView2Loader.dll"
if (Test-Path $WebView2Dll) {
    Copy-Item -Path $WebView2Dll -Destination $ReleasePath -Force
}

# Copy game files
Write-Host "  Copying game files..."
$GamePath = Join-Path $ReleasePath "game"
New-Item -ItemType Directory -Path $GamePath -Force | Out-Null

$UE5GamePath = Join-Path $UE5OutputPath "Windows"
if (Test-Path $UE5GamePath) {
    Copy-Item -Path "$UE5GamePath\*" -Destination $GamePath -Recurse -Force
}

# Copy certificates
Write-Host "  Copying certificates..."
$CertsPath = Join-Path $ReleasePath "certs"
New-Item -ItemType Directory -Path $CertsPath -Force | Out-Null

$CertsSource = Join-Path $ProjectRoot "certs\dev"
if (Test-Path $CertsSource) {
    Copy-Item -Path "$CertsSource\*" -Destination $CertsPath -Recurse
}

# Copy README and licenses
Write-Host "  Copying documentation..."
$ReadmePath = Join-Path $ProjectRoot "README.md"
if (Test-Path $ReadmePath) {
    Copy-Item -Path $ReadmePath -Destination $ReleasePath -Force
}

$LicensePath = Join-Path $ProjectRoot "LICENSE"
if (Test-Path $LicensePath) {
    Copy-Item -Path $LicensePath -Destination $ReleasePath -Force
}

Write-Host "Release structure organized." -ForegroundColor Green
Write-Host ""

# Step 5: Sign binaries (if requested)
if ($SignBinaries) {
    Write-Host "Step 5: Signing binaries..." -ForegroundColor Cyan

    if ([string]::IsNullOrEmpty($CertificatePath) -or [string]::IsNullOrEmpty($CertificatePassword)) {
        Write-Warning "Certificate path or password not provided. Skipping signing."
    } else {
        # Find signtool
        $SignTool = "${env:ProgramFiles(x86)}\Windows Kits\10\bin\10.0.22000.0\x64\signtool.exe"

        if (-not (Test-Path $SignTool)) {
            # Try to find signtool in other locations
            $SignTool = Get-Command signtool.exe -ErrorAction SilentlyContinue
            if (-not $SignTool) {
                Write-Warning "signtool.exe not found. Skipping signing."
                $SignBinaries = $false
            }
        }

        if ($SignBinaries) {
            # Get all executables to sign
            $FilesToSign = @()
            $FilesToSign += Get-ChildItem -Path $ReleasePath -Filter "*.exe" -Recurse
            $FilesToSign += Get-ChildItem -Path $ReleasePath -Filter "*.dll" -Recurse |
                Where-Object { $_.Name -notmatch "^api-ms-win" }

            Write-Host "  Found $($FilesToSign.Count) files to sign"

            foreach ($File in $FilesToSign) {
                Write-Host "  Signing: $($File.Name)"

                & $SignTool sign `
                    /f $CertificatePath `
                    /p $CertificatePassword `
                    /t "http://timestamp.digicert.com" `
                    /fd SHA256 `
                    $File.FullName

                if ($LASTEXITCODE -ne 0) {
                    Write-Warning "Failed to sign $($File.Name)"
                }
            }

            Write-Host "Binary signing complete." -ForegroundColor Green
        }
    }
    Write-Host ""
} else {
    Write-Host "Step 5: Skipping binary signing (not requested)." -ForegroundColor Yellow
    Write-Host ""
}

# Step 6: Create installer (if requested)
if ($CreateInstaller) {
    Write-Host "Step 6: Creating installer..." -ForegroundColor Cyan

    # Check for WiX toolset
    $WixPath = "${env:ProgramFiles(x86)}\WiX Toolset v3.11\bin"
    $Candle = Join-Path $WixPath "candle.exe"
    $Light = Join-Path $WixPath "light.exe"

    if (-not (Test-Path $Candle) -or -not (Test-Path $Light)) {
        Write-Warning "WiX Toolset not found. Attempting to use Inno Setup instead..."

        # Try Inno Setup
        $InnoSetup = "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe"

        if (Test-Path $InnoSetup) {
            Write-Host "  Using Inno Setup..."

            # Create Inno Setup script
            $IssPath = Join-Path $InstallerOutputPath "setup.iss"
            New-Item -ItemType Directory -Path $InstallerOutputPath -Force | Out-Null

            $IssContent = @"
[Setup]
AppId={{YOUR-GUID-HERE}
AppName=RTS Game
AppVersion=$Version
AppPublisher=Your Company
AppPublisherURL=https://yourcompany.com
AppSupportURL=https://yourcompany.com/support
AppUpdatesURL=https://yourcompany.com/updates
DefaultDirName={autopf}\RTSGame
DisableProgramGroupPage=yes
OutputDir=$InstallerOutputPath
OutputBaseFilename=RTSGame-$Version-Setup
Compression=lzma2
SolidCompression=yes
WizardStyle=modern

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "$ReleasePath\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\RTS Game"; Filename: "{app}\RTSGame.exe"
Name: "{autodesktop}\RTS Game"; Filename: "{app}\RTSGame.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\RTSGame.exe"; Description: "{cm:LaunchProgram,RTS Game}"; Flags: nowait postinstall skipifsilent
"@
            Set-Content -Path $IssPath -Value $IssContent

            Write-Host "  Compiling installer..."
            & $InnoSetup $IssPath

            if ($LASTEXITCODE -eq 0) {
                Write-Host "Installer created successfully." -ForegroundColor Green
            } else {
                Write-Warning "Installer creation failed."
            }
        } else {
            Write-Warning "Neither WiX nor Inno Setup found. Skipping installer creation."
            Write-Host "  Please install WiX Toolset or Inno Setup to create installers."
        }
    } else {
        Write-Host "  Using WiX Toolset..."

        # Create WiX source file
        $WxsPath = Join-Path $InstallerOutputPath "installer.wxs"
        New-Item -ItemType Directory -Path $InstallerOutputPath -Force | Out-Null

        # Generate WiX XML (simplified version)
        $WxsContent = @"
<?xml version="1.0" encoding="UTF-8"?>
<Wix xmlns="http://schemas.microsoft.com/wix/2006/wi">
    <Product Id="*" Name="RTS Game" Language="1033" Version="$Version"
             Manufacturer="Your Company" UpgradeCode="YOUR-UPGRADE-GUID">
        <Package InstallerVersion="300" Compressed="yes" InstallScope="perMachine" />
        <MajorUpgrade DowngradeErrorMessage="A newer version is already installed." />
        <MediaTemplate EmbedCab="yes" />

        <Feature Id="ProductFeature" Title="RTS Game" Level="1">
            <ComponentGroupRef Id="ProductComponents" />
        </Feature>

        <Directory Id="TARGETDIR" Name="SourceDir">
            <Directory Id="ProgramFiles64Folder">
                <Directory Id="INSTALLFOLDER" Name="RTSGame" />
            </Directory>
        </Directory>

        <ComponentGroup Id="ProductComponents" Directory="INSTALLFOLDER">
            <Component Id="MainExecutable" Guid="YOUR-COMPONENT-GUID">
                <File Id="RTSGameExe" Source="$ReleasePath\RTSGame.exe" KeyPath="yes" />
            </Component>
        </ComponentGroup>
    </Product>
</Wix>
"@
        Set-Content -Path $WxsPath -Value $WxsContent

        Write-Host "  Compiling installer with WiX..."

        # Compile
        & $Candle -o "$InstallerOutputPath\installer.wixobj" $WxsPath

        # Link
        & $Light -o "$InstallerOutputPath\RTSGame-$Version-Setup.msi" "$InstallerOutputPath\installer.wixobj"

        if ($LASTEXITCODE -eq 0) {
            Write-Host "MSI installer created successfully." -ForegroundColor Green
        } else {
            Write-Warning "MSI creation failed."
        }
    }

    Write-Host ""
} else {
    Write-Host "Step 6: Skipping installer creation (not requested)." -ForegroundColor Yellow
    Write-Host ""
}

# Step 7: Create archive
Write-Host "Step 7: Creating release archive..." -ForegroundColor Cyan

$ArchiveName = "RTSGame-$Version-windows-x64.zip"
$ArchivePath = Join-Path $OutputPath $ArchiveName

# Remove existing archive if present
if (Test-Path $ArchivePath) {
    Remove-Item -Path $ArchivePath -Force
}

# Create ZIP archive
Write-Host "  Creating $ArchiveName..."

if (Get-Command 7z -ErrorAction SilentlyContinue) {
    # Use 7-Zip if available (better compression)
    & 7z a -tzip -mx=9 $ArchivePath "$ReleasePath\*"
} else {
    # Use built-in compression
    Compress-Archive -Path "$ReleasePath\*" -DestinationPath $ArchivePath -CompressionLevel Optimal
}

if (Test-Path $ArchivePath) {
    $ArchiveInfo = Get-Item $ArchivePath
    Write-Host "  Archive size: $([math]::Round($ArchiveInfo.Length / 1MB, 2)) MB"
    Write-Host "Archive created successfully." -ForegroundColor Green
} else {
    Write-Warning "Failed to create archive."
}

Write-Host ""

# Calculate build time
$EndTime = Get-Date
$BuildTime = $EndTime - $StartTime

# Summary
Write-Host "========================================" -ForegroundColor Green
Write-Host " Full Release Build Complete!" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green
Write-Host ""
Write-Host "Version:     $Version" -ForegroundColor Yellow
Write-Host "Build Time:  $($BuildTime.ToString('mm\:ss'))" -ForegroundColor Yellow
Write-Host ""
Write-Host "Output Directory: $OutputPath" -ForegroundColor Cyan
Write-Host ""
Write-Host "Release Contents:" -ForegroundColor Cyan

# List release contents
Get-ChildItem $OutputPath -Recurse | Where-Object { -not $_.PSIsContainer } |
    Group-Object Extension | Sort-Object Count -Descending |
    Format-Table @{Label="Extension"; Expression={$_.Name}}, Count -AutoSize

# Calculate total size
$TotalSize = (Get-ChildItem $ReleasePath -Recurse |
    Where-Object { -not $_.PSIsContainer } |
    Measure-Object -Property Length -Sum).Sum

Write-Host ""
Write-Host "Total Release Size: $([math]::Round($TotalSize / 1MB, 2)) MB" -ForegroundColor Yellow

if (Test-Path $ArchivePath) {
    Write-Host "Archive: $ArchiveName" -ForegroundColor Green
}

$InstallerPath = Join-Path $InstallerOutputPath "RTSGame-$Version-Setup.msi"
if (Test-Path $InstallerPath) {
    Write-Host "Installer: RTSGame-$Version-Setup.msi" -ForegroundColor Green
}

Write-Host ""
Write-Host "Release build completed successfully!" -ForegroundColor Green

exit 0