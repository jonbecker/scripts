# Plan 55: Automated Latency Test Pipeline
# latency-test.ps1 - PowerShell script to run latency tests locally
#
# Usage:
#   .\latency-test.ps1 [-Iterations 100] [-SkipServer] [-SkipClient] [-ReportOnly]
#
# Parameters:
#   -Iterations    Number of test iterations (default: 100)
#   -SkipServer    Skip starting the game server (assumes already running)
#   -SkipClient    Skip starting the UE5 client (assumes already running)
#   -ReportOnly    Only analyze existing reports in Saved/LatencyTests/

param(
    [int]$Iterations = 100,
    [switch]$SkipServer,
    [switch]$SkipClient,
    [switch]$ReportOnly,
    [string]$ServerConfig = "config/server_config.ron"
)

$ErrorActionPreference = "Stop"
$ProjectRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)

Write-Host "=== Plan 55: Automated Latency Test Pipeline ===" -ForegroundColor Cyan
Write-Host "Project Root: $ProjectRoot"
Write-Host "Iterations: $Iterations"

# Paths - Use standalone game exe, not UE5 editor (matches launcher behavior)
$GameServerPath = Join-Path $ProjectRoot "target\release\game_server.exe"

# Game client paths (same as launcher/src-tauri/src/main.rs)
$DevGamePath = Join-Path $ProjectRoot "ue5_client\RTSGame\Binaries\Win64\RTSGame.exe"
$PackagedGamePath = Join-Path $ProjectRoot "ue5_client\RTSGame\Packaged\Windows\RTSGame\Binaries\Win64\RTSGame.exe"

# Determine which game exe to use
$GameClientPath = $null
if (Test-Path $DevGamePath) {
    $GameClientPath = $DevGamePath
    Write-Host "Found development build: $GameClientPath" -ForegroundColor Green
} elseif (Test-Path $PackagedGamePath) {
    $GameClientPath = $PackagedGamePath
    Write-Host "Found packaged build: $GameClientPath" -ForegroundColor Green
} else {
    Write-Host "WARNING: Game client not found at:" -ForegroundColor Yellow
    Write-Host "  Dev: $DevGamePath" -ForegroundColor Yellow
    Write-Host "  Packaged: $PackagedGamePath" -ForegroundColor Yellow
}

# Report directories - dev build and cooked/packaged build use different paths
$ReportDirDev = Join-Path $ProjectRoot "ue5_client\RTSGame\Saved\LatencyTests"
$ReportDirCooked = Join-Path $ProjectRoot "ue5_client\RTSGame\Saved\Cooked\Windows\RTSGame\Saved\LatencyTests"
$ReportDirs = @($ReportDirDev, $ReportDirCooked)

# Create report directories if they don't exist
foreach ($dir in $ReportDirs) {
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
}

function Start-GameServer {
    Write-Host "`n--- Starting Game Server ---" -ForegroundColor Yellow

    if (-not (Test-Path $GameServerPath)) {
        Write-Host "Building game server..." -ForegroundColor Gray
        Push-Location $ProjectRoot
        & cargo build --release --bin game_server
        Pop-Location
    }

    Write-Host "Starting game_server.exe..." -ForegroundColor Gray
    $script:ServerProcess = Start-Process -FilePath $GameServerPath `
        -WorkingDirectory $ProjectRoot `
        -PassThru `
        -WindowStyle Normal

    # Wait for server to start
    Write-Host "Waiting for server to initialize..." -ForegroundColor Gray
    Start-Sleep -Seconds 3

    return $script:ServerProcess
}

function Start-UE5Client {
    Write-Host "`n--- Starting Game Client ---" -ForegroundColor Yellow

    if (-not $GameClientPath -or -not (Test-Path $GameClientPath)) {
        Write-Host "ERROR: Game client not found!" -ForegroundColor Red
        Write-Host "Please compile the UE5 game first." -ForegroundColor Red
        return $null
    }

    # Get working directory (UE5 project root for dev builds)
    $GameWorkingDir = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $GameClientPath))

    # Launch arguments matching launcher behavior
    # Using insecure port 48216 with -InsecureWS flag (no TLS for local testing)
    # NOTE: These are hardcoded LOCAL DEV/TEST credentials only — not used in production
    $GameArgs = @(
        "-windowed",
        "-log",
        "-ResX=1280",
        "-ResY=720",
        "-Username=test_user",
        "-Password=password",
        "-WSServerAddress=127.0.0.1:48216",
        "-InsecureWS",
        "-GameId=test_game_pie",
        "-LaunchedFromLauncher",
        "-RunLatencyTest=$Iterations"
    )

    Write-Host "Starting game client..." -ForegroundColor Gray
    Write-Host "  Exe: $GameClientPath" -ForegroundColor Gray
    Write-Host "  WorkDir: $GameWorkingDir" -ForegroundColor Gray

    $script:ClientProcess = Start-Process -FilePath $GameClientPath `
        -ArgumentList ($GameArgs -join " ") `
        -WorkingDirectory $GameWorkingDir `
        -PassThru `
        -WindowStyle Normal

    # Wait for client to connect
    Write-Host "Waiting for client to connect to server..." -ForegroundColor Gray
    Start-Sleep -Seconds 10

    return $script:ClientProcess
}

function Wait-ForTestCompletion {
    param([int]$MaxWaitSeconds = 300)

    Write-Host "`n--- Waiting for Test Completion ---" -ForegroundColor Yellow
    Write-Host "Monitoring report directories for new reports:" -ForegroundColor Gray
    foreach ($dir in $ReportDirs) {
        Write-Host "  - $dir" -ForegroundColor Gray
    }

    $startTime = Get-Date

    # Count initial reports across all directories
    $initialCount = 0
    foreach ($dir in $ReportDirs) {
        $reports = Get-ChildItem -Path $dir -Filter "latency_report_*.json" -ErrorAction SilentlyContinue
        if ($reports) { $initialCount += $reports.Count }
    }

    while ((Get-Date) - $startTime -lt [TimeSpan]::FromSeconds($MaxWaitSeconds)) {
        Start-Sleep -Seconds 5

        # Check all directories for new reports
        $currentCount = 0
        $allReports = @()
        foreach ($dir in $ReportDirs) {
            $reports = Get-ChildItem -Path $dir -Filter "latency_report_*.json" -ErrorAction SilentlyContinue
            if ($reports) {
                $currentCount += $reports.Count
                $allReports += $reports
            }
        }

        if ($currentCount -gt $initialCount) {
            Write-Host "New report detected!" -ForegroundColor Green
            return $allReports | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        }

        $elapsed = (Get-Date) - $startTime
        Write-Host "  Waiting... ($([math]::Round($elapsed.TotalSeconds))s elapsed)" -ForegroundColor Gray
    }

    Write-Host "Timeout waiting for test completion" -ForegroundColor Red
    return $null
}

function Analyze-LatencyReport {
    param([string]$ReportPath)

    Write-Host "`n--- Analyzing Latency Report ---" -ForegroundColor Yellow
    Write-Host "Report: $ReportPath"

    $report = Get-Content $ReportPath | ConvertFrom-Json

    Write-Host "`n=== LATENCY TEST SUMMARY ===" -ForegroundColor Cyan
    Write-Host "Timestamp: $($report.metadata.timestamp)"
    Write-Host "Samples: $($report.metadata.sample_count)"

    Write-Host "`n--- Total Round Trip ---" -ForegroundColor Yellow
    Write-Host "  Min:  $($report.total_round_trip_ms.min) ms"
    Write-Host "  Max:  $($report.total_round_trip_ms.max) ms"
    Write-Host "  Mean: $([math]::Round($report.total_round_trip_ms.mean, 2)) ms"
    Write-Host "  P50:  $($report.total_round_trip_ms.p50) ms"
    Write-Host "  P95:  $($report.total_round_trip_ms.p95) ms"
    Write-Host "  P99:  $($report.total_round_trip_ms.p99) ms"

    # Network RTT (clock-skew-immune)
    if ($report.network_rtt_ms) {
        Write-Host "`n--- Network RTT (clock-skew-immune) ---" -ForegroundColor Yellow
        Write-Host "  P50:  $($report.network_rtt_ms.p50) ms"
        Write-Host "  P95:  $($report.network_rtt_ms.p95) ms"
        Write-Host "  (True one-way latency: ~$([math]::Round($report.network_rtt_ms.p50 / 2, 1)) ms)" -ForegroundColor Gray
    }

    Write-Host "`n--- Breakdown (P50) ---" -ForegroundColor Yellow
    Write-Host "  Client Send:      $($report.client_send_ms.p50) ms"
    Write-Host "  Network Uplink:   $($report.network_uplink_ms.p50) ms"
    Write-Host "  Server Total:     $($report.server_total_ms.p50) ms"
    Write-Host "  Network Downlink: $($report.network_downlink_ms.p50) ms"
    if ($report.client_queue_wait_ms) {
        Write-Host "  Client Queue Wait:$($report.client_queue_wait_ms.p50) ms"
    }
    Write-Host "  Client Apply:     $($report.client_apply_ms.p50) ms"

    # Performance assessment
    Write-Host "`n--- Performance Assessment ---" -ForegroundColor Yellow
    $p95 = $report.total_round_trip_ms.p95
    if ($p95 -le 16) {
        Write-Host "  EXCELLENT: P95 <= 16ms (sub-frame latency at 60fps)" -ForegroundColor Green
    } elseif ($p95 -le 33) {
        Write-Host "  GOOD: P95 <= 33ms (within 2 frames at 60fps)" -ForegroundColor Green
    } elseif ($p95 -le 50) {
        Write-Host "  ACCEPTABLE: P95 <= 50ms (within 3 frames at 60fps)" -ForegroundColor Yellow
    } else {
        Write-Host "  NEEDS IMPROVEMENT: P95 > 50ms (noticeable lag)" -ForegroundColor Red
    }

    # Identify bottlenecks
    Write-Host "`n--- Bottleneck Analysis ---" -ForegroundColor Yellow
    $breakdown = @{
        "Client Send" = $report.client_send_ms.p50
        "Network Uplink" = $report.network_uplink_ms.p50
        "Server Processing" = $report.server_total_ms.p50
        "Network Downlink" = $report.network_downlink_ms.p50
    }
    if ($report.client_queue_wait_ms) {
        $breakdown["Client Queue Wait"] = $report.client_queue_wait_ms.p50
    }
    $breakdown["Client Apply"] = $report.client_apply_ms.p50

    $sorted = $breakdown.GetEnumerator() | Sort-Object Value -Descending
    Write-Host "  Largest contributors (P50):"
    foreach ($item in $sorted) {
        $pct = [math]::Round(($item.Value / $report.total_round_trip_ms.p50) * 100, 1)
        Write-Host "    $($item.Key): $($item.Value) ms ($pct%)"
    }

    return $report
}

function Show-AllReports {
    Write-Host "`n--- Available Reports ---" -ForegroundColor Yellow

    # Collect reports from all directories
    $allReports = @()
    foreach ($dir in $ReportDirs) {
        $reports = Get-ChildItem -Path $dir -Filter "latency_report_*.json" -ErrorAction SilentlyContinue
        if ($reports) { $allReports += $reports }
    }

    if (-not $allReports -or $allReports.Count -eq 0) {
        Write-Host "No reports found in any monitored directory" -ForegroundColor Gray
        return
    }

    $allReports | Sort-Object LastWriteTime -Descending | ForEach-Object {
        Write-Host "  $($_.Name) - $($_.LastWriteTime)"
    }

    # Analyze the most recent report
    $latestReport = $allReports | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    Analyze-LatencyReport -ReportPath $latestReport.FullName
}

# Main execution
try {
    if ($ReportOnly) {
        Show-AllReports
        exit 0
    }

    $serverProcess = $null
    $clientProcess = $null

    # Start server if needed
    if (-not $SkipServer) {
        $serverProcess = Start-GameServer
    } else {
        Write-Host "Skipping server start (assuming already running)" -ForegroundColor Gray
    }

    # Start client if needed
    if (-not $SkipClient) {
        $clientProcess = Start-UE5Client
    } else {
        Write-Host "Skipping client start (assuming already running)" -ForegroundColor Gray
    }

    # Provide instructions for manual test trigger
    Write-Host "`n=== INSTRUCTIONS ===" -ForegroundColor Cyan
    Write-Host "1. In the UE5 client, press ~ to open the console"
    Write-Host "2. Type: RunLatencyTest $Iterations"
    Write-Host "3. Wait for the test to complete"
    Write-Host ""
    Write-Host "Or use the automated approach:"
    Write-Host "  The test will auto-detect when a new report is generated."

    # Wait for test completion
    $newReport = Wait-ForTestCompletion -MaxWaitSeconds 300

    if ($newReport) {
        Analyze-LatencyReport -ReportPath $newReport.FullName
    }

} finally {
    Write-Host "`n--- Cleanup ---" -ForegroundColor Yellow

    # Optionally stop processes
    if ($serverProcess -and -not $SkipServer) {
        Write-Host "Server process still running (PID: $($serverProcess.Id))"
        Write-Host "To stop manually: Stop-Process -Id $($serverProcess.Id)"
    }

    if ($clientProcess -and -not $SkipClient) {
        Write-Host "Client process still running (PID: $($clientProcess.Id))"
        Write-Host "To stop manually: Stop-Process -Id $($clientProcess.Id)"
    }
}

Write-Host "`n=== Latency Test Complete ===" -ForegroundColor Cyan
