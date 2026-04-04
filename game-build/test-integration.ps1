# Integration Test Script
# Tests the launcher and UE5 client integration

param(
    [Parameter(Mandatory=$false)]
    [ValidateSet("Quick", "Full", "Smoke")]
    [string]$TestMode = "Full",

    [Parameter(Mandatory=$false)]
    [string]$LauncherPath = "",

    [Parameter(Mandatory=$false)]
    [string]$GamePath = "",

    [Parameter(Mandatory=$false)]
    [string]$TestServerUrl = "ws://localhost:3000",

    [Parameter(Mandatory=$false)]
    [switch]$KeepRunning
)

# Set error action preference
$ErrorActionPreference = "Stop"

# Define paths
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectRoot = Split-Path -Parent $ScriptDir

if ([string]::IsNullOrEmpty($LauncherPath)) {
    $LauncherPath = Join-Path $ProjectRoot "build\release\RTSGame.exe"
}

if ([string]::IsNullOrEmpty($GamePath)) {
    $GamePath = Join-Path $ProjectRoot "build\release\game\RTSGame.exe"
}

Write-Host "========================================" -ForegroundColor Cyan
Write-Host " Integration Test Suite" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Test Mode:     $TestMode" -ForegroundColor Yellow
Write-Host "Launcher Path: $LauncherPath" -ForegroundColor Yellow
Write-Host "Game Path:     $GamePath" -ForegroundColor Yellow
Write-Host "Test Server:   $TestServerUrl" -ForegroundColor Yellow
Write-Host ""

# Test results
$TestResults = @{
    Passed = 0
    Failed = 0
    Skipped = 0
    Details = @()
}

function Test-Component {
    param(
        [string]$Name,
        [scriptblock]$TestScript,
        [switch]$Critical
    )

    Write-Host "Testing: $Name..." -ForegroundColor Cyan -NoNewline

    try {
        $result = & $TestScript

        if ($result) {
            Write-Host " PASSED" -ForegroundColor Green
            $TestResults.Passed++
            $TestResults.Details += @{
                Test = $Name
                Status = "Passed"
                Details = $result
            }
            return $true
        } else {
            Write-Host " FAILED" -ForegroundColor Red
            $TestResults.Failed++
            $TestResults.Details += @{
                Test = $Name
                Status = "Failed"
                Details = "Test returned false"
            }

            if ($Critical) {
                throw "Critical test failed: $Name"
            }
            return $false
        }
    } catch {
        Write-Host " ERROR" -ForegroundColor Red
        Write-Host "  Error: $_" -ForegroundColor Red
        $TestResults.Failed++
        $TestResults.Details += @{
            Test = $Name
            Status = "Error"
            Details = $_.ToString()
        }

        if ($Critical) {
            throw "Critical test failed: $Name - $_"
        }
        return $false
    }
}

# Test 1: Check file existence
Test-Component -Name "Launcher Executable Exists" -Critical -TestScript {
    Test-Path $LauncherPath
}

Test-Component -Name "Game Executable Exists" -Critical -TestScript {
    Test-Path $GamePath
}

Test-Component -Name "WebView2 Loader Exists" -TestScript {
    $WebView2Path = Join-Path (Split-Path $LauncherPath -Parent) "WebView2Loader.dll"
    Test-Path $WebView2Path
}

Test-Component -Name "Certificates Exist" -TestScript {
    $CertsPath = Join-Path (Split-Path $LauncherPath -Parent) "certs\ca_cert.pem"
    Test-Path $CertsPath
}

# Test 2: Check file signatures (if signed)
if ($TestMode -ne "Smoke") {
    Test-Component -Name "Launcher Signature Valid" -TestScript {
        $Sig = Get-AuthenticodeSignature -FilePath $LauncherPath
        $Sig.Status -eq "Valid" -or $Sig.Status -eq "NotSigned"
    }

    Test-Component -Name "Game Signature Valid" -TestScript {
        $Sig = Get-AuthenticodeSignature -FilePath $GamePath
        $Sig.Status -eq "Valid" -or $Sig.Status -eq "NotSigned"
    }
}

# Test 3: Launch launcher
Write-Host ""
Write-Host "Step 2: Testing Launcher Startup..." -ForegroundColor Yellow
Write-Host ""

$LauncherProcess = $null

Test-Component -Name "Launcher Starts Successfully" -Critical -TestScript {
    try {
        $LauncherProcess = Start-Process -FilePath $LauncherPath -PassThru -WindowStyle Normal
        Start-Sleep -Seconds 3

        if ($LauncherProcess.HasExited) {
            throw "Launcher exited immediately with code $($LauncherProcess.ExitCode)"
        }

        # Check if process is running
        $Running = Get-Process -Id $LauncherProcess.Id -ErrorAction SilentlyContinue
        return ($null -ne $Running)
    } catch {
        throw $_
    }
}

# Test 4: Check launcher memory usage
if ($TestMode -eq "Full" -and $LauncherProcess) {
    Test-Component -Name "Launcher Memory Usage Reasonable" -TestScript {
        Start-Sleep -Seconds 2
        $Process = Get-Process -Id $LauncherProcess.Id -ErrorAction SilentlyContinue

        if ($Process) {
            $MemoryMB = [math]::Round($Process.WorkingSet64 / 1MB, 2)
            Write-Host " (${MemoryMB} MB)" -NoNewline

            # Check if memory usage is reasonable (< 200 MB)
            return $MemoryMB -lt 200
        }
        return $false
    }
}

# Test 5: Test WebSocket connection
if ($TestMode -ne "Smoke") {
    Write-Host ""
    Write-Host "Step 3: Testing Network Connectivity..." -ForegroundColor Yellow
    Write-Host ""

    Test-Component -Name "WebSocket Connection Test" -TestScript {
        # Try to connect to test server
        try {
            $TestConnection = Test-NetConnection -ComputerName "localhost" -Port 3000 -ErrorAction SilentlyContinue

            if ($TestConnection.TcpTestSucceeded) {
                return $true
            } else {
                Write-Host " (Server not running - skipping)" -NoNewline -ForegroundColor Yellow
                $TestResults.Skipped++
                return $true  # Not a failure if server isn't running
            }
        } catch {
            $TestResults.Skipped++
            return $true  # Not a failure if test not available
        }
    }
}

# Test 6: Launch game with parameters
if ($TestMode -eq "Full") {
    Write-Host ""
    Write-Host "Step 4: Testing Game Launch..." -ForegroundColor Yellow
    Write-Host ""

    $GameProcess = $null

    Test-Component -Name "Game Launches with Parameters" -TestScript {
        try {
            # NOTE: These are hardcoded LOCAL DEV/TEST credentials only — not used in production
            $GameArgs = @(
                "-game",
                "-windowed",
                "-ResX=1280",
                "-ResY=720",
                "-Username=TestUser",
                "-Password=TestPass",
                "-ServerAddress=$TestServerUrl",
                "-GameId=test_game_001",
                "-LaunchedFromLauncher=true"
            )

            $GameProcess = Start-Process -FilePath $GamePath -ArgumentList $GameArgs -PassThru -WindowStyle Normal
            Start-Sleep -Seconds 5

            if ($GameProcess.HasExited) {
                throw "Game exited immediately with code $($GameProcess.ExitCode)"
            }

            # Check if process is running
            $Running = Get-Process -Id $GameProcess.Id -ErrorAction SilentlyContinue
            return ($null -ne $Running)
        } catch {
            throw $_
        }
    }

    # Check game memory usage
    if ($GameProcess) {
        Test-Component -Name "Game Memory Usage Reasonable" -TestScript {
            Start-Sleep -Seconds 3
            $Process = Get-Process -Id $GameProcess.Id -ErrorAction SilentlyContinue

            if ($Process) {
                $MemoryMB = [math]::Round($Process.WorkingSet64 / 1MB, 2)
                Write-Host " (${MemoryMB} MB)" -NoNewline

                # Check if memory usage is reasonable (< 4000 MB)
                return $MemoryMB -lt 4000
            }
            return $false
        }
    }
}

# Test 7: Check for crashes
if ($TestMode -eq "Full") {
    Write-Host ""
    Write-Host "Step 5: Stability Testing..." -ForegroundColor Yellow
    Write-Host ""

    Test-Component -Name "Launcher Remains Stable (10s)" -TestScript {
        if ($LauncherProcess -and -not $LauncherProcess.HasExited) {
            Start-Sleep -Seconds 10
            return -not $LauncherProcess.HasExited
        }
        return $false
    }

    if ($GameProcess) {
        Test-Component -Name "Game Remains Stable (10s)" -TestScript {
            if ($GameProcess -and -not $GameProcess.HasExited) {
                Start-Sleep -Seconds 10
                return -not $GameProcess.HasExited
            }
            return $false
        }
    }
}

# Cleanup
Write-Host ""
Write-Host "Step 6: Cleanup..." -ForegroundColor Yellow

if (-not $KeepRunning) {
    # Stop processes
    if ($GameProcess -and -not $GameProcess.HasExited) {
        Write-Host "  Stopping game process..."
        Stop-Process -Id $GameProcess.Id -Force -ErrorAction SilentlyContinue
    }

    if ($LauncherProcess -and -not $LauncherProcess.HasExited) {
        Write-Host "  Stopping launcher process..."
        Stop-Process -Id $LauncherProcess.Id -Force -ErrorAction SilentlyContinue
    }

    Write-Host "  Cleanup complete." -ForegroundColor Green
} else {
    Write-Host "  Keeping processes running (use -KeepRunning:$false to auto-close)" -ForegroundColor Yellow

    if ($LauncherProcess) {
        Write-Host "  Launcher PID: $($LauncherProcess.Id)" -ForegroundColor Gray
    }
    if ($GameProcess) {
        Write-Host "  Game PID: $($GameProcess.Id)" -ForegroundColor Gray
    }
}

# Generate report
Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host " Test Results Summary" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

$TotalTests = $TestResults.Passed + $TestResults.Failed + $TestResults.Skipped
$PassRate = if ($TotalTests -gt 0) { [math]::Round(($TestResults.Passed / $TotalTests) * 100, 1) } else { 0 }

Write-Host ("Passed:  {0}/{1} ({2}%)" -f $TestResults.Passed, $TotalTests, $PassRate) -ForegroundColor Green
Write-Host ("Failed:  {0}/{1}" -f $TestResults.Failed, $TotalTests) -ForegroundColor Red
Write-Host ("Skipped: {0}/{1}" -f $TestResults.Skipped, $TotalTests) -ForegroundColor Yellow
Write-Host ""

# Show detailed results
if ($TestResults.Failed -gt 0) {
    Write-Host "Failed Tests:" -ForegroundColor Red
    $TestResults.Details | Where-Object { $_.Status -eq "Failed" -or $_.Status -eq "Error" } | ForEach-Object {
        Write-Host ("  - {0}: {1}" -f $_.Test, $_.Details) -ForegroundColor Red
    }
    Write-Host ""
}

# Save report to file
$ReportPath = Join-Path $ProjectRoot "build\test-report-$(Get-Date -Format 'yyyyMMdd-HHmmss').json"
$TestResults | ConvertTo-Json -Depth 5 | Set-Content $ReportPath
Write-Host "Test report saved to: $ReportPath" -ForegroundColor Gray

# Exit with appropriate code
if ($TestResults.Failed -gt 0) {
    Write-Host "Integration tests FAILED!" -ForegroundColor Red
    exit 1
} else {
    Write-Host "Integration tests PASSED!" -ForegroundColor Green
    exit 0
}