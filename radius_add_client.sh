#!/bin/bash

# FreeRADIUS Client Management Script
# Usage: sudo bash radius_add_client.sh <shortname> <ip_address> <shared_secret> [nastype]

# Check if script is run as root
if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root (sudo)"
    exit 1
fi

# Check arguments
if [ $# -lt 3 ]; then
    echo "Usage: $0 <shortname> <ip_address> <shared_secret> [nastype]"
    echo "Example: $0 vpn_server 192.168.1.10 mysecret openvpn"
    echo ""
    echo "Common nastypes: other, cisco, livingston, computone, max40xx, multitech, alteon, netserver, pathras, patton, portslave, tc, usrhiper, 3com, ascend, bay, juniper, mikrotik, openvpn"
    exit 1
fi

SHORTNAME=$1
IPADDR=$2
SECRET=$3
NASTYPE=${4:-"other"}  # Default NAS type is "other" if not specified

# Check if clients.conf exists
CLIENTS_CONF="/etc/freeradius/3.0/clients.conf"
if [ ! -f "$CLIENTS_CONF" ]; then
    echo "Error: FreeRADIUS clients.conf not found at $CLIENTS_CONF"
    echo "Make sure FreeRADIUS is correctly installed."
    exit 1
fi

# Check if client already exists
if grep -q "client $SHORTNAME {" "$CLIENTS_CONF"; then
    echo "Warning: Client '$SHORTNAME' already exists in clients.conf"
    echo "Updating existing client configuration..."
    # Remove existing client config
    sed -i "/client $SHORTNAME {/,/}/d" "$CLIENTS_CONF"
fi

# Add new client to clients.conf
echo "Adding client '$SHORTNAME' ($IPADDR) to FreeRADIUS configuration..."
cat >> "$CLIENTS_CONF" << EOF

client $SHORTNAME {
    ipaddr = $IPADDR
    secret = $SECRET
    shortname = $SHORTNAME
    nastype = $NASTYPE
    require_message_authenticator = no
}
EOF

# Set proper permissions
chown freerad:freerad "$CLIENTS_CONF" 2>/dev/null || true
chmod 640 "$CLIENTS_CONF" 2>/dev/null || true

# Restart FreeRADIUS to apply changes
echo "Restarting FreeRADIUS service to apply changes..."
if systemctl is-active --quiet freeradius; then
    systemctl restart freeradius
    echo "FreeRADIUS restarted successfully."
else
    echo "Warning: FreeRADIUS service is not running."
    echo "You need to start it with: sudo systemctl start freeradius"
fi

echo "Client '$SHORTNAME' added successfully."
NASTYPE=${4:-"other"}  # Default NAS type is "other" if not specified

echo "==============================================="
echo "Adding RADIUS client: $SHORTNAME ($IPADDR)"
echo "==============================================="

# Function to check if client already exists
client_exists() {
    if grep -q "client $SHORTNAME {" /etc/freeradius/3.0/clients.conf; then
        return 0  # True, client exists
    else
        return 1  # False, client doesn't exist
    fi
}

# Check if client already exists
if client_exists; then
    echo "Client $SHORTNAME already exists. Updating..."
    # Create a temporary file
    TEMP_FILE=$(mktemp)
    
    # Extract the existing client block
    awk -v client="$SHORTNAME" '
    BEGIN { printing = 0; found = 0; }
    $1 == "client" && $2 == client" {" { found = 1; }
    { if (found) { printing = 1; } }
    printing == 1 { print; }
    printing == 1 && $0 == "}" { printing = 0; found = 0; exit; }
    ' /etc/freeradius/3.0/clients.conf > $TEMP_FILE
    
    # Remove the client section
    sed -i "/client $SHORTNAME {/,/}/d" /etc/freeradius/3.0/clients.conf
else
    echo "Adding new client: $SHORTNAME"
fi

# Add client to clients.conf
cat >> /etc/freeradius/3.0/clients.conf << EOF

client $SHORTNAME {
    ipaddr = $IPADDR
    secret = $SECRET
    shortname = $SHORTNAME
    nastype = $NASTYPE
    require_message_authenticator = no
}
EOF

# If client also exists in database, update PostgreSQL too
if command -v psql &> /dev/null; then
    # Check if PostgreSQL schema includes NAS table
    NAS_TABLE_EXISTS=$(su - postgres -c "psql -t -c \"SELECT to_regclass('nas');\" radius" 2>/dev/null)
    
    if [[ "$NAS_TABLE_EXISTS" != *"NULL"* ]]; then
        echo "Updating PostgreSQL NAS table..."
        
        # Check if this client already exists in the NAS table
        NAS_EXISTS=$(su - postgres -c "psql -t -c \"SELECT COUNT(*) FROM nas WHERE shortname='$SHORTNAME';\" radius" 2>/dev/null)
        
        if [ "$(echo $NAS_EXISTS | tr -d ' ')" -gt 0 ]; then
            # Update existing entry
            su - postgres -c "psql -c \"UPDATE nas SET nasname='$IPADDR', secret='$SECRET', type='$NASTYPE' WHERE shortname='$SHORTNAME';\" radius"
        else
            # Insert new entry
            su - postgres -c "psql -c \"INSERT INTO nas (nasname, shortname, type, secret, description) VALUES ('$IPADDR', '$SHORTNAME', '$NASTYPE', '$SECRET', 'Added by script');\" radius"
        fi
    fi
fi

# Set proper permissions
chown freerad:freerad /etc/freeradius/3.0/clients.conf
chmod 640 /etc/freeradius/3.0/clients.conf

# Restart FreeRADIUS service
echo "Restarting FreeRADIUS service..."
systemctl restart freeradius

# Check service status
if systemctl is-active --quiet freeradius; then
    echo "FreeRADIUS restarted successfully!"
else
    echo "ERROR: FreeRADIUS service failed to restart. Checking for errors..."
    systemctl status freeradius
    echo "Configuration error may exist. Reverting changes..."
    
    # Revert to backup if service failed to start
    if [ -f /etc/freeradius/3.0/clients.conf.bak ]; then
        cp /etc/freeradius/3.0/clients.conf.bak /etc/freeradius/3.0/clients.conf
        systemctl restart freeradius
        echo "Reverted to previous configuration."
    fi
    
    exit 1
fi

echo
echo "==============================================="
echo "RADIUS client added successfully!"
echo "Name: $SHORTNAME"
echo "IP address: $IPADDR"
echo "Secret: $SECRET"
echo "NAS type: $NASTYPE"
echo "==============================================="
