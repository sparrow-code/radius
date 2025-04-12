#!/bin/bash

# Constants for RADIUS management scripts
# This file contains shared constants used across RADIUS management scripts

# Default database settings
DB_NAME="radius"
DB_USER="radius"
DB_PASS="radpass"

# Default RADIUS settings
RADIUS_SECRET="testing123"
RADIUS_PORT_AUTH="1812"
RADIUS_PORT_ACCT="1813"

# Default paths
CONFIG_DIR_CANDIDATES=(
    "/etc/freeradius/3.0"
    "/etc/freeradius"
    "/etc/raddb"
)

LOG_DIR="/var/log/radius"
LOG_FILE="$LOG_DIR/radius.log"

# Script information
SCRIPT_VERSION="1.0.0"
SCRIPT_NAME="radius"
