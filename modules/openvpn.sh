#!/bin/bash
# OpenVPN integration module for FreeRADIUS Manager

# Configure OpenVPN integration with RADIUS
configure_openvpn() {
    section "OpenVPN Integration"
    
    # Ensure FreeRADIUS is installed
    if ! check_freeradius_installed; then
        return 1
    fi
    
    # Check if OpenVPN is installed
    if ! command_exists openvpn; then
        warn "OpenVPN is not installed. Installing..."
        apt-get update -qq
        apt-get install -y openvpn openvpn-auth-radius
    fi
    
    if ! command_exists openvpn; then
        error "Failed to install OpenVPN. Please install it manually."
        return 1
    fi
    
    # Get OpenVPN server IP
    OPENVPN_IP=$(ip addr show tun0 2>/dev/null | grep -oP 'inet \K[\d.]+' || echo "")
    if [ -z "$OPENVPN_IP" ]; then
        # If tun0 doesn't exist, use server's main IP
        OPENVPN_IP=$(ip addr | grep -oP 'inet \K[\d.]+' | grep -v '127.0.0.1' | head -n 1)
    fi
    
    echo -e "Detected OpenVPN IP: ${GREEN}$OPENVPN_IP${NC}"
    read -p "Use this IP? [Y/n]: " use_detected_ip
    if [[ $use_detected_ip =~ ^[Nn]$ ]]; then
        read -p "Enter OpenVPN server IP: " OPENVPN_IP
    fi
    
    # Get shared secret
    read -p "Enter shared secret for RADIUS-OpenVPN [vpn_radius_secret]: " SHARED_SECRET
    SHARED_SECRET=${SHARED_SECRET:-vpn_radius_secret}
    
    # Configure FreeRADIUS for OpenVPN
    configure_radius_for_openvpn "$OPENVPN_IP" "$SHARED_SECRET"
    
    # Configure OpenVPN for RADIUS
    configure_openvpn_for_radius "$SHARED_SECRET"
    
    return 0
}

# Configure FreeRADIUS for OpenVPN
configure_radius_for_openvpn() {
    local openvpn_ip="$1"
    local shared_secret="$2"
    
    log "Configuring FreeRADIUS for OpenVPN..."
    
    local config_dir=$(find_freeradius_dir)
    
    # Add OpenVPN client to clients.conf
    if [ -f "$config_dir/clients.conf" ]; then
        # Check if OpenVPN client already exists
        if grep -q "client openvpn_server" "$config_dir/clients.conf"; then
            log "Updating OpenVPN client in clients.conf..."
            sed -i "/client openvpn_server {/,/^}/c\
client openvpn_server {\n\
    ipaddr = $openvpn_ip\n\
    secret = $shared_secret\n\
    shortname = openvpn\n\
    nastype = other\n\
    require_message_authenticator = no\n\
}" "$config_dir/clients.conf"
        else
            log "Adding OpenVPN client to clients.conf..."
            cat >> "$config_dir/clients.conf" << EOF

client openvpn_server {
    ipaddr = $openvpn_ip
    secret = $shared_secret
    shortname = openvpn
    nastype = other
    require_message_authenticator = no
}
EOF
        fi
    fi
    
    # Create OpenVPN policy
    log "Creating OpenVPN policy..."
    mkdir -p "$config_dir/policy.d"
    
    cat > "$config_dir/policy.d/openvpn" << EOF
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
    
    # Update site configuration
    log "Updating site configuration..."
    local default_site="$config_dir/sites-available/default"
    if [ -f "$default_site" ]; then
        if ! grep -q "openvpn" "$default_site"; then
            sed -i '/^authenticate {/,/^}/ s/^}$/    openvpn\n}/' "$default_site"
        fi
    fi
    
    # Create instructions for OpenVPN configuration
    log "Creating OpenVPN configuration instructions..."
    cat > "$config_dir/openvpn_radius_config.txt" << EOF
=====================================
OpenVPN Configuration Instructions
=====================================

To enable RADIUS authentication in OpenVPN, follow these steps:

1. Install the OpenVPN RADIUS plugin:

   sudo apt-get install openvpn-auth-radius

2. Create a RADIUS configuration file for OpenVPN:

   sudo mkdir -p /etc/openvpn/radiusplugin
   sudo nano /etc/openvpn/radiusplugin/radiusplugin.cnf

3. Add the following content to the file:

   # RADIUS plugin configuration
   NAS-Identifier=OpenVPN
   Service-Type=5
   Framed-Protocol=1
   NAS-Port-Type=5
   NAS-IP-Address=SERVER_IP
   OpenVPNConfig=/etc/openvpn/server.conf
   subnet=255.255.255.0
   overwriteccfiles=true
   server
   {
       acctport=1813
       authport=1812
       name=127.0.0.1
       retry=1
       wait=1
       secret=$shared_secret
   }

4. Edit your OpenVPN server configuration to use RADIUS authentication:

   sudo nano /etc/openvpn/server.conf

5. Add the following lines to your OpenVPN configuration:

   # RADIUS authentication
   plugin /usr/lib/openvpn/radiusplugin.so /etc/openvpn/radiusplugin/radiusplugin.cnf

6. Restart OpenVPN:

   sudo systemctl restart openvpn

=====================================
EOF
    
    # Restart FreeRADIUS to apply changes
    log "Restarting FreeRADIUS to apply changes..."
    systemctl restart freeradius
    
    log "FreeRADIUS has been configured for OpenVPN integration."
    
    return 0
}

# Configure OpenVPN for RADIUS
configure_openvpn_for_radius() {
    local shared_secret="$1"
    
    log "Configuring OpenVPN for RADIUS authentication..."
    
    # Check if OpenVPN is installed and running
    if ! systemctl is-active --quiet openvpn; then
        warn "OpenVPN service is not active. Skipping OpenVPN configuration."
        echo -e "${YELLOW}Please install and configure OpenVPN first, then run this script again.${NC}"
        return 1
    fi
    
    # Create RADIUS plugin directory and configuration
    mkdir -p /etc/openvpn/radiusplugin
    
    # Get server IP
    SERVER_IP=$(ip addr | grep -oP 'inet \K[\d.]+' | grep -v '127.0.0.1' | head -n 1)
    
    # Create RADIUS plugin configuration
    cat > /etc/openvpn/radiusplugin/radiusplugin.cnf << EOF
# RADIUS plugin configuration for OpenVPN
NAS-Identifier=OpenVPN
Service-Type=5
Framed-Protocol=1
NAS-Port-Type=5
NAS-IP-Address=$SERVER_IP
OpenVPNConfig=/etc/openvpn/server.conf
subnet=255.255.255.0
overwriteccfiles=true
server
{
    acctport=1813
    authport=1812
    name=127.0.0.1
    retry=1
    wait=1
    secret=$shared_secret
}
EOF
    
    # Find OpenVPN server configuration
    local server_conf=$(find /etc/openvpn -name "*.conf" | grep -i server | head -n1)
    
    if [ -z "$server_conf" ]; then
        warn "Could not find OpenVPN server configuration."
        echo -e "${YELLOW}Please make sure OpenVPN server is installed and configured.${NC}"
        return 1
    fi
    
    log "Found OpenVPN server configuration at $server_conf"
    
    # Check if RADIUS plugin is already configured
    if grep -q "radiusplugin.so" "$server_conf"; then
        log "RADIUS plugin is already configured in $server_conf"
    else
        log "Adding RADIUS plugin configuration to $server_conf"
        
        # Backup original config
        cp -a "$server_conf" "$server_conf.bak.$(date +%Y%m%d%H%M%S)"
        
        # Add RADIUS plugin configuration
        echo "" >> "$server_conf"
        echo "# RADIUS authentication" >> "$server_conf"
        echo "plugin /usr/lib/openvpn/radiusplugin.so /etc/openvpn/radiusplugin/radiusplugin.cnf" >> "$server_conf"
        
        # Set permissions
        chmod 644 "$server_conf"
    fi
    
    # Restart OpenVPN to apply changes
    log "Restarting OpenVPN to apply changes..."
    systemctl restart openvpn
    
    log "OpenVPN has been configured for RADIUS authentication."
    echo -e "${GREEN}OpenVPN and FreeRADIUS integration is complete!${NC}"
    
    return 0
}
