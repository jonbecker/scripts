# Bump launcher version across all config files
# Usage: .\bump-launcher-version.ps1 -Bump patch    (0.3.5 → 0.3.6)
#        .\bump-launcher-version.ps1 -Bump minor    (0.3.5 → 0.4.0)
#        .\bump-launcher-version.ps1 -Bump major    (0.3.5 → 1.0.0)
#        .\bump-launcher-version.ps1 -Version "1.2.3" (explicit override)

param(
    [Parameter(Mandatory=$false)]
    [ValidateSet("major", "minor", "patch")]
    [string]$Bump,

    [Parameter(Mandatory=$false)]
    [string]$Version
)

$ErrorActionPreference = "Stop"

if (-not $Bump -and -not $Version) {
    Write-Error "Specify either -Bump (major|minor|patch) or -Version `"x.y.z`""
    exit 1
}

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectRoot = Split-Path -Parent $ScriptDir
$LauncherDir = Join-Path $ProjectRoot "launcher"

# Read current version from package.json (source of truth)
$pkgPath = Join-Path $LauncherDir "package.json"
$pkgContent = Get-Content $pkgPath -Raw
if ($pkgContent -match '"version":\s*"(\d+)\.(\d+)\.(\d+)"') {
    $curMajor = [int]$Matches[1]
    $curMinor = [int]$Matches[2]
    $curPatch = [int]$Matches[3]
    $currentVersion = "$curMajor.$curMinor.$curPatch"
} else {
    Write-Error "Could not parse current version from package.json"
    exit 1
}

if ($Bump) {
    switch ($Bump) {
        "major" { $Version = "$($curMajor + 1).0.0" }
        "minor" { $Version = "$curMajor.$($curMinor + 1).0" }
        "patch" { $Version = "$curMajor.$curMinor.$($curPatch + 1)" }
    }
}

Write-Host "Version: $currentVersion -> $Version" -ForegroundColor Cyan

$simpleFiles = @(
    @{ Path = "src-tauri\tauri.conf.json"; Pattern = '"version": "\d+\.\d+\.\d+"'; Replace = "`"version`": `"$Version`"" },
    @{ Path = "src-tauri\Cargo.toml";      Pattern = '(?m)^version = "\d+\.\d+\.\d+"'; Replace = "version = `"$Version`"" },
    @{ Path = "package.json";              Pattern = '"version": "\d+\.\d+\.\d+"'; Replace = "`"version`": `"$Version`"" }
)

foreach ($f in $simpleFiles) {
    $fullPath = Join-Path $LauncherDir $f.Path
    if (-not (Test-Path $fullPath)) {
        Write-Warning "File not found: $($f.Path)"
        continue
    }
    $content = Get-Content $fullPath -Raw
    $count = ([regex]::Matches($content, $f.Pattern)).Count
    $content = $content -replace $f.Pattern, $f.Replace
    Set-Content -Path $fullPath -Value $content -NoNewline
    Write-Host "  $($f.Path) ($count replacement(s))" -ForegroundColor Green
}

# package-lock.json: only update the two top-level version fields (lines 3 and 9),
# not the hundreds of dependency version strings
$lockFile = Join-Path $LauncherDir "package-lock.json"
if (Test-Path $lockFile) {
    $lines = Get-Content $lockFile
    $count = 0
    for ($i = 0; $i -lt [Math]::Min(15, $lines.Count); $i++) {
        if ($lines[$i] -match '^\s+"version": "\d+\.\d+\.\d+"') {
            $lines[$i] = $lines[$i] -replace '"version": "\d+\.\d+\.\d+"', "`"version`": `"$Version`""
            $count++
        }
    }
    $lines | Set-Content $lockFile
    Write-Host "  package-lock.json ($count replacement(s))" -ForegroundColor Green
}

Write-Host ""
Write-Host "Launcher version bumped to $Version" -ForegroundColor Cyan
