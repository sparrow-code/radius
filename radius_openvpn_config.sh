#!/bin/bash

# FreeRADIUS OpenVPN Integration Script
# This script configures FreeRADIUS to work with OpenVPN for authentication
# Usage: sudo bash radius_openvpn_config.sh

# Check if script is run as root
if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root (sudo)"
    exit 1
fi

echo "==============================================="
echo "Configuring RADIUS for OpenVPN Integration"
echo "==============================================="

# Function to display progress
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

# Check if FreeRADIUS is installed
if ! command -v freeradius &> /dev/null && ! command -v radiusd &> /dev/null; then
    log "ERROR: FreeRADIUS is not installed. Please run install_freeradius.sh first."
    exit 1
fi

# Backup current configuration
log "Creating backup of current configuration..."
timestamp=$(date +%Y%m%d-%H%M%S)
cp /etc/freeradius/3.0/sites-available/default /etc/freeradius/3.0/sites-available/default.bak.$timestamp

# Configure OpenVPN-specific settings
log "Configuring OpenVPN-specific settings..."

# Create OpenVPN policy
cat > /etc/freeradius/3.0/policy.d/openvpn << EOF
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
        reject "Invalid username format"
    }
}
EOF

# Update the clients.conf with OpenVPN server information
log "Updating clients.conf for OpenVPN..."

# Check if OpenVPN server IP exists in config
OPENVPN_SERVER_IP=$(ip addr | grep -oP 'inet \K[\d.]+' | grep -v '127.0.0.1' | head -n 1)

# Prompt for OpenVPN server IP if needed
read -p "Enter OpenVPN server IP address [$OPENVPN_SERVER_IP]: " input_ip
OPENVPN_SERVER_IP=${input_ip:-$OPENVPN_SERVER_IP}

# Prompt for shared secret
read -p "Enter shared secret for RADIUS-OpenVPN communication [vpn_radius_secret]: " input_secret
SHARED_SECRET=${input_secret:-"vpn_radius_secret"}

# Check if OpenVPN client already exists in clients.conf
if ! grep -q "client openvpn_server " /etc/freeradius/3.0/clients.conf; then
    log "Adding OpenVPN server as RADIUS client..."
    cat >> /etc/freeradius/3.0/clients.conf << EOF

client openvpn_server {
    ipaddr = $OPENVPN_SERVER_IP
    secret = $SHARED_SECRET
    shortname = openvpn
    nastype = openvpn
    require_message_authenticator = no
}
EOF
else
    log "OpenVPN server already configured in clients.conf"
    # Update the existing entry
    sed -i "/client openvpn_server {/,/}/{s/ipaddr = .*/ipaddr = $OPENVPN_SERVER_IP/;s/secret = .*/secret = $SHARED_SECRET/}" /etc/freeradius/3.0/clients.conf
fi

# Update the default site configuration to include our OpenVPN policy
log "Updating default site configuration..."
sed -i '/^authenticate {/,/^}/ s/^}$/    openvpn\n}/' /etc/freeradius/3.0/sites-available/default

# Create OpenVPN server configuration with RADIUS authentication
log "Creating OpenVPN RADIUS authentication plugin configuration..."

# Check for OpenVPN installation
if [ ! -d "/etc/openvpn" ]; then
    log "WARNING: OpenVPN directory not found. Creating /etc/openvpn directory..."
    mkdir -p /etc/openvpn
fi

cat > /etc/openvpn/radiusplugin.cnf << EOF
# OpenVPN RADIUS plugin configuration
# This file is used by the OpenVPN RADIUS plugin for authentication

# RADIUS server configuration
server
{
    # RADIUS server address
    acctserver = $OPENVPN_SERVER_IP:1813
    authserver = $OPENVPN_SERVER_IP:1812
    
    # Shared secret
    secret = $SHARED_SECRET
    
    # Timeout and retry parameters
    timeout = 3
    retry = 1
    
    # NAS identifier
    nasid = OpenVPN
    
    # NAS port type
    nasporttype = 5 # Virtual
}

# General plugin settings
general
{
    # Authentication via RADIUS
    mode = auth
    
    # Accounting for sessions
    sessionstartaccounting = yes
    sessionstopaccounting = yes
    
    # Authentication result log file
    # Note: This file needs write permission for OpenVPN
    logfile = /var/log/openvpn/radius.log
}

# Attributes for RADIUS authentication
authentication
{
    # User-Name sent to RADIUS server
    username = %u
    
    # Service-Type attribute
    service-type = 5 # NAS-Prompt
}

# Attributes for RADIUS accounting
accounting
{
    # User-Name sent to RADIUS server
    username = %u
}
EOF

# Create directory for RADIUS plugin logs
mkdir -p /var/log/openvpn/
touch /var/log/openvpn/radius.log
chmod 644 /var/log/openvpn/radius.log
chown nobody:nogroup /var/log/openvpn/radius.log

# Update OpenVPN server.conf with RADIUS configuration
log "Creating instructions to update OpenVPN server configuration..."

cat > /etc/freeradius/3.0/openvpn_radius_config.txt << EOF
=====================================
OpenVPN Configuration Instructions
=====================================

To enable RADIUS authentication in OpenVPN, follow these steps:

1. Install the OpenVPN RADIUS plugin:

   sudo apt-get install openvpn-auth-radius

2. Add the following lines to your OpenVPN server configuration file (/etc/openvpn/server.conf):

   # RADIUS Authentication
   plugin /usr/lib/openvpn/radiusplugin.so /etc/openvpn/radiusplugin.cnf
   
   # If you want to use both RADIUS and certificate authentication:
   verify-client-cert require
   
   # Or if you want to use RADIUS authentication only (no certificates required for clients):
   # verify-client-cert none
   # client-cert-not-required

3. Restart the OpenVPN server:

   sudo systemctl restart openvpn@server

4. RADIUS server information:
   - Server IP: $OPENVPN_SERVER_IP
   - Authentication port: 1812
   - Accounting port: 1813
   - Shared secret: $SHARED_SECRET

=====================================
EOF

# Set proper permissions for all configurations
log "Setting proper file permissions..."
chown -R freerad:freerad /etc/freeradius/3.0/policy.d/openvpn
chmod 640 /etc/freeradius/3.0/policy.d/openvpn
chmod 640 /etc/openvpn/radiusplugin.cnf

# Restart FreeRADIUS service
log "Restarting FreeRADIUS service..."
systemctl restart freeradius

# Check if service is running
if systemctl is-active --quiet freeradius; then
    log "FreeRADIUS service restarted successfully!"
else
    log "ERROR: FreeRADIUS service failed to restart. Check logs for errors."
    systemctl status freeradius
    exit 1
fi

echo
echo "==============================================="
echo "RADIUS-OpenVPN integration configuration complete!"
echo "==============================================="
echo
echo "OpenVPN configuration instructions have been saved to:"
echo "/etc/freeradius/3.0/openvpn_radius_config.txt"
echo
echo "Don't forget to install the RADIUS plugin for OpenVPN:"
echo "sudo apt-get install openvpn-auth-radius"
echo
echo "After updating OpenVPN configuration, restart the service:"
echo "sudo systemctl restart openvpn@server"
echo "==============================================="
