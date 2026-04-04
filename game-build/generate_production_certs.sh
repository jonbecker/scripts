#!/bin/bash
set -euo pipefail

# Usage: ./generate_production_certs.sh <server-ip>
# Example: ./generate_production_certs.sh 203.0.113.45

if [ -z "${1:-}" ]; then
    echo "Usage: $0 <server-ip>"
    exit 1
fi

SERVER_IP=$1

# Validate IP address format (each octet 0-255)
if ! [[ "$SERVER_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    echo "Error: Invalid IP address format: $SERVER_IP"
    exit 1
fi
IFS='.' read -ra OCTETS <<< "$SERVER_IP"
for octet in "${OCTETS[@]}"; do
    if (( octet > 255 )); then
        echo "Error: Invalid IP address (octet $octet > 255): $SERVER_IP"
        exit 1
    fi
done
OUTPUT_DIR="deployment/certs"
VALIDITY_DAYS=365

echo "=========================================="
echo "Generating Production PKI Certificates"
echo "Server IP: $SERVER_IP"
echo "Validity: $VALIDITY_DAYS days"
echo "Output: $OUTPUT_DIR/"
echo "=========================================="

# Create output directory structure
mkdir -p "${OUTPUT_DIR}"/{ca,game_server,global_server}

# Step 1: Generate Root CA (if not using dev CA)
echo ""
echo "[1/4] Generating Root CA..."
openssl genrsa -out "${OUTPUT_DIR}/ca/root_ca.key" 4096

openssl req -x509 -new -nodes \
    -key "${OUTPUT_DIR}/ca/root_ca.key" \
    -sha256 -days ${VALIDITY_DAYS} \
    -out "${OUTPUT_DIR}/ca/root_ca.crt" \
    -subj "/C=US/ST=State/L=City/O=ProjectRTS/CN=Project RTS Production CA"

echo "✅ Root CA generated"

# Step 2: Generate Game Server Certificates
echo ""
echo "[2/4] Generating Game Server certificates..."

# Server certificate (for TLS on port 8080)
openssl genrsa -out "${OUTPUT_DIR}/game_server/server.key" 4096

openssl req -new \
    -key "${OUTPUT_DIR}/game_server/server.key" \
    -out "${OUTPUT_DIR}/game_server/server.csr" \
    -subj "/C=US/ST=State/L=City/O=ProjectRTS/CN=${SERVER_IP}"

# Create SAN config for server IP
cat > "${OUTPUT_DIR}/game_server/server_san.cnf" <<EOF
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
    -in "${OUTPUT_DIR}/game_server/server.csr" \
    -CA "${OUTPUT_DIR}/ca/root_ca.crt" \
    -CAkey "${OUTPUT_DIR}/ca/root_ca.key" \
    -CAcreateserial \
    -out "${OUTPUT_DIR}/game_server/server.crt" \
    -days ${VALIDITY_DAYS} \
    -sha256 \
    -extensions v3_req \
    -extfile "${OUTPUT_DIR}/game_server/server_san.cnf"

# Create PKCS12 bundle (no password)
openssl pkcs12 -export \
    -out "${OUTPUT_DIR}/game_server/server.p12" \
    -inkey "${OUTPUT_DIR}/game_server/server.key" \
    -in "${OUTPUT_DIR}/game_server/server.crt" \
    -passout pass:

# Client certificate (for mTLS to global_server)
openssl genrsa -out "${OUTPUT_DIR}/game_server/client.key" 4096

openssl req -new \
    -key "${OUTPUT_DIR}/game_server/client.key" \
    -out "${OUTPUT_DIR}/game_server/client.csr" \
    -subj "/C=US/ST=State/L=City/O=ProjectRTS/CN=game_server_client"

openssl x509 -req \
    -in "${OUTPUT_DIR}/game_server/client.csr" \
    -CA "${OUTPUT_DIR}/ca/root_ca.crt" \
    -CAkey "${OUTPUT_DIR}/ca/root_ca.key" \
    -CAcreateserial \
    -out "${OUTPUT_DIR}/game_server/client.crt" \
    -days ${VALIDITY_DAYS} \
    -sha256

openssl pkcs12 -export \
    -out "${OUTPUT_DIR}/game_server/client.p12" \
    -inkey "${OUTPUT_DIR}/game_server/client.key" \
    -in "${OUTPUT_DIR}/game_server/client.crt" \
    -passout pass:

echo "✅ Game Server certificates generated"

# Step 3: Generate Global Server Certificates
echo ""
echo "[3/4] Generating Global Server certificates..."

openssl genrsa -out "${OUTPUT_DIR}/global_server/server.key" 4096

openssl req -new \
    -key "${OUTPUT_DIR}/global_server/server.key" \
    -out "${OUTPUT_DIR}/global_server/server.csr" \
    -subj "/C=US/ST=State/L=City/O=ProjectRTS/CN=global_server"

# SAN config for localhost (global_server is internal only)
cat > "${OUTPUT_DIR}/global_server/server_san.cnf" <<EOF
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
    -in "${OUTPUT_DIR}/global_server/server.csr" \
    -CA "${OUTPUT_DIR}/ca/root_ca.crt" \
    -CAkey "${OUTPUT_DIR}/ca/root_ca.key" \
    -CAcreateserial \
    -out "${OUTPUT_DIR}/global_server/server.crt" \
    -days ${VALIDITY_DAYS} \
    -sha256 \
    -extensions v3_req \
    -extfile "${OUTPUT_DIR}/global_server/server_san.cnf"

openssl pkcs12 -export \
    -out "${OUTPUT_DIR}/global_server/server.p12" \
    -inkey "${OUTPUT_DIR}/global_server/server.key" \
    -in "${OUTPUT_DIR}/global_server/server.crt" \
    -passout pass:

echo "✅ Global Server certificates generated"

# Step 4: Cleanup temporary files
echo ""
echo "[4/4] Cleaning up..."
find "${OUTPUT_DIR}" \( -name "*.csr" -o -name "*.cnf" -o -name "*.srl" \) -delete

echo ""
echo "=========================================="
echo "✅ Production certificates generated!"
echo "=========================================="
echo ""
echo "Certificate details:"
echo "  CA: ${OUTPUT_DIR}/ca/root_ca.crt"
echo "  Game Server: ${SERVER_IP}"
echo "  Global Server: localhost (internal)"
echo "  Validity: ${VALIDITY_DAYS} days"
echo ""
echo "Certificates (.crt) are safe to commit — they are public."
echo "NEVER commit private keys (.key, .p12) to git!"
echo "  Add '${OUTPUT_DIR}/**/*.key' and '${OUTPUT_DIR}/**/*.p12' to your .gitignore."
echo ""
echo "Next steps:"
echo "  1. git add ${OUTPUT_DIR}/**/*.crt"
echo "  2. git commit -m 'chore: Add production certificates for ${SERVER_IP}'"
echo "  3. git push origin main"
echo ""
echo "Clients connecting via TLS must install: ${OUTPUT_DIR}/ca/root_ca.crt"
echo "=========================================="
