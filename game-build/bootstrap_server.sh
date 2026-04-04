#!/bin/bash
set -euo pipefail

###############################################################################
# RTS Game Server Bootstrap Script
# Purpose: Fully automated server provisioning from fresh Ubuntu 22.04 install
# Usage:
#   1. Copy this script to fresh server: scp bootstrap_server.sh user@server:/tmp/
#   2. SSH into server: ssh user@server
#   3. Run with sudo: sudo bash /tmp/bootstrap_server.sh
#
# Required environment variables:
#   GITHUB_TOKEN - Personal Access Token for runner registration
#   GITHUB_REPO  - Repository in format "owner/repo" (e.g., "username/project_rts_infra")
#   SERVER_IP    - Public IP address of this server (for certificates)
###############################################################################

# Color output for better readability
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Warn on failure
cleanup() {
    local rc=$?
    if [ $rc -ne 0 ]; then
        log_warn "Bootstrap interrupted (exit $rc) — review partial state before re-running"
    fi
}
trap cleanup EXIT

# Validate required environment variables
if [ -z "${GITHUB_TOKEN:-}" ]; then
    log_error "GITHUB_TOKEN environment variable not set"
    exit 1
fi

if [ -z "${GITHUB_REPO:-}" ]; then
    log_error "GITHUB_REPO environment variable not set (format: owner/repo)"
    exit 1
fi

if [ -z "${SERVER_IP:-}" ]; then
    log_warn "SERVER_IP not set, will use machine's public IP"
    # Try to detect public IP
    SERVER_IP=$(curl -s ifconfig.me || echo "")
    if [ -z "$SERVER_IP" ]; then
        log_error "Could not detect public IP. Please set SERVER_IP environment variable"
        exit 1
    fi
    log_info "Detected public IP: $SERVER_IP"
fi

log_info "=========================================="
log_info "RTS Game Server Bootstrap"
log_info "Repository: $GITHUB_REPO"
log_info "Server IP: $SERVER_IP"
log_info "=========================================="

# Must run as root
if [ "$EUID" -ne 0 ]; then
    log_error "This script must be run as root (use sudo)"
    exit 1
fi

###############################################################################
# Step 1: System Updates and Package Installation
###############################################################################
log_info "Step 1: Installing system packages..."
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get upgrade -y
DEBIAN_FRONTEND=noninteractive apt-get install -y \
    curl \
    git \
    build-essential \
    pkg-config \
    libssl-dev \
    ufw \
    jq \
    netcat \
    logrotate \
    unattended-upgrades

log_info "System packages installed ✅"

###############################################################################
# Step 2: Create Dedicated User
###############################################################################
log_info "Step 2: Creating github-runner user..."
if id -u github-runner >/dev/null 2>&1; then
    log_warn "User github-runner already exists, skipping creation"
else
    useradd -r -m -d /opt/rts_game -s /bin/bash github-runner
    log_info "User github-runner created ✅"
fi

# Allow github-runner to restart services without password
cat > /etc/sudoers.d/github-runner <<EOF
github-runner ALL=(ALL) NOPASSWD: /bin/systemctl restart rts-game-server.service
github-runner ALL=(ALL) NOPASSWD: /bin/systemctl restart rts-global-server.service
github-runner ALL=(ALL) NOPASSWD: /bin/systemctl status rts-game-server.service
github-runner ALL=(ALL) NOPASSWD: /bin/systemctl status rts-global-server.service
github-runner ALL=(ALL) NOPASSWD: /bin/systemctl daemon-reload
github-runner ALL=(ALL) NOPASSWD: /usr/bin/netstat
EOF
chmod 0440 /etc/sudoers.d/github-runner

###############################################################################
# Step 3: Directory Structure
###############################################################################
log_info "Step 3: Creating directory structure..."
mkdir -p /opt/rts_game/{current,releases,shared/{config,certs,data,logs,backups}}
chown -R github-runner:github-runner /opt/rts_game

###############################################################################
# Step 4: Install Rust (as github-runner user)
###############################################################################
log_info "Step 4: Installing Rust toolchain..."
if [ -f /opt/rts_game/.cargo/bin/rustc ]; then
    log_warn "Rust already installed, skipping"
else
    su - github-runner -c 'curl --proto "=https" --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain stable'
    su - github-runner -c 'source $HOME/.cargo/env && rustup default stable'
    log_info "Rust installed ✅"
fi

# Add Rust to github-runner's PATH permanently
if ! grep -q 'source $HOME/.cargo/env' /opt/rts_game/.bashrc; then
    echo 'source $HOME/.cargo/env' >> /opt/rts_game/.bashrc
fi

###############################################################################
# Step 5: Install GitHub Actions Runner
###############################################################################
log_info "Step 5: Installing GitHub Actions runner..."

RUNNER_VERSION="2.311.0"
RUNNER_SHA256="29fc8cf2dab4c195f108009ca0ee0651064e31b0880bfae1a37c2a58f21e12a8"
RUNNER_DIR="/opt/rts_game/actions-runner"

if [ -d "$RUNNER_DIR" ] && [ -f "$RUNNER_DIR/.runner" ]; then
    log_warn "GitHub runner already configured, skipping installation"
else
    mkdir -p "$RUNNER_DIR"
    cd "$RUNNER_DIR"

    # Download runner
    log_info "Downloading GitHub Actions runner v${RUNNER_VERSION}..."
    curl -o actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz -L \
        "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz"

    # Verify download integrity
    echo "${RUNNER_SHA256}  actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz" | sha256sum -c - || {
        log_error "Checksum verification failed! Download may be corrupted or tampered with."
        exit 1
    }

    tar xzf "actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz"
    chown -R github-runner:github-runner "$RUNNER_DIR"

    # Get registration token from GitHub API
    log_info "Requesting runner registration token from GitHub..."
    REGISTRATION_TOKEN=$(curl -s -X POST \
        -H "Authorization: token ${GITHUB_TOKEN}" \
        -H "Accept: application/vnd.github.v3+json" \
        "https://api.github.com/repos/${GITHUB_REPO}/actions/runners/registration-token" \
        | jq -r .token)

    if [ -z "$REGISTRATION_TOKEN" ] || [ "$REGISTRATION_TOKEN" = "null" ]; then
        log_error "Failed to get registration token from GitHub"
        log_error "Check that GITHUB_TOKEN has 'repo' scope and GITHUB_REPO is correct"
        exit 1
    fi

    # Configure runner (as github-runner user)
    log_info "Configuring GitHub Actions runner..."
    su - github-runner -c "cd ${RUNNER_DIR} && ./config.sh \
        --url https://github.com/${GITHUB_REPO} \
        --token ${REGISTRATION_TOKEN} \
        --name production-server-$(hostname) \
        --work _work \
        --labels production,linux,x64 \
        --unattended \
        --replace"

    # Install as systemd service
    cd "$RUNNER_DIR"
    ./svc.sh install github-runner
    ./svc.sh start

    log_info "GitHub Actions runner installed and started ✅"
fi

###############################################################################
# Step 6: Systemd Service Files
###############################################################################
log_info "Step 6: Creating systemd service files..."

cat > /etc/systemd/system/rts-global-server.service <<'EOF'
[Unit]
Description=RTS Global Management Server
After=network.target

[Service]
Type=simple
User=github-runner
Group=github-runner
WorkingDirectory=/opt/rts_game/current
Environment="RUST_LOG=info"
Environment="RTS_ENV=production"
Environment="RUST_BACKTRACE=1"
ExecStart=/opt/rts_game/current/target/release/global_server
Restart=on-failure
RestartSec=5s
StandardOutput=append:/opt/rts_game/shared/logs/global_server.log
StandardError=append:/opt/rts_game/shared/logs/global_server_error.log

# Security hardening
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/opt/rts_game/shared/logs /opt/rts_game/shared/data

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/rts-game-server.service <<'EOF'
[Unit]
Description=RTS Game Server
After=network.target rts-global-server.service
Requires=rts-global-server.service

[Service]
Type=simple
User=github-runner
Group=github-runner
WorkingDirectory=/opt/rts_game/current
Environment="RUST_LOG=info"
Environment="RTS_ENV=production"
Environment="RUST_BACKTRACE=1"
ExecStart=/opt/rts_game/current/target/release/game_server
Restart=on-failure
RestartSec=5s
StandardOutput=append:/opt/rts_game/shared/logs/game_server.log
StandardError=append:/opt/rts_game/shared/logs/game_server_error.log

# Security hardening
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/opt/rts_game/shared/logs /opt/rts_game/shared/data

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable rts-global-server.service
systemctl enable rts-game-server.service

log_info "Systemd services created and enabled ✅"

###############################################################################
# Step 7: Firewall Configuration
###############################################################################
log_info "Step 7: Configuring firewall..."

# Reset UFW to defaults
ufw --force reset

# Default policies
ufw default deny incoming
ufw default allow outgoing

# SSH (adjust port if needed)
ufw allow 22/tcp comment 'SSH'

# Game server ports
ufw allow 8080/tcp comment 'Game Server TLS'
ufw allow 3000/tcp comment 'Game Server Insecure (temp)'
# Port 9753 NOT exposed (internal only)

# Health check endpoint (optional)
ufw allow 8081/tcp comment 'Health Check'

# Enable UFW
ufw --force enable

log_info "Firewall configured ✅"

###############################################################################
# Step 8: Log Rotation
###############################################################################
log_info "Step 8: Configuring log rotation..."

cat > /etc/logrotate.d/rts-game <<'EOF'
/opt/rts_game/shared/logs/*.log {
    daily
    rotate 7
    compress
    delaycompress
    missingok
    notifempty
    create 0644 github-runner github-runner
    sharedscripts
    postrotate
        systemctl reload rts-game-server.service >/dev/null 2>&1 || true
        systemctl reload rts-global-server.service >/dev/null 2>&1 || true
    endscript
}
EOF

log_info "Log rotation configured ✅"

###############################################################################
# Step 9: Monitoring and Backup Scripts
###############################################################################
log_info "Step 9: Installing monitoring and backup scripts..."

cat > /opt/rts_game/monitor.sh <<'EOFMONITOR'
#!/bin/bash
set -euo pipefail
# Health monitoring script

check_service() {
    SERVICE=$1
    if systemctl is-active --quiet "$SERVICE"; then
        echo "✅ $SERVICE is running"
        return 0
    else
        echo "❌ $SERVICE is DOWN"
        return 1
    fi
}

check_port() {
    PORT=$1
    NAME=$2
    if netstat -tuln | grep -q ":$PORT "; then
        echo "✅ Port $PORT ($NAME) listening"
        return 0
    else
        echo "❌ Port $PORT ($NAME) NOT listening"
        return 1
    fi
}

echo "=== RTS Game Server Health Check ==="
echo "Timestamp: $(date)"
echo ""

HEALTH_OK=true
check_service "rts-global-server.service" || HEALTH_OK=false
check_service "rts-game-server.service" || HEALTH_OK=false
echo ""
check_port 8080 "game_server TLS" || HEALTH_OK=false
check_port 3000 "game_server insecure" || HEALTH_OK=false
check_port 9753 "global_server mTLS" || HEALTH_OK=false
echo ""

DISK_USAGE=$(df -h /opt/rts_game | awk 'NR==2 {print $5}' | sed 's/%//')
echo "Disk usage: ${DISK_USAGE}%"
if [ "$DISK_USAGE" -gt 80 ]; then
    echo "⚠️  Warning: Disk usage above 80%"
    HEALTH_OK=false
fi

echo ""
echo "=== End Health Check ==="

if [ "$HEALTH_OK" = true ]; then
    exit 0
else
    exit 1
fi
EOFMONITOR

cat > /opt/rts_game/backup.sh <<'EOFBACKUP'
#!/bin/bash
set -euo pipefail
# Daily backup script

BACKUP_DIR="/opt/rts_game/shared/backups"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_FILE="${BACKUP_DIR}/data_backup_${TIMESTAMP}.tar.gz"

mkdir -p "${BACKUP_DIR}"

echo "Creating backup: ${BACKUP_FILE}"
tar -czf "${BACKUP_FILE}" \
    /opt/rts_game/shared/data/users \
    /opt/rts_game/shared/data/player_stats \
    /opt/rts_game/shared/data/match_history \
    /opt/rts_game/shared/data/stats_metadata.json 2>/dev/null || true

# Keep only last 7 days of backups
find "${BACKUP_DIR}" -name "data_backup_*.tar.gz" -mtime +7 -delete

echo "Backup complete: ${BACKUP_FILE}"
EOFBACKUP

chmod +x /opt/rts_game/monitor.sh
chmod +x /opt/rts_game/backup.sh
chown github-runner:github-runner /opt/rts_game/*.sh

# Install cron jobs
(crontab -u github-runner -l 2>/dev/null || true; echo "*/5 * * * * /opt/rts_game/monitor.sh >> /opt/rts_game/shared/logs/monitor.log 2>&1") | crontab -u github-runner -
(crontab -u github-runner -l 2>/dev/null || true; echo "0 3 * * * /opt/rts_game/backup.sh >> /opt/rts_game/shared/logs/backup.log 2>&1") | crontab -u github-runner -

log_info "Monitoring and backup scripts installed ✅"

###############################################################################
# Step 10: Generate Production Certificates ON SERVER
###############################################################################
log_info "Step 10: Generating production certificates on server..."

# Install OpenSSL if not already present
if ! command -v openssl &> /dev/null; then
    apt-get install -y openssl
fi

# Generate certificates directly on server (NEVER commit private keys to git!)
# NOTE: This cert generation logic mirrors generate_production_certs.sh —
# keep both in sync when changing certificate parameters.
CERT_DIR="/opt/rts_game/shared/certs"
mkdir -p "${CERT_DIR}"/{ca,game_server,global_server}

log_info "Generating Root CA..."
openssl genrsa -out "${CERT_DIR}/ca/root_ca.key" 4096
openssl req -x509 -new -nodes \
    -key "${CERT_DIR}/ca/root_ca.key" \
    -sha256 -days 365 \
    -out "${CERT_DIR}/ca/root_ca.crt" \
    -subj "/C=US/ST=State/L=City/O=ProjectRTS/CN=Project RTS Production CA"

log_info "Generating Game Server certificates..."
openssl genrsa -out "${CERT_DIR}/game_server/server.key" 4096
openssl req -new \
    -key "${CERT_DIR}/game_server/server.key" \
    -out "${CERT_DIR}/game_server/server.csr" \
    -subj "/C=US/ST=State/L=City/O=ProjectRTS/CN=${SERVER_IP}"

cat > "${CERT_DIR}/game_server/server_san.cnf" <<EOF
[req]
distinguished_name = req_distinguished_name
req_extensions = v3_req

[req_distinguished_name]

[v3_req]
subjectAltName = @alt_names

[alt_names]
IP.1 = ${SERVER_IP}
DNS.1 = localhost
EOF

openssl x509 -req \
    -in "${CERT_DIR}/game_server/server.csr" \
    -CA "${CERT_DIR}/ca/root_ca.crt" \
    -CAkey "${CERT_DIR}/ca/root_ca.key" \
    -CAcreateserial \
    -out "${CERT_DIR}/game_server/server.crt" \
    -days 365 \
    -sha256 \
    -extensions v3_req \
    -extfile "${CERT_DIR}/game_server/server_san.cnf"

openssl pkcs12 -export \
    -out "${CERT_DIR}/game_server/server.p12" \
    -inkey "${CERT_DIR}/game_server/server.key" \
    -in "${CERT_DIR}/game_server/server.crt" \
    -passout pass:

# Client certificate for mTLS to global_server
openssl genrsa -out "${CERT_DIR}/game_server/client.key" 4096
openssl req -new \
    -key "${CERT_DIR}/game_server/client.key" \
    -out "${CERT_DIR}/game_server/client.csr" \
    -subj "/C=US/ST=State/L=City/O=ProjectRTS/CN=game_server_client"

openssl x509 -req \
    -in "${CERT_DIR}/game_server/client.csr" \
    -CA "${CERT_DIR}/ca/root_ca.crt" \
    -CAkey "${CERT_DIR}/ca/root_ca.key" \
    -CAcreateserial \
    -out "${CERT_DIR}/game_server/client.crt" \
    -days 365 \
    -sha256

openssl pkcs12 -export \
    -out "${CERT_DIR}/game_server/client.p12" \
    -inkey "${CERT_DIR}/game_server/client.key" \
    -in "${CERT_DIR}/game_server/client.crt" \
    -passout pass:

log_info "Generating Global Server certificates..."
openssl genrsa -out "${CERT_DIR}/global_server/server.key" 4096
openssl req -new \
    -key "${CERT_DIR}/global_server/server.key" \
    -out "${CERT_DIR}/global_server/server.csr" \
    -subj "/C=US/ST=State/L=City/O=ProjectRTS/CN=global_server"

cat > "${CERT_DIR}/global_server/server_san.cnf" <<EOF
[req]
distinguished_name = req_distinguished_name
req_extensions = v3_req

[req_distinguished_name]

[v3_req]
subjectAltName = @alt_names

[alt_names]
DNS.1 = localhost
IP.1 = 127.0.0.1
EOF

openssl x509 -req \
    -in "${CERT_DIR}/global_server/server.csr" \
    -CA "${CERT_DIR}/ca/root_ca.crt" \
    -CAkey "${CERT_DIR}/ca/root_ca.key" \
    -CAcreateserial \
    -out "${CERT_DIR}/global_server/server.crt" \
    -days 365 \
    -sha256 \
    -extensions v3_req \
    -extfile "${CERT_DIR}/global_server/server_san.cnf"

openssl pkcs12 -export \
    -out "${CERT_DIR}/global_server/server.p12" \
    -inkey "${CERT_DIR}/global_server/server.key" \
    -in "${CERT_DIR}/global_server/server.crt" \
    -passout pass:

# Cleanup temporary files
find "${CERT_DIR}" \( -name "*.csr" -o -name "*.cnf" -o -name "*.srl" \) -delete

# Set proper permissions
find "${CERT_DIR}" \( -name "*.key" -o -name "*.p12" \) -exec chmod 600 {} +
chmod 644 "${CERT_DIR}"/ca/root_ca.crt
chown -R github-runner:github-runner "${CERT_DIR}"

log_info "✅ Production certificates generated on server"
log_info "Root CA certificate: ${CERT_DIR}/ca/root_ca.crt"
log_warn "IMPORTANT: Download root_ca.crt from server and install on client machines"
log_warn "Command: scp $(whoami)@${SERVER_IP}:${CERT_DIR}/ca/root_ca.crt ."

###############################################################################
# Step 11: Download Server + nginx (Plan 63)
###############################################################################
log_info "Step 11: Setting up download server and nginx..."

# Install nginx and certbot
DEBIAN_FRONTEND=noninteractive apt-get install -y nginx certbot python3-certbot-nginx

# Create download-server user
if ! id -u download-server >/dev/null 2>&1; then
    useradd -r -s /usr/sbin/nologin download-server
    log_info "User download-server created"
fi

# Create data directories for download server
mkdir -p /data/{chunks,manifests,releases}
chown -R download-server:download-server /data

# Create opt directory for binary
mkdir -p /opt/rts/config
chown -R download-server:download-server /opt/rts

# Install download_server systemd service
if [ -f /opt/rts_game/current/deployment/download_server.service ]; then
    cp /opt/rts_game/current/deployment/download_server.service /etc/systemd/system/
    systemctl daemon-reload
    systemctl enable download_server.service
    log_info "download_server systemd service installed"
fi

# Install nginx config
if [ -f /opt/rts_game/current/deployment/nginx/download_server.conf ]; then
    cp /opt/rts_game/current/deployment/nginx/download_server.conf /etc/nginx/sites-available/
    ln -sf /etc/nginx/sites-available/download_server.conf /etc/nginx/sites-enabled/
    rm -f /etc/nginx/sites-enabled/default
    nginx -t && systemctl reload nginx
    log_info "nginx config installed"
fi

# Open HTTPS port in firewall
ufw allow 443/tcp comment 'HTTPS (download server)'

# Add download-server service restart permissions to sudoers
cat >> /etc/sudoers.d/github-runner <<EOF
github-runner ALL=(ALL) NOPASSWD: /bin/systemctl restart download_server.service
github-runner ALL=(ALL) NOPASSWD: /bin/systemctl status download_server.service
EOF

log_info "Download server infrastructure set up ✅"
log_warn "Run 'certbot --nginx -d yourdomain.com' to configure Let's Encrypt TLS"

###############################################################################
# Step 12: Security Hardening
###############################################################################
log_info "Step 12: Applying security hardening..."

# Enable unattended security updates
echo 'Unattended-Upgrade::Automatic-Reboot "false";' > /etc/apt/apt.conf.d/52unattended-upgrades-no-reboot
DEBIAN_FRONTEND=noninteractive dpkg-reconfigure -plow unattended-upgrades

# Secure SSH (if not already configured)
if ! grep -q "^PasswordAuthentication no" /etc/ssh/sshd_config; then
    log_warn "Consider disabling password authentication in /etc/ssh/sshd_config"
    log_warn "After setting up SSH keys: PasswordAuthentication no"
fi

log_info "Security hardening applied ✅"

###############################################################################
# Completion
###############################################################################
log_info "=========================================="
log_info "✅ Server bootstrap complete!"
log_info "=========================================="
log_info ""
log_info "Next steps:"
log_info "1. Download Root CA for client machines:"
log_info "   scp $(whoami)@${SERVER_IP}:/opt/rts_game/shared/certs/ca/root_ca.crt ."
log_info "2. Install root_ca.crt on client machines (Windows: certutil -addstore -f \"Root\" root_ca.crt)"
log_info "3. Verify GitHub runner is online in your repo's Actions settings"
log_info "4. Push to 'main' branch to trigger first deployment"
log_info "5. Monitor deployment: GitHub → Actions → Deploy to Production Server"
log_info ""
log_info "Useful commands:"
log_info "  - Check services: sudo systemctl status rts-game-server.service"
log_info "  - View logs: sudo journalctl -u rts-game-server.service -f"
log_info "  - Run health check: /opt/rts_game/monitor.sh"
log_info ""
log_info "Runner registered for: $GITHUB_REPO"
log_info "Server IP: $SERVER_IP"
log_info "Certificates: /opt/rts_game/shared/certs/ (NEVER commit private keys to git!)"
log_info "=========================================="
