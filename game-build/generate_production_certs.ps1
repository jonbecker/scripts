# PowerShell script to generate production PKI certificates
# Usage: .\scripts\generate_production_certs.ps1 -ServerIP "203.0.113.45"

param(
    [Parameter(Mandatory=$true)]
    [string]$ServerIP
)

# Get the project root directory (parent of scripts/)
$SCRIPT_DIR = Split-Path -Parent $MyInvocation.MyCommand.Path
$PROJECT_ROOT = Split-Path -Parent $SCRIPT_DIR
$OUTPUT_DIR = Join-Path $PROJECT_ROOT "deployment\certs"
$VALIDITY_DAYS = 365

Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "Generating Production PKI Certificates" -ForegroundColor Cyan
Write-Host "Server IP: $ServerIP" -ForegroundColor Cyan
Write-Host "Validity: $VALIDITY_DAYS days" -ForegroundColor Cyan
Write-Host "Output: $OUTPUT_DIR\" -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan

# Detect OpenSSL (check common locations)
$opensslPaths = @(
    "C:\Program Files\Git\usr\bin\openssl.exe",
    "C:\Program Files\Git\mingw64\bin\openssl.exe",
    "C:\Program Files (x86)\Git\usr\bin\openssl.exe",
    "openssl.exe"  # Try PATH last
)

$opensslCmd = $null
foreach ($path in $opensslPaths) {
    if ($path -eq "openssl.exe") {
        # Test if openssl is in PATH
        try {
            $null = Get-Command openssl -ErrorAction Stop
            $opensslCmd = "openssl"
            break
        } catch {
            continue
        }
    } elseif (Test-Path $path) {
        $opensslCmd = $path  # Don't quote - PowerShell's & operator handles spaces
        break
    }
}

if ($null -eq $opensslCmd) {
    Write-Host ""
    Write-Host "ERROR: OpenSSL not found!" -ForegroundColor Red
    Write-Host ""
    Write-Host "Please install one of:" -ForegroundColor Yellow
    Write-Host "  1. Git for Windows (includes OpenSSL): https://git-scm.com/download/win"
    Write-Host "  2. OpenSSL for Windows: https://slproweb.com/products/Win32OpenSSL.html"
    Write-Host ""
    Write-Host "Or add OpenSSL to your PATH temporarily:" -ForegroundColor Yellow
    Write-Host '  $env:PATH += ";C:\Program Files\Git\usr\bin"' -ForegroundColor Cyan
    exit 1
}

Write-Host ""
Write-Host "Using OpenSSL: $opensslCmd" -ForegroundColor Green

# Create output directory structure
New-Item -ItemType Directory -Force -Path "$OUTPUT_DIR\ca" | Out-Null
New-Item -ItemType Directory -Force -Path "$OUTPUT_DIR\game_server" | Out-Null
New-Item -ItemType Directory -Force -Path "$OUTPUT_DIR\global_server" | Out-Null

# Step 1: Generate Root CA
Write-Host ""
Write-Host "[1/4] Generating Root CA..." -ForegroundColor Yellow
& $opensslCmd genrsa -out "$OUTPUT_DIR\ca\root_ca.key" 4096

& $opensslCmd req -x509 -new -nodes `
    -key "$OUTPUT_DIR\ca\root_ca.key" `
    -sha256 -days $VALIDITY_DAYS `
    -out "$OUTPUT_DIR\ca\root_ca.crt" `
    -subj "/C=US/ST=State/L=City/O=ProjectRTS/CN=Project RTS Production CA"

Write-Host "✅ Root CA generated" -ForegroundColor Green

# Step 2: Generate Game Server Certificates
Write-Host ""
Write-Host "[2/4] Generating Game Server certificates..." -ForegroundColor Yellow

# Server certificate (for TLS on port 8080)
& $opensslCmd genrsa -out "$OUTPUT_DIR\game_server\server.key" 4096

& $opensslCmd req -new `
    -key "$OUTPUT_DIR\game_server\server.key" `
    -out "$OUTPUT_DIR\game_server\server.csr" `
    -subj "/C=US/ST=State/L=City/O=ProjectRTS/CN=$ServerIP"

# Create SAN config for server IP
@"
[req]
distinguished_name = req_distinguished_name
req_extensions = v3_req

[req_distinguished_name]

[v3_req]
subjectAltName = @alt_names

[alt_names]
IP.1 = $ServerIP
DNS.1 = localhost
"@ | Out-File -FilePath "$OUTPUT_DIR\game_server\server_san.cnf" -Encoding ASCII

& $opensslCmd x509 -req `
    -in "$OUTPUT_DIR\game_server\server.csr" `
    -CA "$OUTPUT_DIR\ca\root_ca.crt" `
    -CAkey "$OUTPUT_DIR\ca\root_ca.key" `
    -CAcreateserial `
    -out "$OUTPUT_DIR\game_server\server.crt" `
    -days $VALIDITY_DAYS `
    -sha256 `
    -extensions v3_req `
    -extfile "$OUTPUT_DIR\game_server\server_san.cnf"

# Create PKCS12 bundle (no password)
& $opensslCmd pkcs12 -export `
    -out "$OUTPUT_DIR\game_server\server.p12" `
    -inkey "$OUTPUT_DIR\game_server\server.key" `
    -in "$OUTPUT_DIR\game_server\server.crt" `
    -passout pass:

# Client certificate (for mTLS to global_server)
& $opensslCmd genrsa -out "$OUTPUT_DIR\game_server\client.key" 4096

& $opensslCmd req -new `
    -key "$OUTPUT_DIR\game_server\client.key" `
    -out "$OUTPUT_DIR\game_server\client.csr" `
    -subj "/C=US/ST=State/L=City/O=ProjectRTS/CN=game_server_client"

& $opensslCmd x509 -req `
    -in "$OUTPUT_DIR\game_server\client.csr" `
    -CA "$OUTPUT_DIR\ca\root_ca.crt" `
    -CAkey "$OUTPUT_DIR\ca\root_ca.key" `
    -CAcreateserial `
    -out "$OUTPUT_DIR\game_server\client.crt" `
    -days $VALIDITY_DAYS `
    -sha256

& $opensslCmd pkcs12 -export `
    -out "$OUTPUT_DIR\game_server\client.p12" `
    -inkey "$OUTPUT_DIR\game_server\client.key" `
    -in "$OUTPUT_DIR\game_server\client.crt" `
    -passout pass:

Write-Host "✅ Game Server certificates generated" -ForegroundColor Green

# Step 3: Generate Global Server Certificates
Write-Host ""
Write-Host "[3/4] Generating Global Server certificates..." -ForegroundColor Yellow

& $opensslCmd genrsa -out "$OUTPUT_DIR\global_server\server.key" 4096

& $opensslCmd req -new `
    -key "$OUTPUT_DIR\global_server\server.key" `
    -out "$OUTPUT_DIR\global_server\server.csr" `
    -subj "/C=US/ST=State/L=City/O=ProjectRTS/CN=global_server"

# SAN config for localhost (global_server is internal only)
@"
[req]
distinguished_name = req_distinguished_name
req_extensions = v3_req

[req_distinguished_name]

[v3_req]
subjectAltName = @alt_names

[alt_names]
DNS.1 = localhost
IP.1 = 127.0.0.1
"@ | Out-File -FilePath "$OUTPUT_DIR\global_server\server_san.cnf" -Encoding ASCII

& $opensslCmd x509 -req `
    -in "$OUTPUT_DIR\global_server\server.csr" `
    -CA "$OUTPUT_DIR\ca\root_ca.crt" `
    -CAkey "$OUTPUT_DIR\ca\root_ca.key" `
    -CAcreateserial `
    -out "$OUTPUT_DIR\global_server\server.crt" `
    -days $VALIDITY_DAYS `
    -sha256 `
    -extensions v3_req `
    -extfile "$OUTPUT_DIR\global_server\server_san.cnf"

& $opensslCmd pkcs12 -export `
    -out "$OUTPUT_DIR\global_server\server.p12" `
    -inkey "$OUTPUT_DIR\global_server\server.key" `
    -in "$OUTPUT_DIR\global_server\server.crt" `
    -passout pass:

Write-Host "✅ Global Server certificates generated" -ForegroundColor Green

# Step 4: Cleanup temporary files
Write-Host ""
Write-Host "[4/4] Cleaning up..." -ForegroundColor Yellow
Remove-Item "$OUTPUT_DIR\**\*.csr" -Force
Remove-Item "$OUTPUT_DIR\**\*.cnf" -Force
Remove-Item "$OUTPUT_DIR\ca\*.srl" -Force -ErrorAction SilentlyContinue

Write-Host ""
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "✅ Production certificates generated!" -ForegroundColor Green
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Certificate details:"
Write-Host "  CA: $OUTPUT_DIR\ca\root_ca.crt"
Write-Host "  Game Server: $ServerIP"
Write-Host "  Global Server: localhost (internal)"
Write-Host "  Validity: $VALIDITY_DAYS days"
Write-Host ""
Write-Host "Certificates (.crt) are safe to commit — they are public." -ForegroundColor Green
Write-Host "NEVER commit private keys (.key, .p12) to git!" -ForegroundColor Red
Write-Host "  Add '$OUTPUT_DIR\**\*.key' and '$OUTPUT_DIR\**\*.p12' to your .gitignore."
Write-Host ""
Write-Host "Next steps:"
Write-Host "  1. git add $OUTPUT_DIR\**\*.crt"
Write-Host "  2. git commit -m 'chore: Add production certificates for $ServerIP'"
Write-Host "  3. git push origin main"
Write-Host ""
Write-Host "Clients connecting via TLS must install: $OUTPUT_DIR\ca\root_ca.crt" -ForegroundColor Yellow
Write-Host "==========================================" -ForegroundColor Cyan
