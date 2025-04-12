#!/bin/bash
# Client Management module for FreeRADIUS Manager

# Manage RADIUS clients (list, add, delete)
manage_clients() {
    local action=$1
    shift
    
    # Ensure FreeRADIUS is installed
    if ! check_freeradius_installed; then
        return 1
    fi
    
    case $action in
        list)
            list_clients
            ;;
        add)
            if [ $# -lt 3 ]; then
                error "Usage: radius.sh client add <shortname> <ipaddr> <secret> [nastype]"
                return 1
            fi
            local nastype=${4:-other}
            add_client "$1" "$2" "$3" "$nastype"
            ;;
        delete)
            if [ $# -lt 1 ]; then
                error "Usage: radius.sh client delete <shortname>"
                return 1
            fi
            delete_client "$1"
            ;;
        *)
            error "Unknown client action: $action"
            echo "Available actions: list, add, delete"
            return 1
            ;;
    esac
    
    return 0
}

# List all RADIUS clients
list_clients() {
    section "RADIUS Client List"
    
    local config_dir=$(find_freeradius_dir)
    local clients_conf="$config_dir/clients.conf"
    
    if [ ! -f "$clients_conf" ]; then
        error "Clients configuration file not found: $clients_conf"
        return 1
    fi
    
    log "Listing RADIUS clients from $clients_conf:"
    echo
    
    # Extract client information
    grep -A5 "^client" "$clients_conf" | grep -E "client |ipaddr|secret|shortname|nastype" | sed 's/^[[:space:]]*//'
    echo
    
    # Check if PostgreSQL is used and has a nas table
    if systemctl is-active --quiet postgresql; then
        if su - postgres -c "psql -t -c \"SELECT to_regclass('nas');\" radius" | grep -q -v "NULL"; then
            log "Clients in database:"
            echo
            su - postgres -c "psql -c \"SELECT nasname, shortname, secret, type FROM nas;\" radius" || true
        fi
    fi
    
    return 0
}

# Add or update a RADIUS client
add_client() {
    local shortname="$1"
    local ipaddr="$2"
    local secret="$3"
    local nastype="$4"
    
    section "Add/Update Client"
    log "Processing client: $shortname"
    
    local config_dir=$(find_freeradius_dir)
    local clients_conf="$config_dir/clients.conf"
    
    if [ ! -f "$clients_conf" ]; then
        error "Clients configuration file not found: $clients_conf"
        return 1
    fi
    
    # Check if client already exists
    if grep -q "client $shortname {" "$clients_conf"; then
        log "Client already exists. Updating..."
        # Update existing client
        sed -i "/client $shortname {/,/}/{s/ipaddr = .*/ipaddr = $ipaddr/;s/secret = .*/secret = $secret/;s/nastype = .*/nastype = $nastype/}" "$clients_conf"
    else
        log "Adding new client..."
        # Append new client
        cat >> "$clients_conf" << EOF

client $shortname {
    ipaddr = $ipaddr
    secret = $secret
    shortname = $shortname
    nastype = $nastype
    require_message_authenticator = no
}
EOF
    fi
    
    # Update database if available
    if systemctl is-active --quiet postgresql; then
        if su - postgres -c "psql -t -c \"SELECT to_regclass('nas');\" radius" | grep -q -v "NULL"; then
            log "Updating client in database..."
            local nas_exists=$(su - postgres -c "psql -t -c \"SELECT COUNT(*) FROM nas WHERE shortname='$shortname';\" radius" | xargs)
            
            if [ "$nas_exists" -gt 0 ]; then
                su - postgres -c "psql -c \"UPDATE nas SET nasname='$ipaddr', secret='$secret', type='$nastype' WHERE shortname='$shortname';\" radius" || true
            else
                su - postgres -c "psql -c \"INSERT INTO nas (nasname, shortname, type, secret, description) VALUES ('$ipaddr', '$shortname', '$nastype', '$secret', 'Added by radius manager');\" radius" || true
            fi
        fi
    fi
    
    log "Client $shortname has been added/updated successfully!"
    
    # Restart the service to apply changes
    systemctl restart freeradius
    
    return 0
}

# Delete a RADIUS client
delete_client() {
    local shortname="$1"
    
    section "Delete Client"
    log "Deleting client: $shortname"
    
    local config_dir=$(find_freeradius_dir)
    local clients_conf="$config_dir/clients.conf"
    
    if [ ! -f "$clients_conf" ]; then
        error "Clients configuration file not found: $clients_conf"
        return 1
    fi
    
    # Delete client from config file
    if grep -q "client $shortname {" "$clients_conf"; then
        log "Removing client from configuration file..."
        sed -i "/client $shortname {/,/^}/d" "$clients_conf"
    else
        warn "Client not found in configuration file."
    fi
    
    # Delete from database if available
    if systemctl is-active --quiet postgresql; then
        if su - postgres -c "psql -t -c \"SELECT to_regclass('nas');\" radius" | grep -q -v "NULL"; then
            log "Removing client from database..."
            su - postgres -c "psql -c \"DELETE FROM nas WHERE shortname='$shortname';\" radius" || true
        fi
    fi
    
    log "Client $shortname has been deleted."
    
    # Restart the service to apply changes
    systemctl restart freeradius
    
    return 0
}
