#!/bin/bash

# FreeRADIUS Installation Fix Script
# This script fixes common issues with FreeRADIUS installation
# Usage: sudo bash fix_freeradius_install_updated.sh

# Color codes for better readability
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Check if script is run as root
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}This script must be run as root (sudo)${NC}"
    exit 1
fi

# Function to display progress
log() {
    echo -e "${GREEN}[$(date '+%Y-%m-%d %H:%M:%S')] $1${NC}"
}

# Function to display warnings
warn() {
    echo -e "${YELLOW}[$(date '+%Y-%m-%d %H:%M:%S')] WARNING: $1${NC}"
}

# Function to display errors
error() {
    echo -e "${RED}[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $1${NC}"
}

# Function to check if OpenVPN is installed and running
check_openvpn() {
    log "Checking existing OpenVPN installation..."
    if systemctl is-active --quiet openvpn; then
        log "OpenVPN service is active"
        # Extract OpenVPN server IP
        OPENVPN_IP=$(ip addr show tun0 2>/dev/null | grep -oP 'inet \K[\d.]+' || echo "")
        if [ -z "$OPENVPN_IP" ]; then
            # If tun0 doesn't exist, use server's main IP
            OPENVPN_IP=$(ip addr | grep -oP 'inet \K[\d.]+' | grep -v '127.0.0.1' | head -n 1)
        fi
        log "OpenVPN server IP detected as: $OPENVPN_IP"
        return 0
    else
        warn "OpenVPN service is not active. Will configure for localhost."
        OPENVPN_IP="127.0.0.1"
        return 1
    fi
}

# Detect Linux distribution
if [ -f /etc/os-release ]; then
    . /etc/os-release
    DISTRO=$ID
    VERSION=$VERSION_ID
    log "Detected Linux distribution: $DISTRO $VERSION_ID"
else
    error "Unable to determine Linux distribution. This script requires Ubuntu or Debian."
    exit 1
fi

# Check if FreeRADIUS is installed
log "Checking if FreeRADIUS is installed..."
if ! dpkg -l | grep -q freeradius; then
    warn "FreeRADIUS is not installed. Installing it now..."
    apt-get update
    apt-get install -y freeradius freeradius-postgresql
fi

# Step 1: Stop any running instances
log "Stopping FreeRADIUS service..."
systemctl stop freeradius || true

# Step 2: Check for existing OpenVPN server
check_openvpn

# Step 3: Clean up any broken installation
log "Cleaning up broken installation..."

# Back up any existing configuration
if [ -d /etc/freeradius ]; then
    TIMESTAMP=$(date +"%Y%m%d-%H%M%S")
    log "Creating backup of existing configuration..."
    mkdir -p /root/freeradius-backup-$TIMESTAMP
    cp -r /etc/freeradius /root/freeradius-backup-$TIMESTAMP/
    
    # Also preserve any existing client configuration
    if [ -f /etc/freeradius/3.0/clients.conf ]; then
        cp /etc/freeradius/3.0/clients.conf /root/freeradius-backup-$TIMESTAMP/clients.conf.original
    fi
fi

# Step 4: Remove existing packages completely (but keep configs with purge --keep-config)
log "Removing FreeRADIUS packages..."
apt-get remove -y freeradius freeradius-common freeradius-config libfreeradius3 freeradius-postgresql freeradius-utils
apt-get autoremove -y

# Step 5: Reinstall FreeRADIUS with proper dependencies
log "Reinstalling FreeRADIUS packages..."
apt-get update
apt-get install -y freeradius freeradius-postgresql freeradius-utils

# Step 6: Make sure the directory structure is correct
log "Verifying directory structure..."

# Check directory structure
if [ ! -d "/etc/freeradius/3.0" ]; then
    # Find the actual radius configuration directory
    RADIUS_CONF_DIR=$(find /etc -type d -name "freeradius" -o -name "raddb" 2>/dev/null | head -n1)
    
    if [ -n "$RADIUS_CONF_DIR" ]; then
        log "Found FreeRADIUS configuration directory at $RADIUS_CONF_DIR"
        
        if [ ! -d "/etc/freeradius" ]; then
            log "Creating /etc/freeradius directory..."
            mkdir -p /etc/freeradius
        fi
        
        if [ "$RADIUS_CONF_DIR" != "/etc/freeradius" ]; then
            log "Creating symbolic link to actual configuration directory..."
            ln -sf "$RADIUS_CONF_DIR" /etc/freeradius/3.0
        fi
    else
        error "Cannot find FreeRADIUS configuration directory!"
        exit 1
    fi
fi

# Step 7: Configure PostgreSQL for FreeRADIUS
log "Setting up PostgreSQL database for FreeRADIUS..."

# Ensure PostgreSQL is running
systemctl start postgresql
systemctl enable postgresql

# Check if radius user exists
RADIUS_USER_EXISTS=$(su - postgres -c "psql -t -c \"SELECT 1 FROM pg_roles WHERE rolname='radius'\"" | xargs)
if [ -z "$RADIUS_USER_EXISTS" ]; then
    log "Creating PostgreSQL user 'radius'..."
    su - postgres -c "psql -c \"CREATE USER radius WITH PASSWORD 'radpass';\""
else
    log "PostgreSQL user 'radius' already exists."
fi

# Check if radius database exists
RADIUS_DB_EXISTS=$(su - postgres -c "psql -t -c \"SELECT 1 FROM pg_database WHERE datname='radius'\"" | xargs)
if [ -z "$RADIUS_DB_EXISTS" ]; then
    log "Creating PostgreSQL database 'radius'..."
    su - postgres -c "psql -c \"CREATE DATABASE radius WITH OWNER radius;\""
else
    log "PostgreSQL database 'radius' already exists."
fi

# Import schema
log "Importing schema to PostgreSQL database..."
SCHEMA_PATH=$(find /etc -name "schema.sql" | grep -i postgresql | head -n1)
if [ -n "$SCHEMA_PATH" ]; then
    log "Found schema file at $SCHEMA_PATH"
    TABLES_EXIST=$(su - postgres -c "psql -t -c \"SELECT count(*) FROM information_schema.tables WHERE table_schema='public';\" radius" | xargs)
    if [ "$TABLES_EXIST" -eq "0" ]; then
        log "Importing FreeRADIUS schema to PostgreSQL..."
        cp "$SCHEMA_PATH" /tmp/radius_schema.sql
        chown postgres:postgres /tmp/radius_schema.sql
        su - postgres -c "psql -d radius -f /tmp/radius_schema.sql" || true
        rm /tmp/radius_schema.sql
    else
        log "Database schema already exists. Skipping import."
    fi
else
    warn "Could not find PostgreSQL schema file. Manual import may be required."
fi

# Configure pg_hba.conf
log "Configuring PostgreSQL authentication (pg_hba.conf)..."
PG_HBA_CONF=$(su - postgres -c "psql -t -c \"SHOW hba_file;\"" | xargs)
log "PostgreSQL hba configuration file: $PG_HBA_CONF"

# Check if radius user entry exists
if ! grep -q "^host.*radius.*radius.*md5" "$PG_HBA_CONF"; then
    log "Adding radius user entry to pg_hba.conf..."
    # Add line before the first 'host' line
    sed -i '/^host/i host    radius          radius          127.0.0.1/32            md5' "$PG_HBA_CONF"
    
    # Reload PostgreSQL to apply changes
    log "Reloading PostgreSQL configuration..."
    systemctl reload postgresql
fi

# Step 8: Fix FreeRADIUS SQL configuration
# Find actual modules directory
MODS_AVAILABLE_DIR=$(find /etc -path "*/mods-available" | grep freeradius | head -n1)
MODS_ENABLED_DIR=$(find /etc -path "*/mods-enabled" | grep freeradius | head -n1)

if [ -n "$MODS_AVAILABLE_DIR" ]; then
    log "Found modules directory at $MODS_AVAILABLE_DIR"

    # Create SQL module configuration
    log "Creating SQL module configuration..."
    cat > "$MODS_AVAILABLE_DIR/sql" << EOF
sql {
    driver = "rlm_sql_postgresql"
    dialect = "postgresql"

    # Connection info
    server = "localhost"
    port = 5432
    login = "radius"
    password = "radpass"
    radius_db = "radius"
    
    # Connection pool optimization
    pool {
        start = 5
        min = 3
        max = 10
        spare = 5
        uses = 0
        lifetime = 0
        idle_timeout = 60
    }

    # Read configuration
    read_clients = yes
    client_table = "nas"

    # Table configuration
    accounting_table = "radacct"
    acct_table1 = "radacct"
    acct_table2 = "radacct"
    postauth_table = "radpostauth"
    authcheck_table = "radcheck"
    authreply_table = "radreply"
    groupcheck_table = "radgroupcheck"
    groupreply_table = "radgroupreply"
    usergroup_table = "radusergroup"
    
    # Query configuration
    read_groups = yes
    deletestalesessions = yes
    sqltrace = no
    num_sql_socks = 10
    connect_failure_retry_delay = 60
}
EOF

    # Enable SQL module
    if [ -n "$MODS_ENABLED_DIR" ]; then
        log "Enabling SQL module..."
        cd "$MODS_ENABLED_DIR"
        ln -sf ../mods-available/sql .
    fi
fi

# Step 9: Fix site configuration
SITES_AVAILABLE_DIR=$(find /etc -path "*/sites-available" | grep freeradius | head -n1)

if [ -n "$SITES_AVAILABLE_DIR" ]; then
    DEFAULT_SITE="$SITES_AVAILABLE_DIR/default"
    INNER_TUNNEL="$SITES_AVAILABLE_DIR/inner-tunnel"

    # Update default site configuration
    if [ -f "$DEFAULT_SITE" ]; then
        log "Updating default site configuration..."
        
        # Update authorize section
        sed -i '/^authorize {/,/^}/ s/^}$/    sql\n}/' "$DEFAULT_SITE"
        
        # Update accounting section
        sed -i '/^accounting {/,/^}/ s/^}$/    sql\n}/' "$DEFAULT_SITE"
        
        # Update session section
        sed -i '/^session {/,/^}/ s/^}$/    sql\n}/' "$DEFAULT_SITE"
        
        # Update post-auth section
        sed -i '/^post-auth {/,/^}/ s/^}$/    sql\n}/' "$DEFAULT_SITE"
    fi

    # Update inner-tunnel site configuration
    if [ -f "$INNER_TUNNEL" ]; then
        log "Updating inner-tunnel site configuration..."
        
        # Update authorize section
        sed -i '/^authorize {/,/^}/ s/^}$/    sql\n}/' "$INNER_TUNNEL"
        
        # Update accounting section
        sed -i '/^accounting {/,/^}/ s/^}$/    sql\n}/' "$INNER_TUNNEL"
        
        # Update session section
        sed -i '/^session {/,/^}/ s/^}$/    sql\n}/' "$INNER_TUNNEL"
        
        # Update post-auth section
        sed -i '/^post-auth {/,/^}/ s/^}$/    sql\n}/' "$INNER_TUNNEL"
    fi
fi

# Step 10: Configure OpenVPN integration
log "Configuring RADIUS for OpenVPN integration..."

# Create OpenVPN policy if it doesn't exist
POLICY_DIR=$(find /etc -path "*/policy.d" | grep freeradius | head -n1)
if [ -n "$POLICY_DIR" ]; then
    log "Creating OpenVPN policy..."
    
    # Create policy file if it doesn't exist
    if [ ! -f "$POLICY_DIR/openvpn" ]; then
        cat > "$POLICY_DIR/openvpn" << EOF
# OpenVPN policy for FreeRADIUS
# This policy handles authentication for OpenVPN clients

policy openvpn {
    # Log authentication attempts
    auth_log {
        reply = no
    }
    
    # Check if user exists
    if (User-Name =~ /^[[:alnum:]._-]+$/) {
        # Valid username format, continue
        update control {
            Auth-Type := PAP
        }
        ok
    } else {
        # Invalid username format
        reject {
            message = "Invalid username format"
        }
    }
}
EOF
EOF
    fi
fi

# Configure default clients
CLIENTS_CONF=$(find /etc -name "clients.conf" | grep freeradius | head -n1)
if [ -n "$CLIENTS_CONF" ]; then
    log "Checking clients configuration..."
    
    # Check if we have the original clients file from backup
    ORIGINAL_CLIENTS=""
    if [ -d "/root/freeradius-backup-$TIMESTAMP" ] && [ -f "/root/freeradius-backup-$TIMESTAMP/clients.conf.original" ]; then
        ORIGINAL_CLIENTS="/root/freeradius-backup-$TIMESTAMP/clients.conf.original"
    fi
    
    # Check for duplicate OpenVPN clients in current config
    DUPLICATE_CLIENT=$(grep -c "client openvpn_server" "$CLIENTS_CONF" || echo "0")
    
    if [ "$DUPLICATE_CLIENT" -gt 1 ]; then
        log "Found duplicate OpenVPN client entries. Fixing..."
        # Create a new clients.conf without duplicates
        TEMP_FILE=$(mktemp)
        
        # Extract the localhost client and one OpenVPN client
        grep -A 10 "client localhost" "$CLIENTS_CONF" | grep -B 100 -m 1 "}" > "$TEMP_FILE"
        echo "" >> "$TEMP_FILE"
        grep -A 10 -m 1 "client openvpn_server" "$CLIENTS_CONF" | grep -B 100 -m 1 "}" >> "$TEMP_FILE"
        
        # Replace clients.conf with the cleaned version
        cp "$TEMP_FILE" "$CLIENTS_CONF"
        rm "$TEMP_FILE"
    elif [ "$DUPLICATE_CLIENT" -eq 0 ] && [ -n "$OPENVPN_IP" ]; then
        log "Adding OpenVPN server as RADIUS client..."
        cat >> "$CLIENTS_CONF" << EOF

client openvpn_server {
    ipaddr = $OPENVPN_IP
    secret = vpn_radius_secret
    shortname = openvpn
    nastype = other
    require_message_authenticator = no
}
EOF
    fi
fi

# Step 11: Create test user
log "Adding test user to PostgreSQL database..."
su - postgres -c "psql -c \"DELETE FROM radcheck WHERE username='testuser';\" radius" || true
su - postgres -c "psql -c \"INSERT INTO radcheck (username, attribute, op, value) VALUES ('testuser', 'Cleartext-Password', ':=', 'password');\" radius" || true

# Step 12: Set file permissions
log "Setting file permissions..."
FREERADIUS_DIR=$(find /etc -name "freeradius" -type d | head -n1)

if [ -n "$FREERADIUS_DIR" ]; then
    # Detect FreeRADIUS user
    if getent group | grep -q "^freerad:"; then
        RADIUS_USER="freerad"
    elif getent group | grep -q "^radiusd:"; then
        RADIUS_USER="radiusd"
    else
        RADIUS_USER="freerad"
    fi

    log "Using user/group: $RADIUS_USER for permissions"
    find "$FREERADIUS_DIR" -type d -exec chmod 755 {} \; || true
    find "$FREERADIUS_DIR" -type f -exec chmod 644 {} \; || true
    chown -R $RADIUS_USER:$RADIUS_USER "$FREERADIUS_DIR" || true
    
    # Special file permissions
    find "$FREERADIUS_DIR" -name "*.conf" -exec chmod 640 {} \; || true
    
    # Create log directory
    mkdir -p /var/log/radius
    touch /var/log/radius/radius.log
    chown -R $RADIUS_USER:$RADIUS_USER /var/log/radius || true
    chmod 755 /var/log/radius || true
    chmod 644 /var/log/radius/radius.log || true
fi

# Step 13: Restart and test FreeRADIUS
log "Restarting FreeRADIUS service..."
systemctl restart freeradius

# Wait a moment for the service to start
sleep 3

# Check service status
if systemctl is-active --quiet freeradius; then
    log "SUCCESS: FreeRADIUS service started successfully!"
    systemctl status freeradius | grep -E "Active:|Main PID:" || true
else
    error "FreeRADIUS service failed to start. Running diagnostics..."
    systemctl status freeradius
    
    # Try to identify the error
    log "Checking for common issues..."
    
    # Check if radiusd executable exists
    if ! command -v radiusd &> /dev/null && ! command -v freeradius &> /dev/null; then
        error "FreeRADIUS binary not found! Reinstall the package."
    fi
    
    # Check for SELinux issues
    if command -v getenforce &> /dev/null; then
        SELINUX=$(getenforce)
        if [ "$SELINUX" = "Enforcing" ]; then
            warn "SELinux is enabled and may be blocking FreeRADIUS. Consider setting it to permissive mode."
            warn "Run: setenforce 0"
        fi
    fi
    
    # Check for port conflicts
    if command -v netstat &> /dev/null || command -v ss &> /dev/null; then
        log "Checking if ports 1812 and 1813 are already in use..."
        if command -v ss &> /dev/null; then
            ss -tuln | grep -E '1812|1813' || echo "Ports are available"
        elif command -v netstat &> /dev/null; then
            netstat -tuln | grep -E '1812|1813' || echo "Ports are available"
        fi
    fi
    
    # Try debugging mode
    log "Starting FreeRADIUS in debug mode for diagnostics..."
    RADIUS_BIN=$(command -v radiusd || command -v freeradius)
    if [ -n "$RADIUS_BIN" ]; then
        $RADIUS_BIN -X
    else
        error "Cannot find FreeRADIUS binary for debug mode."
    fi
    
    exit 1
fi

# Display success message
echo
echo "==============================================="
echo "FreeRADIUS installation fixed successfully!"
echo "==============================================="
echo
echo "Default test user created:"
echo "  Username: testuser"
echo "  Password: password"
echo
echo "OpenVPN integration configured with:"
echo "  IP address: $OPENVPN_IP"
echo "  Shared secret: vpn_radius_secret"
echo
echo "PostgreSQL database details:"
echo "  Database: radius"
echo "  Username: radius"
echo "  Password: radpass"
echo
echo "To verify your installation, run:"
echo "radtest testuser password localhost 0 testing123"
echo "==============================================="
