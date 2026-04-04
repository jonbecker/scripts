#!/bin/bash
# ============================================================================
# PostgreSQL Setup Script for RTS Game Global Server
# Debian 12.12 (Bookworm)
# ============================================================================
#
# Usage:
#   chmod +x setup_postgres_debian.sh
#   sudo ./setup_postgres_debian.sh
#
# This script will:
#   1. Install PostgreSQL 15
#   2. Create the rts_game database
#   3. Create a dedicated user with password
#   4. Initialize the schema
#   5. Generate a .env file for the global_server
#
# ============================================================================

set -euo pipefail  # Exit on error, undefined vars, pipe failures

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Configuration - CHANGE THESE!
DB_NAME="rts_game"
DB_USER="rts_server"
DB_PASSWORD="CHANGE_ME_$(openssl rand -hex 16)"  # Auto-generate if not set

# Validate identifiers (alphanumeric + underscore only — prevents SQL injection)
for ident in "$DB_NAME" "$DB_USER"; do
    if ! [[ "$ident" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]]; then
        echo -e "${RED}Error: Invalid identifier '$ident' — use only letters, digits, underscores${NC}"
        exit 1
    fi
done

echo -e "${GREEN}============================================${NC}"
echo -e "${GREEN}  RTS Game - PostgreSQL Setup for Debian 12${NC}"
echo -e "${GREEN}============================================${NC}"
echo ""

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Error: Please run as root (sudo)${NC}"
    exit 1
fi

# Prompt for custom password
read -p "Enter database password for user '$DB_USER' (or press Enter for auto-generated): " USER_PASSWORD
if [ -n "$USER_PASSWORD" ]; then
    DB_PASSWORD="$USER_PASSWORD"
fi

echo ""
echo -e "${YELLOW}Configuration:${NC}"
echo "  Database: $DB_NAME"
echo "  User:     $DB_USER"
echo "  Password: (hidden)"
echo ""

# Step 1: Update package lists
echo -e "${YELLOW}[1/6] Updating package lists...${NC}"
apt-get update -qq

# Step 2: Install PostgreSQL
echo -e "${YELLOW}[2/6] Installing PostgreSQL...${NC}"
apt-get install -y postgresql postgresql-contrib

# Step 3: Start and enable PostgreSQL
echo -e "${YELLOW}[3/6] Starting PostgreSQL service...${NC}"
systemctl start postgresql
systemctl enable postgresql

# Step 4: Create database and user
echo -e "${YELLOW}[4/6] Creating database and user...${NC}"

# Escape single quotes in password to prevent SQL injection
DB_PASSWORD_ESCAPED="${DB_PASSWORD//\'/\'\'}"

sudo -u postgres psql <<EOF
-- Create user if not exists
DO \$\$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = '$DB_USER') THEN
        CREATE USER $DB_USER WITH PASSWORD '$DB_PASSWORD_ESCAPED';
    ELSE
        ALTER USER $DB_USER WITH PASSWORD '$DB_PASSWORD_ESCAPED';
    END IF;
END
\$\$;

-- Create database if not exists
SELECT 'CREATE DATABASE $DB_NAME OWNER $DB_USER'
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = '$DB_NAME')\gexec

-- Grant privileges
GRANT ALL PRIVILEGES ON DATABASE $DB_NAME TO $DB_USER;

-- Connect to the database and grant schema privileges
\c $DB_NAME
GRANT ALL ON SCHEMA public TO $DB_USER;
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO $DB_USER;
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO $DB_USER;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO $DB_USER;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO $DB_USER;
EOF

echo -e "${GREEN}  ✓ Database '$DB_NAME' created${NC}"
echo -e "${GREEN}  ✓ User '$DB_USER' created${NC}"

# Step 5: Initialize schema
echo -e "${YELLOW}[5/6] Initializing database schema...${NC}"

# Check if schema file exists (look in common locations)
SCHEMA_FILE=""
POSSIBLE_PATHS=(
    "./global_server/src/migrations/001_initial_schema.sql"
    "../global_server/src/migrations/001_initial_schema.sql"
    "/opt/rts_game/global_server/src/migrations/001_initial_schema.sql"
    "~/rts_game/global_server/src/migrations/001_initial_schema.sql"
)

for path in "${POSSIBLE_PATHS[@]}"; do
    expanded_path=$(eval echo "$path")
    if [ -f "$expanded_path" ]; then
        SCHEMA_FILE="$expanded_path"
        break
    fi
done

if [ -n "$SCHEMA_FILE" ]; then
    echo "  Found schema file: $SCHEMA_FILE"
    sudo -u postgres psql -d "$DB_NAME" -f "$SCHEMA_FILE"
    echo -e "${GREEN}  ✓ Schema initialized${NC}"
else
    echo -e "${YELLOW}  ⚠ Schema file not found. The global_server will auto-initialize on first run.${NC}"
    echo "  Expected location: global_server/src/migrations/001_initial_schema.sql"
fi

# Step 6: Configure PostgreSQL for local connections (already default on Debian)
echo -e "${YELLOW}[6/6] Verifying PostgreSQL configuration...${NC}"

# Check if pg_hba.conf allows local connections
PG_HBA=$(sudo -u postgres psql -t -c "SHOW hba_file;" | xargs)
if grep -q "local.*all.*all.*peer" "$PG_HBA" || grep -q "host.*127.0.0.1.*md5" "$PG_HBA"; then
    echo -e "${GREEN}  ✓ Local connections enabled${NC}"
else
    echo -e "${YELLOW}  Adding local connection rules...${NC}"
    echo "host    $DB_NAME    $DB_USER    127.0.0.1/32    scram-sha-256" >> "$PG_HBA"
    systemctl reload postgresql
fi

# Generate .env file
ENV_FILE="/opt/rts_game/.env"
echo ""
echo -e "${YELLOW}Generating environment file...${NC}"

mkdir -p /opt/rts_game
cat > "$ENV_FILE" <<EOF
# RTS Game Global Server - Database Configuration
# Generated on $(date)

DATABASE_HOST=127.0.0.1
DATABASE_PORT=5432
DATABASE_NAME=$DB_NAME
DATABASE_USER=$DB_USER
DATABASE_PASSWORD=$DB_PASSWORD
EOF

chmod 600 "$ENV_FILE"
echo -e "${GREEN}  ✓ Environment file created: $ENV_FILE${NC}"

# Also create a local copy
LOCAL_ENV="./global_server.env"
cat > "$LOCAL_ENV" <<EOF
# RTS Game Global Server - Database Configuration
# Generated on $(date)

DATABASE_HOST=127.0.0.1
DATABASE_PORT=5432
DATABASE_NAME=$DB_NAME
DATABASE_USER=$DB_USER
DATABASE_PASSWORD=$DB_PASSWORD
EOF

chmod 600 "$LOCAL_ENV"

# Print summary
echo ""
echo -e "${GREEN}============================================${NC}"
echo -e "${GREEN}  Setup Complete!${NC}"
echo -e "${GREEN}============================================${NC}"
echo ""
echo "Database connection details:"
echo "  Host:     127.0.0.1"
echo "  Port:     5432"
echo "  Database: $DB_NAME"
echo "  User:     $DB_USER"
echo "  Password: (stored in $ENV_FILE)"
echo ""
echo "Environment files created:"
echo "  $ENV_FILE"
echo "  $LOCAL_ENV"
echo ""
echo -e "${YELLOW}To start the global_server:${NC}"
echo ""
echo "  # Option 1: Source the env file"
echo "  source $LOCAL_ENV"
echo "  ./global_server --env staging --bind 0.0.0.0:9753"
echo ""
echo "  # Option 2: Using env file inline"
echo "  env \$(cat $LOCAL_ENV | xargs) ./global_server --env staging --bind 0.0.0.0:9753"
echo ""
echo -e "${YELLOW}To test the connection:${NC}"
echo "  psql -h 127.0.0.1 -U $DB_USER -d $DB_NAME"
echo ""
echo -e "${RED}IMPORTANT: Save the password securely! It won't be shown again.${NC}"
echo ""
