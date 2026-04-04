# Game Build Scripts

PowerShell and Bash scripts for building, testing, packaging, and deploying the game (Launcher + UE5 Client + Server infrastructure).

## Prerequisites

### Windows (Build & Test)

- **Windows 11** (or Windows 10 20H2+)
- **PowerShell 5.1+** (or PowerShell Core 7+)
- **Unreal Engine 5.6+** installed
- **Visual Studio 2022+** with C++ workload
- **Node.js 20+** and npm
- **Rust 1.75+** (install from https://rustup.rs/)
- **Git** for version control

Optional:
- **WiX Toolset 3.11** or **Inno Setup 6** (for installer creation)
- **Windows SDK** with signtool (for code signing)
- **7-Zip** (for better compression)
- **OpenSSL** (for certificate generation on Windows; bundled with Git for Windows)

### Linux (Server Provisioning)

- **Ubuntu 22.04** or **Debian 12**
- **OpenSSL** (for certificate generation)
- **PostgreSQL 15** (installed by `setup_postgres_debian.sh`)
- **curl**, **jq**, **git**, **build-essential**

## Scripts Overview

### Build Scripts

#### `build-launcher.ps1`
Builds the Tauri-based launcher application.

```powershell
.\game-build\build-launcher.ps1 -Configuration Release -Clean -Bundle
```

| Parameter | Description | Default |
|---|---|---|
| `-Configuration` | `Debug` or `Release` | `Release` |
| `-OutputPath` | Output directory | `build\launcher_output` |
| `-Clean` | Clean previous build | - |
| `-SkipTypeScript` | Skip TypeScript compilation | - |
| `-Bundle` | Create installer bundles (MSI/NSIS) | - |

#### `build-launcher-signed.ps1`
Builds the launcher with Tauri updater signing and optional version bumping.

```powershell
.\game-build\build-launcher-signed.ps1 -KeyPassword "<your-key-password>" -Bump patch
```

| Parameter | Description | Default |
|---|---|---|
| `-KeyPassword` | **(Required)** Signing key password | - |
| `-KeyFile` | Path to Tauri updater signing key | `<project>\keys\tauri-updater.key` |
| `-Bump` | Version bump type: `major`, `minor`, `patch` | - |
| `-Version` | Explicit version override (e.g., `"1.2.3"`) | - |

#### `build-ue5.ps1`
Builds the Unreal Engine 5 game client.

```powershell
.\game-build\build-ue5.ps1 -Configuration Shipping -Cook -Package
```

| Parameter | Description | Default |
|---|---|---|
| `-Configuration` | `Development`, `Shipping`, or `Debug` | `Shipping` |
| `-Platform` | `Win64` or `Win32` | `Win64` |
| `-UE5Path` | Path to UE5 installation | `C:\Program Files\Epic Games\UE_5.6` |
| `-OutputPath` | Output directory | `build\ue5_output` |
| `-Clean` | Clean previous build | - |
| `-Cook` | Cook game content | - |
| `-Package` | Create packaged build | - |

#### `build-shared-simulation.ps1`
Builds the Rust `shared_simulation` crate as a cdylib (DLL) and copies it + the C header into the UE5 project.

```powershell
.\game-build\build-shared-simulation.ps1 -Release
```

| Parameter | Description | Default |
|---|---|---|
| `-Release` | Build in release mode | debug |
| `-SkipCopy` | Skip copying DLL/header to UE5 project | - |

#### `build-full-release.ps1`
Orchestrates a complete release build: launcher + UE5 client + packaging + optional signing and installer.

```powershell
.\game-build\build-full-release.ps1 `
    -Version "1.2.0" `
    -Configuration Shipping `
    -Clean `
    -SignBinaries `
    -CertificatePath ".\cert.pfx" `
    -CertificatePassword "<your-cert-password>" `
    -CreateInstaller
```

| Parameter | Description | Default |
|---|---|---|
| `-Version` | Release version number | `1.0.0` |
| `-Configuration` | `Development` or `Shipping` | `Shipping` |
| `-UE5Path` | Path to UE5 installation | `C:\Program Files\Epic Games\UE_5.6` |
| `-OutputPath` | Output directory | `build\release` |
| `-Clean` | Clean all previous builds | - |
| `-SignBinaries` | Sign executables with code certificate | - |
| `-CertificatePath` | Path to `.pfx` code signing certificate | - |
| `-CertificatePassword` | Certificate password | - |
| `-CreateInstaller` | Generate installer (MSI or Inno Setup) | - |

#### `package-ue5-game.ps1`
Packages the UE5 game for distribution using RunUAT. Builds the shared simulation DLL first, then runs the full cook/package pipeline.

```powershell
.\game-build\package-ue5-game.ps1 -BuildConfig Shipping
```

| Parameter | Description | Default |
|---|---|---|
| `-UE5Path` | Path to UE5 installation | `$env:UE5_PATH` or `D:\UE_5.7` |
| `-ProjectPath` | Path to `.uproject` directory | `<project>\ue5_client\RTSGame` |
| `-OutputPath` | Intermediate output directory | `<project>\build\RTSGame_Package` |
| `-BuildConfig` | `Shipping` (distribution) or `Development` (testing) | `Shipping` |

### Version Management

#### `bump-launcher-version.ps1`
Bumps the launcher version consistently across `package.json`, `tauri.conf.json`, `Cargo.toml`, and `package-lock.json`.

```powershell
.\game-build\bump-launcher-version.ps1 -Bump patch     # 0.3.5 -> 0.3.6
.\game-build\bump-launcher-version.ps1 -Version "1.2.3" # explicit
```

| Parameter | Description |
|---|---|
| `-Bump` | `major`, `minor`, or `patch` |
| `-Version` | Explicit version string (e.g., `"1.2.3"`) |

### Testing

#### `test-integration.ps1`
Integration test suite covering file existence, signatures, launcher startup, memory usage, WebSocket connectivity, game launch, and stability.

```powershell
.\game-build\test-integration.ps1 -TestMode Full
```

| Parameter | Description | Default |
|---|---|---|
| `-TestMode` | `Quick`, `Full`, or `Smoke` | `Full` |
| `-LauncherPath` | Path to launcher executable | `build\release\RTSGame.exe` |
| `-GamePath` | Path to game executable | `build\release\game\RTSGame.exe` |
| `-TestServerUrl` | WebSocket server URL | `ws://localhost:3000` |
| `-KeepRunning` | Keep processes running after tests | - |

Outputs a JSON test report to `build/test-report-<timestamp>.json`.

#### `latency-test.ps1`
Automated latency testing pipeline. Starts game server + UE5 client, runs latency measurements, and provides detailed P50/P95/P99 breakdown with bottleneck analysis.

```powershell
.\game-build\latency-test.ps1 -Iterations 100
.\game-build\latency-test.ps1 -ReportOnly   # analyze existing reports
```

| Parameter | Description | Default |
|---|---|---|
| `-Iterations` | Number of test iterations | `100` |
| `-SkipServer` | Assume game server already running | - |
| `-SkipClient` | Assume UE5 client already running | - |
| `-ReportOnly` | Only analyze existing reports | - |
| `-ServerConfig` | Server config file path | `config/server_config.ron` |

### Server Provisioning (Linux)

#### `bootstrap_server.sh`
Fully automated server provisioning for a fresh Ubuntu 22.04 install. Sets up: system packages, dedicated user, Rust toolchain, GitHub Actions runner, systemd services, firewall (UFW), log rotation, monitoring/backup cron jobs, production TLS certificates, download server + nginx.

```bash
export GITHUB_TOKEN="ghp_..."
export GITHUB_REPO="owner/repo"
export SERVER_IP="203.0.113.45"  # optional, auto-detected if omitted
sudo bash bootstrap_server.sh
```

| Env Variable | Description | Required |
|---|---|---|
| `GITHUB_TOKEN` | Personal Access Token with `repo` scope | Yes |
| `GITHUB_REPO` | Repository in `owner/repo` format | Yes |
| `SERVER_IP` | Public IP (auto-detected if not set) | No |

#### `setup_postgres_debian.sh`
PostgreSQL 15 setup for Debian 12. Creates database, user, initializes schema, generates `.env` files with credentials.

```bash
sudo ./setup_postgres_debian.sh
```

Prompts for a custom database password (or auto-generates one). Credentials are written to `/opt/rts_game/.env` and `./global_server.env`.

### Certificate Generation

#### `generate_production_certs.ps1` (Windows)
#### `generate_production_certs.sh` (Linux)

Generate a full PKI certificate bundle (Root CA + game server + global server certificates) for TLS and mTLS.

```powershell
# Windows
.\game-build\generate_production_certs.ps1 -ServerIP "203.0.113.45"

# Linux
./game-build/generate_production_certs.sh 203.0.113.45
```

Output: `deployment/certs/{ca,game_server,global_server}/` with 365-day validity.

Certificates (`.crt`) are public and safe to commit for easy distribution. **Never commit private keys (`.key`, `.p12`) to git.** Add `deployment/certs/**/*.key` and `deployment/certs/**/*.p12` to `.gitignore`.

## Build Dependency Graph

```
build-full-release.ps1
  +-- build-launcher.ps1
  +-- build-ue5.ps1
  \-- cargo build (download_server)

build-launcher-signed.ps1
  +-- bump-launcher-version.ps1
  \-- build-launcher.ps1

package-ue5-game.ps1
  \-- build-shared-simulation.ps1
```

## Quick Start

### Development Build

```powershell
# 1. Build shared simulation DLL
.\game-build\build-shared-simulation.ps1

# 2. Build launcher (debug)
.\game-build\build-launcher.ps1 -Configuration Debug

# 3. Build UE5 client (development)
.\game-build\build-ue5.ps1 -Configuration Development -Cook

# 4. Run integration tests
.\game-build\test-integration.ps1 -TestMode Quick
```

### Release Build

```powershell
.\game-build\build-full-release.ps1 `
    -Version "1.0.0" `
    -Configuration Shipping `
    -Clean `
    -CreateInstaller
```

## Troubleshooting

| Issue | Solution |
|---|---|
| "Unreal Engine 5 not found" | Verify UE5 path, pass correct path via `-UE5Path` |
| "Node.js is not installed" | Install Node.js 20+ from https://nodejs.org/, restart PowerShell |
| "Rust is not installed" | Install from https://rustup.rs/, run `rustup default stable-msvc` |
| "Build failed with exit code X" | Check error output, try `-Clean` flag, check disk space |
| "Cannot sign binaries" | Install Windows SDK with signtool, check certificate is valid `.pfx` |
| "Access denied" errors | Run PowerShell as Administrator, check no files are locked |

### Required Disk Space

| Component | Size |
|---|---|
| Source Code | ~2 GB |
| Launcher Build | ~500 MB |
| UE5 Development Build | ~5 GB |
| UE5 Shipping Build | ~3 GB |
| Full Release Package | ~1 GB |
| **Total Recommended** | **15 GB free** |

## Script Exit Codes

| Code | Meaning |
|---|---|
| `0` | Success |
| `1` | General failure |
| `2` | Missing prerequisites |
| `3` | Build failure |
| `4` | Test failure |
| `5` | Packaging failure |

## Environment Variables

| Variable | Description |
|---|---|
| `UE5_PATH` | Override UE5 installation path |
| `BUILD_OUTPUT` | Override default output directory |
| `SKIP_TESTS` | Skip test execution |
| `VERBOSE` | Enable verbose logging |
| `CI` | Optimize for CI environment |

---

Last Updated: April 2026
