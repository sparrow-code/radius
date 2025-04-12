#!/bin/bash
# cleanup_radius.sh
# This script completely removes FreeRADIUS and all related configurations
# Run with: sudo bash cleanup_radius.sh

# Source common utilities
SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
source "$SCRIPT_DIR/common.sh" || {
    echo "Error: Could not load common utilities"
    exit 1
}

section "FreeRADIUS Complete Cleanup"

# Check if running as root
check_root

# Confirm with user
echo -e "${RED}⚠️ WARNING:${NC} This will completely remove FreeRADIUS and all configurations!"
echo -e "${RED}⚠️ WARNING:${NC} All users, clients, and settings will be permanently deleted!"
echo
read -p "Are you sure you want to continue? [y/N]: " confirm
if [[ ! $confirm =~ ^[Yy]$ ]]; then
    log "Cleanup aborted."
    exit 0
fi

# Step 1: Stop all related services
section "Stopping Services"
log "Stopping FreeRADIUS service..."
systemctl stop freeradius || true
log "Stopping PostgreSQL service..."
systemctl stop postgresql || true
echo

# Step 2: Remove FreeRADIUS packages
section "Removing Packages"
log "Removing FreeRADIUS packages..."
apt-get purge --auto-remove -y freeradius* || true
echo

# Step 3: Remove PostgreSQL for RADIUS if requested
read -p "Do you also want to remove PostgreSQL? [y/N]: " remove_pg
if [[ $remove_pg =~ ^[Yy]$ ]]; then
    log "Removing PostgreSQL packages..."
    apt-get purge --auto-remove -y postgresql* || true
    
    log "Removing PostgreSQL data directory..."
    rm -rf /var/lib/postgresql || true
else
    # Just remove the RADIUS database
    if command_exists psql; then
        log "Removing only the RADIUS database..."
        su - postgres -c "psql -c 'DROP DATABASE IF EXISTS radius;'" || true
        su - postgres -c "psql -c 'DROP ROLE IF EXISTS radius;'" || true
    fi
fi
echo

# Step 4: Remove configuration files
section "Removing Configuration Files"
log "Removing FreeRADIUS configuration files..."
rm -rf /etc/freeradius || true
rm -rf /etc/raddb || true
rm -rf /var/lib/freeradius || true

# Step 5: Remove logs
log "Removing log files..."
rm -rf /var/log/radius || true
rm -rf /var/log/freeradius || true

# Step 6: Remove any additional files
log "Removing additional files..."
find /etc -name "*radius*" -print -exec rm -rf {} \; 2>/dev/null || true
find /var -name "*radius*" -print -exec rm -rf {} \; 2>/dev/null || true
echo

section "Cleanup Complete"
echo -e "${GREEN}FreeRADIUS has been completely removed from your system!${NC}"
echo "You can now perform a fresh installation using:"
echo "  sudo bash radius.sh install"
echo
