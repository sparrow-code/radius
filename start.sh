#!/bin/bash

# FreeRADIUS Automated Setup Script
# This script automates the entire FreeRADIUS installation and configuration process
# Usage: sudo bash start.sh [options]

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

# Function to check if a command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Function to get script directory
get_script_dir() {
    dirname "$(readlink -f "$0")"
}

SCRIPT_DIR=$(get_script_dir)
CONFIG_FILE="${SCRIPT_DIR}/radius_config.conf"

# Default configuration
RADIUS_USER="radius"
RADIUS_PASS="radpass"
RADIUS_DB="radius"
TEST_USER="testuser"
TEST_PASS="password"
OPENVPN_INTEGRATION=true
SERVER_IP=$(ip addr | grep -oP 'inet \K[\d.]+' | grep -v '127.0.0.1' | head -n 1)

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --no-openvpn)
            OPENVPN_INTEGRATION=false
            shift
            ;;
        --config=*)
            CONFIG_FILE="${1#*=}"
            shift
            ;;
        *)
            echo "Unknown option: $1"
            echo "Available options: --no-openvpn, --config=FILE"
            exit 1
            ;;
    esac
done

# Load configuration file if it exists
if [[ -f "$CONFIG_FILE" ]]; then
    log "Loading configuration from $CONFIG_FILE"
    source "$CONFIG_FILE"
else
    log "Using default configuration (no config file found at $CONFIG_FILE)"
    
    # Create a sample config file for future use
    cat > "$CONFIG_FILE" << EOF
# FreeRADIUS configuration
# Edit this file to customize your installation

# PostgreSQL settings
RADIUS_USER="radius"
RADIUS_PASS="radpass"
RADIUS_DB="radius"

# Test user settings
TEST_USER="testuser"
TEST_PASS="password"

# OpenVPN integration
OPENVPN_INTEGRATION=true

# Server IP (autodetected if empty)
SERVER_IP="$SERVER_IP"
EOF
    
    log "Sample configuration file created at $CONFIG_FILE"
    log "You can edit this file and re-run the script with --config=$CONFIG_FILE"
fi

# Display current configuration
echo "=================================================="
echo "FreeRADIUS Automated Setup"
echo "=================================================="
echo "PostgreSQL User: $RADIUS_USER"
echo "PostgreSQL Database: $RADIUS_DB"
echo "Test User: $TEST_USER"
echo "Server IP: $SERVER_IP"
echo "OpenVPN Integration: $(if $OPENVPN_INTEGRATION; then echo "Yes"; else echo "No"; fi)"
echo "=================================================="

# Confirm before proceeding
read -p "Continue with installation? [Y/n] " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]?$ ]]; then
    log "Installation cancelled."
    exit 0
fi

# Step 1: Install FreeRADIUS with PostgreSQL
log "Step 1: Installing FreeRADIUS with PostgreSQL"
bash "${SCRIPT_DIR}/install_freeradius.sh"
if [ $? -ne 0 ]; then
    error "FreeRADIUS installation failed. Check the logs for more information."
    exit 1
fi

# Step 2: Add test users
log "Step 2: Adding test users"
bash "${SCRIPT_DIR}/radius_add_user.sh" "$TEST_USER" "$TEST_PASS" "testgroup"
if [ $? -ne 0 ]; then
    warn "Failed to add test user. This may not be critical if the user already exists."
fi

# Step 3: Add OpenVPN as a RADIUS client if enabled
if $OPENVPN_INTEGRATION; then
    log "Step 3: Adding OpenVPN as a RADIUS client"
    bash "${SCRIPT_DIR}/radius_add_client.sh" "openvpn_server" "$SERVER_IP" "vpn_radius_secret" "openvpn"
    if [ $? -ne 0 ]; then
        warn "Failed to add OpenVPN as a RADIUS client. This may not be critical if the client already exists."
    fi
    
    # Step 4: Configure FreeRADIUS for OpenVPN integration
    log "Step 4: Configuring FreeRADIUS for OpenVPN integration"
    bash "${SCRIPT_DIR}/radius_openvpn_config.sh"
    if [ $? -ne 0 ]; then
        warn "Failed to configure OpenVPN integration. You may need to run the script manually."
    fi
else
    log "OpenVPN integration skipped as per configuration."
fi

# Step 5: Verify installation
log "Step 5: Verifying installation"
if [ -f /etc/freeradius/3.0/sql_module_check.sh ]; then
    log "Running SQL module verification test"
    bash /etc/freeradius/3.0/sql_module_check.sh
    if [ $? -ne 0 ]; then
        warn "SQL module verification failed. You may need to troubleshoot the PostgreSQL connection."
    else
        log "SQL module verification passed."
    fi
else
    warn "SQL module verification script not found. Skipping verification."
fi

# Step 6: Test RADIUS authentication
log "Step 6: Testing RADIUS authentication"
if command_exists radtest; then
    radtest "$TEST_USER" "$TEST_PASS" localhost 0 testing123 | tee /tmp/radtest_result.txt
    if grep -q "Access-Accept" /tmp/radtest_result.txt; then
        log "RADIUS authentication test passed!"
    else
        warn "RADIUS authentication test failed. Check the logs for more information."
    fi
else
    warn "radtest command not found. Skipping authentication test."
fi

# Step 7: Show service status
log "Step 7: Checking service status"
systemctl status freeradius | grep -E "Active:|Main PID:" || true
systemctl status postgresql | grep -E "Active:|Main PID:" || true

echo
echo "=================================================="
echo "FreeRADIUS Setup Complete!"
echo "=================================================="
echo "Your FreeRADIUS server has been set up with PostgreSQL backend."
echo
echo "Test user details:"
echo "  Username: $TEST_USER"
echo "  Password: $TEST_PASS"
echo
echo "PostgreSQL database details:"
echo "  Database: $RADIUS_DB"
echo "  Username: $RADIUS_USER"
echo "  Password: $RADIUS_PASS"
echo
echo "To add users, run:"
echo "  sudo bash ${SCRIPT_DIR}/radius_add_user.sh <username> <password> [group]"
echo
echo "To add RADIUS clients, run:"
echo "  sudo bash ${SCRIPT_DIR}/radius_add_client.sh <name> <ip> <secret> [nastype]"
echo
if $OPENVPN_INTEGRATION; then
    echo "OpenVPN integration was configured."
    echo "OpenVPN configuration instructions are available at:"
    echo "  /etc/freeradius/3.0/openvpn_radius_config.txt"
    echo
fi
echo "RADIUS logs are stored in /var/log/radius/radius.log"
echo "=================================================="
