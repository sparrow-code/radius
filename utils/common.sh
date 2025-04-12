#!/bin/bash

# Common utilities for RADIUS scripts
# This file contains shared functions used across RADIUS management scripts

# Color codes for better readability
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
PURPLE='\033[0;35m'
BOLD='\033[1m'
NC='\033[0m' # No Color

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

# Function for section headers
section() {
    echo
    echo -e "${BLUE}==== $1 ====${NC}"
    echo
}

# Check if running as root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "This script must be run as root"
        echo -e "${YELLOW}Please run with sudo or as root user${NC}"
        exit 1
    fi
}

# Function to find FreeRADIUS configuration directory
find_freeradius_dir() {
    local config_dir=$(find /etc -type d -name "freeradius" -o -name "raddb" 2>/dev/null | head -n1)
    if [ -z "$config_dir" ]; then
        error "Cannot find FreeRADIUS configuration directory."
        return 1
    fi
    
    # Check for version 3 directory
    if [ -d "$config_dir/3.0" ]; then
        echo "$config_dir/3.0"
    else
        echo "$config_dir"
    fi
    return 0
}

# Function to check if FreeRADIUS is installed
check_freeradius_installed() {
    if ! dpkg -l | grep -q freeradius; then
        error "FreeRADIUS is not installed. Please run the installation script first."
        return 1
    fi
    return 0
}

# Function to check if a command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Function to display a header
show_header() {
    clear
    echo -e "${BLUE}=================================================${NC}"
    echo -e "${BOLD}${PURPLE}           FreeRADIUS Management System${NC}"
    echo -e "${BLUE}=================================================${NC}"
    echo
}

# Function to check if a command exists
command_exists() {
    command -v "$1" &> /dev/null
}

# Find FreeRADIUS configuration directory
find_freeradius_dir() {
    local config_dir=""
    
    # Common locations to check
    local locations=(
        "/etc/freeradius/3.0"
        "/etc/freeradius"
        "/etc/raddb"
    )
    
    for dir in "${locations[@]}"; do
        if [ -d "$dir" ]; then
            config_dir="$dir"
            break
        fi
    done
    
    echo "$config_dir"
}

# Check FreeRADIUS service status
check_freeradius_status() {
    if systemctl is-active --quiet freeradius; then
        echo -e "${GREEN}● FreeRADIUS service is running${NC}"
        return 0
    else
        echo -e "${RED}✗ FreeRADIUS service is not running${NC}"
        return 1
    fi
}

# Restart FreeRADIUS service
restart_freeradius() {
    log "Restarting FreeRADIUS service..."
    systemctl restart freeradius
    
    if systemctl is-active --quiet freeradius; then
        log "FreeRADIUS service restarted successfully!"
        return 0
    else
        error "FreeRADIUS service failed to restart. Check logs for errors."
        systemctl status freeradius
        return 1
    fi
}
