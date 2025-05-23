#!/bin/bash

# FreeRADIUS Manager Script
# This script provides a management interface for FreeRADIUS server
# Usage: sudo bash radius_manager.sh [option]

# Script directory
SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
UTILS_DIR="$SCRIPT_DIR/utils"

# Source common utilities
source "$UTILS_DIR/common.sh"

# Source constants for consistent configuration values
source "$UTILS_DIR/constants.sh"

# Check if running as root
check_root

# Load all module files with proper error handling
log "Loading modules..."
for module in "$SCRIPT_DIR/modules"/*.sh; do
    if [ -f "$module" ]; then
        module_name=$(basename "$module")
        log "Loading module: $module_name"
        source "$module" || {
            error "Failed to load module: $module_name"
            exit 1
        }
    fi
done

# Function to check if FreeRADIUS is installed
check_freeradius_installed() {
    if ! dpkg -l | grep -q freeradius; then
        error "FreeRADIUS is not installed. Please run the installation script first."
        echo -e "Run: ${GREEN}sudo bash ${SCRIPT_DIR}/install_freeradius.sh${NC}"
        return 1
    fi
    return 0
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

# Function to check if FreeRADIUS service is running
check_freeradius_status() {
    section "FreeRADIUS Service Status"
    
    if systemctl is-active --quiet freeradius; then
        echo -e "Status: ${GREEN}ACTIVE${NC}"
        systemctl status freeradius | grep -E "Active:|Main PID:|Tasks:" || true
        
        # Check if ports are listening
        echo -e "\nPort Status:"
        if command_exists ss; then
            ss -tuln | grep -E '1812|1813' || echo "Ports 1812 and 1813 are not listening"
        elif command_exists netstat; then
            netstat -tuln | grep -E '1812|1813' || echo "Ports 1812 and 1813 are not listening"
        fi
    else
        echo -e "Status: ${RED}INACTIVE${NC}"
        systemctl status freeradius | grep -E "Active:|Main PID:|Tasks:" || true
    fi
}

# Function to manage FreeRADIUS service
manage_service() {
    local action=$1
    
    section "FreeRADIUS Service Management"
    
    case $action in
        start)
            log "Starting FreeRADIUS service..."
            systemctl start freeradius
            ;;
        stop)
            log "Stopping FreeRADIUS service..."
            systemctl stop freeradius
            ;;
        restart)
            log "Restarting FreeRADIUS service..."
            systemctl restart freeradius
            ;;
        reload)
            log "Reloading FreeRADIUS configuration..."
            systemctl reload freeradius || systemctl restart freeradius
            ;;
        *)
            error "Invalid service action: $action"
            echo "Valid actions: start, stop, restart, reload"
            return 1
            ;;
    esac
    
    sleep 2
    check_freeradius_status
}

# Function to add or modify a RADIUS user
manage_users() {
    local action=$1
    shift
    
    section "User Management"
    
    case $action in
        list)
            log "Listing all RADIUS users..."
            su - postgres -c "psql -c \"SELECT username, attribute, value FROM radcheck WHERE attribute='Cleartext-Password';\" radius" || true
            ;;
        add)
            if [ $# -lt 2 ]; then
                error "Usage: radius_manager.sh user add <username> <password> [group]"
                return 1
            fi
            
            local username=$1
            local password=$2
            local group=${3:-}
            
            log "Adding/updating user: $username"
            
            # Check if user exists
            local user_exists=$(su - postgres -c "psql -t -c \"SELECT COUNT(*) FROM radcheck WHERE username='$username' AND attribute='Cleartext-Password';\" radius" | xargs)
            
            if [ "$user_exists" -gt 0 ]; then
                log "User already exists. Updating password..."
                su - postgres -c "psql -c \"UPDATE radcheck SET value='$password' WHERE username='$username' AND attribute='Cleartext-Password';\" radius" || true
            else
                log "Creating new user..."
                su - postgres -c "psql -c \"INSERT INTO radcheck (username, attribute, op, value) VALUES ('$username', 'Cleartext-Password', ':=', '$password');\" radius" || true
            fi
            
            # Add user to group if specified
            if [ -n "$group" ]; then
                log "Adding user to group: $group"
                
                # Check if group exists
                local group_exists=$(su - postgres -c "psql -t -c \"SELECT COUNT(*) FROM radgroupcheck WHERE groupname='$group';\" radius" | xargs)
                
                if [ "$group_exists" -eq 0 ]; then
                    log "Group $group does not exist. Creating group..."
                    su - postgres -c "psql -c \"INSERT INTO radgroupcheck (groupname, attribute, op, value) VALUES ('$group', 'Auth-Type', ':=', 'Local');\" radius" || true
                fi
                
                # Remove existing group assignments
                su - postgres -c "psql -c \"DELETE FROM radusergroup WHERE username='$username';\" radius" || true
                
                # Add to new group
                su - postgres -c "psql -c \"INSERT INTO radusergroup (username, groupname, priority) VALUES ('$username', '$group', 1);\" radius" || true
            fi
            
            log "User $username has been added/updated successfully!"
            ;;
        delete)
            if [ $# -lt 1 ]; then
                error "Usage: radius_manager.sh user delete <username>"
                return 1
            fi
            
            local username=$1
            
            log "Deleting user: $username"
            
            # Delete user from tables
            su - postgres -c "psql -c \"DELETE FROM radcheck WHERE username='$username';\" radius" || true
            su - postgres -c "psql -c \"DELETE FROM radreply WHERE username='$username';\" radius" || true
            su - postgres -c "psql -c \"DELETE FROM radusergroup WHERE username='$username';\" radius" || true
            
            log "User $username has been deleted!"
            ;;
        test)
            if [ $# -lt 2 ]; then
                error "Usage: radius_manager.sh user test <username> <password>"
                return 1
            fi
            
            local username=$1
            local password=$2
            
            log "Testing user authentication: $username"
            
            if ! command_exists radtest; then
                error "radtest command not found. Install FreeRADIUS utils first."
                return 1
            fi
            
            radtest "$username" "$password" localhost 0 testing123
            
            if [ $? -eq 0 ]; then
                log "Authentication test passed for user $username!"
            else
                error "Authentication test failed for user $username!"
            fi
            ;;
        *)
            error "Invalid user action: $action"
            echo "Valid actions: list, add, delete, test"
            return 1
            ;;
    esac
}

# Function to manage client configuration
manage_clients() {
    local action=$1
    shift
    
    section "Client Management"
    
    # Find clients.conf
    local CLIENTS_CONF=$(find /etc -name "clients.conf" | grep freeradius | head -n1)
    if [ ! -f "$CLIENTS_CONF" ]; then
        error "Cannot find clients.conf file."
        return 1
    fi
    
    case $action in
        list)
            log "Listing all RADIUS clients..."
            grep -A 1 "client " "$CLIENTS_CONF" | grep -v "^--$" || true
            
            # Also check database if available
            if su - postgres -c "psql -t -c \"SELECT to_regclass('nas');\" radius" | grep -q -v "NULL"; then
                log "Clients from database:"
                su - postgres -c "psql -c \"SELECT nasname, shortname, secret FROM nas;\" radius" || true
            fi
            ;;
        add)
            if [ $# -lt 3 ]; then
                error "Usage: radius_manager.sh client add <shortname> <ipaddr> <secret> [nastype]"
                return 1
            fi
            
            local shortname=$1
            local ipaddr=$2
            local secret=$3
            local nastype=${4:-"other"}
            
            log "Adding/updating client: $shortname"
            
            # Check if client already exists
            if grep -q "client $shortname {" "$CLIENTS_CONF"; then
                log "Client already exists. Updating..."
                sed -i "/client $shortname {/,/}/{s/ipaddr = .*/ipaddr = $ipaddr/;s/secret = .*/secret = $secret/;s/nastype = .*/nastype = $nastype/}" "$CLIENTS_CONF"
            else
                log "Adding new client..."
                cat >> "$CLIENTS_CONF" << EOF

client $shortname {
    ipaddr = $ipaddr
    secret = $secret
    shortname = $shortname
    nastype = $nastype
    require_message_authenticator = no
}
EOF
            fi
            
            # Also update database if available
            if su - postgres -c "psql -t -c \"SELECT to_regclass('nas');\" radius" | grep -q -v "NULL"; then
                log "Updating client in database..."
                local nas_exists=$(su - postgres -c "psql -t -c \"SELECT COUNT(*) FROM nas WHERE shortname='$shortname';\" radius" | xargs)
                
                if [ "$nas_exists" -gt 0 ]; then
                    su - postgres -c "psql -c \"UPDATE nas SET nasname='$ipaddr', secret='$secret', type='$nastype' WHERE shortname='$shortname';\" radius" || true
                else
                    su - postgres -c "psql -c \"INSERT INTO nas (nasname, shortname, type, secret, description) VALUES ('$ipaddr', '$shortname', '$nastype', '$secret', 'Added by radius_manager');\" radius" || true
                fi
            fi
            
            log "Client $shortname has been added/updated successfully!"
            ;;
        delete)
            if [ $# -lt 1 ]; then
                error "Usage: radius_manager.sh client delete <shortname>"
                return 1
            fi
            
            local shortname=$1
            
            log "Deleting client: $shortname"
            
            # Delete client from config file
            if grep -q "client $shortname {" "$CLIENTS_CONF"; then
                sed -i "/client $shortname {/,/}/d" "$CLIENTS_CONF"
                log "Client deleted from configuration file."
            else
                warn "Client not found in configuration file."
            fi
            
            # Also delete from database if available
            if su - postgres -c "psql -t -c \"SELECT to_regclass('nas');\" radius" | grep -q -v "NULL"; then
                log "Deleting client from database..."
                su - postgres -c "psql -c \"DELETE FROM nas WHERE shortname='$shortname';\" radius" || true
            fi
            
            log "Client $shortname has been deleted!"
            ;;
        *)
            error "Invalid client action: $action"
            echo "Valid actions: list, add, delete"
            return 1
            ;;
    esac
}

# Function to check the database connection
check_database_connection() {
    section "Database Connection"
    
    log "Testing PostgreSQL connection..."
    
    # Check if PostgreSQL is running
    if ! systemctl is-active --quiet postgresql; then
        error "PostgreSQL service is not running."
        return 1
    fi
    
    # Test connection
    if su - postgres -c "psql -c \"\\l\" | grep -q radius"; then
        log "PostgreSQL connection successful. Database 'radius' exists."
        
        # Check if tables exist
        TABLES_COUNT=$(su - postgres -c "psql -t -c \"SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='public';\" radius" | xargs)
        
        if [ "$TABLES_COUNT" -gt 0 ]; then
            log "Database has $TABLES_COUNT tables."
            
            # Check specific tables
            echo -e "\nChecking critical tables:"
            for table in radcheck radreply radgroupcheck radgroupreply radusergroup radacct nas; do
                EXISTS=$(su - postgres -c "psql -t -c \"SELECT to_regclass('$table');\" radius" | grep -v "NULL" | xargs)
                if [ -n "$EXISTS" ]; then
                    echo -e "  $table: ${GREEN}OK${NC}"
                else
                    echo -e "  $table: ${RED}MISSING${NC}"
                fi
            done
        else
            warn "Database exists but has no tables. Schema may not be loaded."
        fi
    else
        error "Cannot connect to PostgreSQL database 'radius'."
        echo "Connection details:"
        echo "  Database: radius"
        echo "  Username: radius"
        echo "  Password: radpass (default)"
        return 1
    fi
}

# Function to run diagnostics
run_diagnostics() {
    section "FreeRADIUS Diagnostics"
    
    # Check FreeRADIUS installation
    log "Checking FreeRADIUS installation..."
    if dpkg -l | grep -q freeradius; then
        echo -e "FreeRADIUS: ${GREEN}INSTALLED${NC}"
        dpkg -l | grep -E 'freeradius|freeradius-postgresql|freeradius-utils' | awk '{print "  ",$2,"(",$3,")"}'
    else
        echo -e "FreeRADIUS: ${RED}NOT INSTALLED${NC}"
    fi
    
    # Check service status
    check_freeradius_status
    
    # Check configuration directory
    log "Checking configuration files..."
    local config_dir=$(find_freeradius_dir)
    if [ -n "$config_dir" ]; then
        echo -e "Configuration directory: ${GREEN}$config_dir${NC}"
        
        # Check key files
        for file in clients.conf radiusd.conf mods-available/sql mods-enabled/sql sites-available/default sites-enabled/default; do
            if [ -f "$config_dir/$file" ]; then
                echo -e "  $file: ${GREEN}OK${NC}"
            else
                echo -e "  $file: ${RED}MISSING${NC}"
            fi
        done
    else
        echo -e "Configuration directory: ${RED}NOT FOUND${NC}"
    fi
    
    # Check database connection
    check_database_connection
    
    # Check log files
    log "Checking log files..."
    local log_file="/var/log/radius/radius.log"
    if [ -f "$log_file" ]; then
        echo -e "Log file: ${GREEN}$log_file${NC}"
        echo -e "\nLast 5 errors in log file:"
        grep -i "error" "$log_file" | tail -5 || echo "No errors found"
    else
        echo -e "Log file: ${RED}NOT FOUND${NC}"
        echo "Checking system log instead..."
        journalctl -u freeradius | grep -i "error" | tail -5 || echo "No errors found"
    fi
    
    # Check for common issues
    log "Checking for common issues..."
    
    # SELinux check
    if command_exists getenforce; then
        SELINUX=$(getenforce)
        if [ "$SELINUX" = "Enforcing" ]; then
            warn "SELinux is enabled and may be blocking FreeRADIUS."
            echo "Consider setting it to permissive mode with: setenforce 0"
        fi
    fi
    
    # Check for port conflicts
    if command_exists ss; then
        PORTS_IN_USE=$(ss -tuln | grep -E ':1812|:1813' | grep -v freeradius || echo "")
        if [ -n "$PORTS_IN_USE" ]; then
            warn "Ports 1812/1813 are in use by other services:"
            echo "$PORTS_IN_USE"
        fi
    fi
    
    # Check OpenVPN integration
    log "Checking OpenVPN integration..."
    if systemctl is-active --quiet openvpn; then
        echo -e "OpenVPN: ${GREEN}ACTIVE${NC}"
        
        # Check RADIUS client
        if [ -n "$config_dir" ] && [ -f "$config_dir/clients.conf" ] && grep -q "client openvpn_server" "$config_dir/clients.conf"; then
            echo -e "OpenVPN RADIUS client: ${GREEN}CONFIGURED${NC}"
        else
            echo -e "OpenVPN RADIUS client: ${RED}NOT CONFIGURED${NC}"
        fi
        
        # Check for RADIUS plugin in OpenVPN
        if grep -q "radiusplugin.so" /etc/openvpn/server.conf 2>/dev/null; then
            echo -e "OpenVPN RADIUS plugin: ${GREEN}CONFIGURED${NC}"
        else
            echo -e "OpenVPN RADIUS plugin: ${RED}NOT CONFIGURED${NC}"
        fi
    else
        echo -e "OpenVPN: ${YELLOW}INACTIVE${NC}"
    fi
}

# Function to view logs
view_logs() {
    local lines=${1:-20}
    
    section "FreeRADIUS Logs"
    
    local log_file="/var/log/radius/radius.log"
    if [ -f "$log_file" ]; then
        log "Showing last $lines lines from $log_file"
        tail -n "$lines" "$log_file"
    else
        log "Radius log file not found. Showing systemd logs instead."
        journalctl -u freeradius -n "$lines"
    fi
}

# Function to configure OpenVPN integration
configure_openvpn_integration() {
    section "OpenVPN Integration"
    
    if ! systemctl is-active --quiet openvpn; then
        warn "OpenVPN service is not active. Make sure OpenVPN is installed and configured."
    fi
    
    # Get OpenVPN IP
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
    
    # Check if radius_openvpn_config.sh exists
    if [ -f "${SCRIPT_DIR}/radius_openvpn_config.sh" ]; then
        log "Running OpenVPN configuration script..."
        
        # Suppress prompts by setting variables
        export OPENVPN_SERVER_IP="$OPENVPN_IP"
        export RADIUS_OPENVPN_SECRET="$SHARED_SECRET"
        export RADIUS_NONINTERACTIVE=1
        
        bash "${SCRIPT_DIR}/radius_openvpn_config.sh"
    else
        log "OpenVPN configuration script not found. Manually configuring..."
        
        # Find FreeRADIUS config directory
        local config_dir=$(find_freeradius_dir)
        if [ -z "$config_dir" ]; then
            error "Cannot find FreeRADIUS configuration directory."
            return 1
        fi
        
        # Update clients.conf
        local clients_conf="$config_dir/clients.conf"
        if [ -f "$clients_conf" ]; then
            log "Updating clients.conf for OpenVPN..."
            
            # Check if OpenVPN client already exists
            if grep -q "client openvpn_server " "$clients_conf"; then
                log "OpenVPN client already configured. Updating..."
                sed -i "/client openvpn_server {/,/}/{s/ipaddr = .*/ipaddr = $OPENVPN_IP/;s/secret = .*/secret = $SHARED_SECRET/}" "$clients_conf"
            else
                log "Adding OpenVPN server as RADIUS client..."
                cat >> "$clients_conf" << EOF

client openvpn_server {
    ipaddr = $OPENVPN_IP
    secret = $SHARED_SECRET
    shortname = openvpn
    nastype = other
    require_message_authenticator = no
}
EOF
            fi
            
            log "OpenVPN RADIUS client configuration updated."
        else
            error "clients.conf not found."
            return 1
        fi
        
        # Create OpenVPN policy if it doesn't exist
        local policy_dir="$config_dir/policy.d"
        if [ -d "$policy_dir" ]; then
            if [ ! -f "$policy_dir/openvpn" ]; then
                log "Creating OpenVPN policy..."
                cat > "$policy_dir/openvpn" << EOF
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
            fi
            
            # Update site configuration
            log "Updating site configuration..."
            local default_site="$config_dir/sites-available/default"
            if [ -f "$default_site" ]; then
                if ! grep -q "openvpn" "$default_site"; then
                    sed -i '/^authenticate {/,/^}/ s/^}$/    openvpn\n}/' "$default_site"
                fi
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

2. Add the following lines to your OpenVPN server configuration file (/etc/openvpn/server.conf):

   # RADIUS Authentication
   plugin /usr/lib/openvpn/radiusplugin.so /etc/openvpn/radiusplugin.cnf
   
   # If you want to use both RADIUS and certificate authentication:
   verify-client-cert require
   
   # Or if you want to use RADIUS authentication only (no certificates required for clients):
   # verify-client-cert none
   # client-cert-not-required

3. Create the RADIUS plugin configuration:

   sudo mkdir -p /etc/openvpn
   sudo cat > /etc/openvpn/radiusplugin.cnf << EOC
# OpenVPN RADIUS plugin configuration
server
{
    # RADIUS server address
    acctserver = $OPENVPN_IP:1813
    authserver = $OPENVPN_IP:1812
    
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

general
{
    # Authentication via RADIUS
    mode = auth
    
    # Accounting for sessions
    sessionstartaccounting = yes
    sessionstopaccounting = yes
    
    # Authentication result log file
    logfile = /var/log/openvpn/radius.log
}

authentication
{
    # User-Name sent to RADIUS server
    username = %u
    
    # Service-Type attribute
    service-type = 5 # NAS-Prompt
}

accounting
{
    # User-Name sent to RADIUS server
    username = %u
}
EOC

4. Create log directory:
   sudo mkdir -p /var/log/openvpn
   sudo touch /var/log/openvpn/radius.log
   sudo chmod 644 /var/log/openvpn/radius.log

5. Restart the OpenVPN server:

   sudo systemctl restart openvpn

=====================================
EOF

        log "OpenVPN integration configured. Instructions saved to:"
        echo "$config_dir/openvpn_radius_config.txt"
    fi
    
    # Restart FreeRADIUS
    systemctl restart freeradius
    
    if systemctl is-active --quiet freeradius; then
        log "FreeRADIUS restarted successfully!"
    else
        error "FreeRADIUS failed to restart. Check logs for details."
    fi
}

# Function to fix common issues
fix_common_issues() {
# Function to fix permissions for FreeRADIUS configuration files
fix_permissions() {
    section "Fixing Permissions for FreeRADIUS"
    
    local config_dir=$(find_freeradius_dir)
    if [ -n "$config_dir" ]; then
        log "Setting correct permissions for configuration files..."
        sudo chown root:freerad "$config_dir"/*.conf
        sudo chmod 640 "$config_dir"/*.conf
        sudo find "$config_dir" -type d -exec chmod 755 {} \;
        sudo find "$config_dir" -type f -exec chmod 644 {} \;
        sudo find "$config_dir" -name "*.conf" -exec chmod 640 {} \;
        sudo chown -R freerad:freerad "$config_dir"
        
        log "Permissions updated for FreeRADIUS configuration files."
    else
        error "Cannot find FreeRADIUS configuration directory."
        return 1
    fi
}

# Function to configure connection to external PostgreSQL database
configure_external_db() {
    section "Configuring External PostgreSQL Database"
    
    local config_dir=$(find_freeradius_dir)
    if [ -n "$config_dir" ]; then
        log "Updating SQL module configuration for external database..."
        
        # Prompt for database connection details
        read -p "Enter PostgreSQL server IP or hostname [160.191.14.56]: " db_host
        db_host=${db_host:-160.191.14.56}
        
        read -p "Enter PostgreSQL port [5432]: " db_port
        db_port=${db_port:-5432}
        
        read -p "Enter PostgreSQL database name [radius_db]: " db_name
        db_name=${db_name:-radius_db}
        
        read -p "Enter PostgreSQL username [freerad]: " db_user
        db_user=${db_user:-freerad}
        
        read -p "Enter PostgreSQL password [radpass]: " db_pass
        db_pass=${db_pass:-radpass}
        
        # Update the SQL module configuration file
        if [ -f "$config_dir/mods-available/sql" ]; then
            sudo sed -i "s/server = \"localhost\"/server = \"$db_host\"/" "$config_dir/mods-available/sql"
            sudo sed -i "s/port = 5432/port = $db_port/" "$config_dir/mods-available/sql"
            sudo sed -i "s/database = \"radius\"/database = \"$db_name\"/" "$config_dir/mods-available/sql"
            sudo sed -i "s/login = \"radius\"/login = \"$db_user\"/" "$config_dir/mods-available/sql"
            sudo sed -i "s/password = \"radpass\"/password = \"$db_pass\"/" "$config_dir/mods-available/sql"
            
            log "SQL module configuration updated for external database."
            
            # Enable SQL module if not already enabled
            if [ ! -L "$config_dir/mods-enabled/sql" ]; then
                sudo ln -sf ../mods-available/sql "$config_dir/mods-enabled/sql"
                log "SQL module enabled."
            fi
        else
            warn "SQL module configuration file not found."
            return 1
        fi
    else
        error "Cannot find FreeRADIUS configuration directory."
        return 1
    fi
}
    section "Fix Common Issues"
# Function to fix common issues
fix_common_issues() {
    section "Fix Common Issues"
    
    log "Running diagnostics to identify issues..."
    
    # Check service status
    if ! systemctl is-active --quiet freeradius; then
        warn "FreeRADIUS service is not running."
    fi
    
    # Check database connection
    if ! su - postgres -c "psql -c \"\\l\" | grep -q radius"; then
        warn "PostgreSQL radius database not found or cannot connect."
    fi
    
    # Check for SQL module
    local config_dir=$(find_freeradius_dir)
    if [ -n "$config_dir" ]; then
        if [ ! -L "$config_dir/mods-enabled/sql" ]; then
            warn "SQL module not enabled."
            
            if [ -f "$config_dir/mods-available/sql" ]; then
                log "Enabling SQL module..."
                sudo ln -sf ../mods-available/sql "$config_dir/mods-enabled/sql"
            else
                warn "SQL module not found in mods-available."
            fi
        fi
    fi
    
    # Fix permissions using the dedicated function
    fix_permissions
    
    # Configure external database if needed
    read -p "Do you want to configure connection to an external PostgreSQL database? [y/N]: " config_db
    if [[ $config_db =~ ^[Yy]$ ]]; then
        configure_external_db
    fi
    
    # Run the comprehensive fix script if available
    if [ -f "${SCRIPT_DIR}/fix_freeradius_install_updated.sh" ]; then
        log "Running comprehensive fix script..."
        read -p "Do you want to run the comprehensive fix script? This will attempt to repair the entire installation. [y/N]: " run_fix
        if [[ $run_fix =~ ^[Yy]$ ]]; then
            bash "${SCRIPT_DIR}/fix_freeradius_install_updated.sh"
            return
        fi
    fi
    
    # Restart service
    log "Restarting FreeRADIUS service..."
    sudo systemctl restart freeradius
    
    if systemctl is-active --quiet freeradius; then
        log "FreeRADIUS service is now running!"
    else
        error "FreeRADIUS service failed to start. Checking logs..."
        sudo journalctl -u freeradius -n 20
    fi
}
    
    log "Running diagnostics to identify issues..."
    
    # Check service status
    if ! systemctl is-active --quiet freeradius; then
        warn "FreeRADIUS service is not running."
    fi
    
    # Check database connection
    if ! su - postgres -c "psql -c \"\\l\" | grep -q radius"; then
        warn "PostgreSQL radius database not found or cannot connect."
    fi
    
    # Check for SQL module
    local config_dir=$(find_freeradius_dir)
    if [ -n "$config_dir" ]; then
        if [ ! -L "$config_dir/mods-enabled/sql" ]; then
            warn "SQL module not enabled."
            
            if [ -f "$config_dir/mods-available/sql" ]; then
                log "Enabling SQL module..."
                ln -sf ../mods-available/sql "$config_dir/mods-enabled/sql"
            else
                warn "SQL module not found in mods-available."
            fi
        fi
    fi
    
    # Check for permission issues
    log "Checking and fixing permissions..."
    FREERADIUS_USER=$(ps -ef | grep freeradius | grep -v grep | head -1 | awk '{print $1}')
    FREERADIUS_USER=${FREERADIUS_USER:-"freerad"}
    
    # Fix permissions
    if [ -n "$config_dir" ]; then
        find "$config_dir" -type d -exec chmod 755 {} \; || true
        find "$config_dir" -type f -exec chmod 644 {} \; || true
        find "$config_dir" -name "*.conf" -exec chmod 640 {} \; || true
        chown -R $FREERADIUS_USER:$FREERADIUS_USER "$config_dir" || true
    fi
    
    # Fix log directory
    mkdir -p /var/log/radius
    touch /var/log/radius/radius.log
    chown -R $FREERADIUS_USER:$FREERADIUS_USER /var/log/radius || true
    chmod 755 /var/log/radius || true
    chmod 644 /var/log/radius/radius.log || true
    
    # Run the comprehensive fix script if available
    if [ -f "${SCRIPT_DIR}/fix_freeradius_install_updated.sh" ]; then
        log "Running comprehensive fix script..."
        read -p "Do you want to run the comprehensive fix script? This will attempt to repair the entire installation. [y/N]: " run_fix
        if [[ $run_fix =~ ^[Yy]$ ]]; then
            bash "${SCRIPT_DIR}/fix_freeradius_install_updated.sh"
            return
        fi
    fi
    
    # Restart service
    log "Restarting FreeRADIUS service..."
    systemctl restart freeradius
    
    if systemctl is-active --quiet freeradius; then
        log "FreeRADIUS service is now running!"
    else
        error "FreeRADIUS service failed to start. Checking logs..."
        journalctl -u freeradius -n 20
    fi
}

# Function to back up and restore
backup_restore() {
    local action=$1
    
    section "Backup and Restore"
    
    local config_dir=$(find_freeradius_dir)
    if [ -z "$config_dir" ]; then
        error "Cannot find FreeRADIUS configuration directory."
        return 1
    fi
    
    local timestamp=$(date +"%Y%m%d-%H%M%S")
    local backup_dir="${SCRIPT_DIR}/backups"
    
    mkdir -p "$backup_dir"
    
    case $action in
        backup)
            local backup_file="$backup_dir/freeradius-backup-$timestamp.tar.gz"
            
            log "Creating backup of FreeRADIUS configuration and database..."
            
            # Backup config files
            if [ -d "$config_dir" ]; then
                tar -czf "$backup_file" "$config_dir" 2>/dev/null
                log "Configuration files backed up."
            else
                warn "Configuration directory not found."
            fi
            
            # Backup database
            if systemctl is-active --quiet postgresql; then
                local db_backup_file="$backup_dir/radius-db-$timestamp.sql"
                su - postgres -c "pg_dump radius" > "$db_backup_file"
                
                if [ -s "$db_backup_file" ]; then
                    log "Database backed up to $db_backup_file"
                    # Add database backup to the tar file
                    tar -rf "${backup_file%.tar.gz}.tar" -C "$backup_dir" "radius-db-$timestamp.sql" 2>/dev/null
                    gzip -f "${backup_file%.tar.gz}.tar"
                    rm -f "$db_backup_file"
                else
                    warn "Database backup failed or empty."
                fi
            else
                warn "PostgreSQL is not running. Database not backed up."
            fi
            
            log "Backup completed: $backup_file"
            ;;
        restore)
            # List available backups
            log "Available backups:"
            ls -1 "$backup_dir"/freeradius-backup-*.tar.gz 2>/dev/null || echo "No backups found."
            
            read -p "Enter backup file to restore (full path): " restore_file
            
            if [ ! -f "$restore_file" ]; then
                error "Backup file not found: $restore_file"
                return 1
            fi
            
            log "Stopping FreeRADIUS service..."
            systemctl stop freeradius
            
            log "Restoring from backup: $restore_file"
            
            # Extract to temp directory
            local temp_dir=$(mktemp -d)
            tar -xzf "$restore_file" -C "$temp_dir"
            
            # Restore config files
            local extracted_config=$(find "$temp_dir" -type d -name "freeradius" -o -name "3.0" | head -1)
            if [ -n "$extracted_config" ]; then
                # Backup current config
                mv "$config_dir" "${config_dir}.old.${timestamp}" || true
                
                # Restore from backup
                mkdir -p "$config_dir"
                cp -r "$extracted_config"/* "$config_dir"/
                
                log "Configuration files restored."
            else
                warn "No configuration files found in backup."
            fi
            
            # Restore database
            local db_backup=$(find "$temp_dir" -name "radius-db-*.sql" | head -1)
            if [ -n "$db_backup" ]; then
                log "Restoring database..."
                
                # Drop and recreate database
                su - postgres -c "psql -c 'DROP DATABASE IF EXISTS radius;'" || true
                su - postgres -c "psql -c 'CREATE DATABASE radius WITH OWNER radius;'" || true
                
                # Restore from backup
                su - postgres -c "psql radius < $db_backup"
                
                log "Database restored."
            else
                warn "No database backup found."
            fi
            
            # Clean up
            rm -rf "$temp_dir"
            
            # Fix permissions
            log "Fixing permissions..."
            FREERADIUS_USER=$(ps -ef | grep freeradius | grep -v grep | head -1 | awk '{print $1}')
            FREERADIUS_USER=${FREERADIUS_USER:-"freerad"}
            
            find "$config_dir" -type d -exec chmod 755 {} \; || true
            find "$config_dir" -type f -exec chmod 644 {} \; || true
            find "$config_dir" -name "*.conf" -exec chmod 640 {} \; || true
            chown -R $FREERADIUS_USER:$FREERADIUS_USER "$config_dir" || true
            
            # Restart service
            log "Starting FreeRADIUS service..."
            systemctl start freeradius
            
            if systemctl is-active --quiet freeradius; then
                log "Restore completed successfully!"
            else
                error "FreeRADIUS failed to start after restore. Check logs."
                systemctl status freeradius
            fi
            ;;
        *)
            error "Invalid action: $action"
            echo "Valid actions: backup, restore"
            return 1
            ;;
    esac
}

# Function to display help information
show_help() {
    echo -e "${BLUE}FreeRADIUS Manager Script${NC} - Management interface for FreeRADIUS server"
    echo
    echo -e "Usage: ${GREEN}radius_manager.sh${NC} [command] [options]"
    echo
    echo "Commands:"
    echo "  (no command)   - Launch interactive menu"
    echo "  status         - Check FreeRADIUS service status"
    echo "  service        - Manage FreeRADIUS service (start|stop|restart|reload)"
    echo "  user           - Manage RADIUS users (list|add|delete|test)"
    echo "  client         - Manage RADIUS clients (list|add|delete)"
    echo "  database-check - Check PostgreSQL database connection"
    echo "  logs           - View FreeRADIUS logs"
    echo "  diagnostics    - Run diagnostics checks"
    echo "  openvpn-config - Configure OpenVPN integration"
    echo "  fix            - Fix common issues"
    echo "  backup         - Back up FreeRADIUS configuration"
    echo "  restore        - Restore FreeRADIUS configuration"
    echo "  help           - Show this help information"
    echo
    echo "Examples:"
    echo "  radius_manager.sh                      - Launch interactive menu"
    echo "  radius_manager.sh status               - Check service status"
    echo "  radius_manager.sh service restart      - Restart the service"
    echo "  radius_manager.sh user list            - List all users"
    echo "  radius_manager.sh user add joe secret  - Add/update a user"
    echo "  radius_manager.sh logs 50              - Show last 50 log lines"
}

# Install/Configure Menu
install_menu() {
    show_header
    echo -e "${BOLD}${YELLOW}FreeRADIUS Installation & Configuration${NC}"
    echo
    
    # Check if already installed
    if dpkg -l | grep -q freeradius; then
        echo -e "${GREEN}FreeRADIUS is already installed.${NC}"
        
        echo -e "\n${BOLD}Choose an option:${NC}"
        echo -e "${CYAN}1)${NC} Run fix script (fix common issues)"
        echo -e "${CYAN}2)${NC} Configure PostgreSQL integration"
        echo -e "${CYAN}3)${NC} View current configuration"
        echo -e "${CYAN}0)${NC} Return to main menu"
        
        read -p "Enter your choice [0-3]: " choice
        
        case $choice in
            1)
                if [ -f "$SCRIPT_DIR/fix_freeradius_install_updated.sh" ]; then
                    bash "$SCRIPT_DIR/fix_freeradius_install_updated.sh"
                else
                    fix_common_issues
                fi
                ;;
            2)
                if [ -f "$SCRIPT_DIR/radius_postgresql_setup.sh" ]; then
                    bash "$SCRIPT_DIR/radius_postgresql_setup.sh"
                else
                    echo -e "${YELLOW}PostgreSQL setup script not found.${NC}"
                    echo -e "${YELLOW}Attempting to fix SQL configuration manually...${NC}"
                    fix_common_issues
                fi
                ;;
            3)
                config_dir=$(find_freeradius_dir)
                if [ -n "$config_dir" ]; then
                    echo -e "\n${YELLOW}Configuration files in $config_dir:${NC}"
                    ls -la "$config_dir" | grep -E "\.conf$|sites-enabled|mods-enabled"
                    
                    echo -e "\n${YELLOW}Enabled virtual hosts:${NC}"
                    ls -la "$config_dir/sites-enabled"
                    
                    echo -e "\n${YELLOW}Enabled modules:${NC}"
                    ls -la "$config_dir/mods-enabled"
                fi
                ;;
            0|*)
                main_menu
                return
                ;;
        esac
    else
        echo -e "${YELLOW}FreeRADIUS is not installed.${NC}"
        
        echo -e "\n${BOLD}Choose an option:${NC}"
        echo -e "${CYAN}1)${NC} Install FreeRADIUS with default settings"
        echo -e "${CYAN}2)${NC} Install FreeRADIUS with PostgreSQL"
        echo -e "${CYAN}0)${NC} Return to main menu"
        
        read -p "Enter your choice [0-2]: " choice
        
        case $choice in
            1)
                if [ -f "$SCRIPT_DIR/install_freeradius.sh" ]; then
                    bash "$SCRIPT_DIR/install_freeradius.sh"
                else
                    echo -e "${RED}Installation script not found.${NC}"
                    echo -e "Please install FreeRADIUS manually with:"
                    echo -e "${CYAN}sudo apt update && sudo apt install -y freeradius freeradius-utils${NC}"
                fi
                ;;
            2)
                if [ -f "$SCRIPT_DIR/install_freeradius.sh" ] && [ -f "$SCRIPT_DIR/radius_postgresql_setup.sh" ]; then
                    bash "$SCRIPT_DIR/install_freeradius.sh"
                    bash "$SCRIPT_DIR/radius_postgresql_setup.sh"
                else
                    echo -e "${RED}Installation scripts not found.${NC}"
                    echo -e "Please install FreeRADIUS with PostgreSQL manually with:"
                    echo -e "${CYAN}sudo apt update && sudo apt install -y freeradius freeradius-utils freeradius-postgresql postgresql${NC}"
                fi
                ;;
            0|*)
                main_menu
                return
                ;;
        esac
    fi
    
    read -p "Press Enter to continue..."
    main_menu
}

# User Management Menu
user_management_menu() {
    show_header
    echo -e "${BOLD}${YELLOW}RADIUS User Management${NC}"
    echo
    
    echo -e "${BOLD}Choose an option:${NC}"
    echo -e "${CYAN}1)${NC} List all users"
    echo -e "${CYAN}2)${NC} Add/update user"
    echo -e "${CYAN}3)${NC} Delete user"
    echo -e "${CYAN}4)${NC} Test user authentication"
    echo -e "${CYAN}0)${NC} Return to main menu"
    echo
    
    read -p "Enter your choice [0-4]: " choice
    
    case $choice in
        1)
            manage_users list
            ;;
        2)
            read -p "Enter username: " username
            read -p "Enter password: " password
            read -p "Enter group (optional): " group
            
            if [ -n "$username" ] && [ -n "$password" ]; then
                manage_users add "$username" "$password" "$group"
            else
                echo -e "${RED}Username and password are required.${NC}"
            fi
            ;;
        3)
            read -p "Enter username to delete: " username
            
            if [ -n "$username" ]; then
                read -p "Are you sure you want to delete user '$username'? (y/n): " confirm
                if [[ $confirm =~ ^[Yy]$ ]]; then
                    manage_users delete "$username"
                fi
            else
                echo -e "${RED}Username is required.${NC}"
            fi
            ;;
        4)
            read -p "Enter username to test: " username
            read -p "Enter password: " password
            
            if [ -n "$username" ] && [ -n "$password" ]; then
                manage_users test "$username" "$password"
            else
                echo -e "${RED}Username and password are required.${NC}"
            fi
            ;;
        0|*)
            main_menu
            return
            ;;
    esac
    
    read -p "Press Enter to continue..."
    user_management_menu
}

# Client Management Menu
client_management_menu() {
    show_header
    echo -e "${BOLD}${YELLOW}RADIUS Client Management${NC}"
    echo
    
    echo -e "${BOLD}Choose an option:${NC}"
    echo -e "${CYAN}1)${NC} List all clients"
    echo -e "${CYAN}2)${NC} Add/update client"
    echo -e "${CYAN}3)${NC} Delete client"
    echo -e "${CYAN}0)${NC} Return to main menu"
    echo
    
    read -p "Enter your choice [0-3]: " choice
    
    case $choice in
        1)
            manage_clients list
            ;;
        2)
            read -p "Enter client name (shortname): " shortname
            read -p "Enter client IP address: " ipaddr
            read -p "Enter shared secret: " secret
            read -p "Enter NAS type [other]: " nastype
            nastype=${nastype:-other}
            
            if [ -n "$shortname" ] && [ -n "$ipaddr" ] && [ -n "$secret" ]; then
                manage_clients add "$shortname" "$ipaddr" "$secret" "$nastype"
            else
                echo -e "${RED}Client name, IP, and secret are required.${NC}"
            fi
            ;;
        3)
            read -p "Enter client name to delete: " shortname
            
            if [ -n "$shortname" ]; then
                read -p "Are you sure you want to delete client '$shortname'? (y/n): " confirm
                if [[ $confirm =~ ^[Yy]$ ]]; then
                    manage_clients delete "$shortname"
                fi
            else
                echo -e "${RED}Client name is required.${NC}"
            fi
            ;;
        0|*)
            main_menu
            return
            ;;
    esac
    
    read -p "Press Enter to continue..."
    client_management_menu
}

# Service Management Menu
service_management_menu() {
    show_header
    echo -e "${BOLD}${YELLOW}FreeRADIUS Service Management${NC}"
    echo
    
    # Display current status
    if systemctl is-active --quiet freeradius; then
        echo -e "Current status: ${GREEN}RUNNING${NC}"
    else
        echo -e "Current status: ${RED}STOPPED${NC}"
    fi
    
    echo -e "\n${BOLD}Choose an option:${NC}"
    echo -e "${CYAN}1)${NC} Start service"
    echo -e "${CYAN}2)${NC} Stop service"
    echo -e "${CYAN}3)${NC} Restart service"
    echo -e "${CYAN}4)${NC} Reload configuration"
    echo -e "${CYAN}5)${NC} View detailed status"
    echo -e "${CYAN}0)${NC} Return to main menu"
    echo
    
    read -p "Enter your choice [0-5]: " choice
    
    case $choice in
        1)
            manage_service start
            ;;
        2)
            manage_service stop
            ;;
        3)
            manage_service restart
            ;;
        4)
            manage_service reload
            ;;
        5)
            systemctl status freeradius --no-pager -l
            ;;
        0|*)
            main_menu
            return
            ;;
    esac
    
    read -p "Press Enter to continue..."
    service_management_menu
}

# OpenVPN Integration Menu
openvpn_integration_menu() {
    show_header
    echo -e "${BOLD}${YELLOW}OpenVPN Integration${NC}"
    echo
    
    echo -e "${BOLD}Choose an option:${NC}"
    echo -e "${CYAN}1)${NC} Configure OpenVPN RADIUS authentication"
    echo -e "${CYAN}2)${NC} Check OpenVPN integration status"
    echo -e "${CYAN}3)${NC} View integration instructions"
    echo -e "${CYAN}0)${NC} Return to main menu"
    echo
    
    read -p "Enter your choice [0-3]: " choice
    
    case $choice in
        1)
            configure_openvpn_integration
            ;;
        2)
            # Check OpenVPN integration status
            echo -e "\n${YELLOW}Checking OpenVPN integration status...${NC}"
            
            # Check if RADIUS policy exists
            config_dir=$(find_freeradius_dir)
            if [ -n "$config_dir" ]; then
                if [ -f "$config_dir/policy.d/openvpn" ]; then
                    echo -e "${GREEN}✓ OpenVPN policy exists${NC}"
                    grep -A 2 "policy openvpn" "$config_dir/policy.d/openvpn"
                else
                    echo -e "${RED}✗ OpenVPN policy is missing${NC}"
                fi
                
                # Check if client is configured
                if grep -q "client openvpn_server" "$config_dir/clients.conf"; then
                    echo -e "${GREEN}✓ OpenVPN RADIUS client is configured${NC}"
                    grep -A 6 "client openvpn_server" "$config_dir/clients.conf"
                else
                    echo -e "${RED}✗ OpenVPN RADIUS client is not configured${NC}"
                fi
                
                # Check if policy is referenced in site configuration
                if [ -f "$config_dir/sites-enabled/default" ] && grep -q "openvpn" "$config_dir/sites-enabled/default"; then
                    echo -e "${GREEN}✓ OpenVPN policy is referenced in site configuration${NC}"
                else
                    echo -e "${RED}✗ OpenVPN policy is not referenced in site configuration${NC}"
                fi
            fi
            
            # Check OpenVPN configuration
            if [ -f "/etc/openvpn/server.conf" ]; then
                echo -e "\n${YELLOW}OpenVPN server configuration:${NC}"
                if grep -q "radiusplugin.so" /etc/openvpn/server.conf; then
                    echo -e "${GREEN}✓ RADIUS plugin is configured in OpenVPN${NC}"
                    grep -A 3 "radiusplugin.so" /etc/openvpn/server.conf
                else
                    echo -e "${RED}✗ RADIUS plugin is not configured in OpenVPN${NC}"
                fi
            else
                echo -e "${RED}✗ OpenVPN server.conf not found${NC}"
            fi
            ;;
        3)
            # View integration instructions
            config_dir=$(find_freeradius_dir)
            if [ -n "$config_dir" ] && [ -f "$config_dir/openvpn_radius_config.txt" ]; then
                echo -e "\n${YELLOW}OpenVPN Integration Instructions:${NC}\n"
                cat "$config_dir/openvpn_radius_config.txt"
            else
                echo -e "${RED}Instructions file not found.${NC}"
                echo -e "You need to configure OpenVPN integration first."
            fi
            ;;
        0|*)
            main_menu
            return
            ;;
    esac
    
    read -p "Press Enter to continue..."
    openvpn_integration_menu
}

# Backup & Restore Menu
backup_restore_menu() {
    show_header
    echo -e "${BOLD}${YELLOW}Backup & Restore${NC}"
    echo
    
    echo -e "${BOLD}Choose an option:${NC}"
    echo -e "${CYAN}1)${NC} Backup configuration and database"
    echo -e "${CYAN}2)${NC} Restore from backup"
    echo -e "${CYAN}3)${NC} List available backups"
    echo -e "${CYAN}0)${NC} Return to main menu"
    echo
    
    read -p "Enter your choice [0-3]: " choice
    
    case $choice in
        1)
            backup_restore backup
            ;;
        2)
            backup_restore restore
            ;;
        3)
            backup_dir="${SCRIPT_DIR}/backups"
            echo -e "\n${YELLOW}Available backups:${NC}"
            ls -lh "$backup_dir"/freeradius-backup-*.tar.gz 2>/dev/null || echo "No backups found."
            ;;
        0|*)
            main_menu
            return
            ;;
    esac
    
    read -p "Press Enter to continue..."
    backup_restore_menu
}

# Diagnostics & Troubleshooting Menu
diagnostics_menu() {
    show_header
    echo -e "${BOLD}${YELLOW}Diagnostics & Troubleshooting${NC}"
    echo
    
    echo -e "${BOLD}Choose an option:${NC}"
    echo -e "${CYAN}1)${NC} Run full diagnostics"
    echo -e "${CYAN}2)${NC} View service logs"
    echo -e "${CYAN}3)${NC} Check database connection"
    echo -e "${CYAN}4)${NC} Fix common issues"
    echo -e "${CYAN}5)${NC} Test RADIUS authentication"
    echo -e "${CYAN}0)${NC} Return to main menu"
    echo
    
    read -p "Enter your choice [0-5]: " choice
    
    case $choice in
        1)
            run_diagnostics
            ;;
        2)
            echo -e "\n${YELLOW}Showing last 30 log entries:${NC}"
            view_logs 30
            ;;
        3)
            check_database_connection
            ;;
        4)
            fix_common_issues
            ;;
        5)
            read -p "Enter username to test: " username
            read -p "Enter password: " password
            
            if [ -n "$username" ] && [ -n "$password" ]; then
                manage_users test "$username" "$password"
            else
                echo -e "${RED}Username and password are required.${NC}"
            fi
            ;;
        0|*)
            main_menu
            return
            ;;
    esac
    
    read -p "Press Enter to continue..."
    diagnostics_menu
}

# Function to render the main menu
main_menu() {
    show_header
    
    # Display status summary if FreeRADIUS is installed
    if command_exists freeradius || dpkg -l | grep -q freeradius; then
        echo -e "${YELLOW}FreeRADIUS Status:${NC}"
        if systemctl is-active --quiet freeradius; then
            echo -e "${GREEN}● Service: Running${NC}"
        else
            echo -e "${RED}● Service: Stopped${NC}"
        fi
        echo
    fi
    
    echo -e "${BOLD}Choose an option:${NC}"
    echo
    echo -e "${CYAN}1)${NC} Install/Configure FreeRADIUS"
    echo -e "${CYAN}2)${NC} Manage Users"
    echo -e "${CYAN}3)${NC} Manage RADIUS Clients"
    echo -e "${CYAN}4)${NC} Service Management"
    echo -e "${CYAN}5)${NC} OpenVPN Integration"
    echo -e "${CYAN}6)${NC} View Logs"
    echo -e "${CYAN}7)${NC} Backup & Restore"
    echo -e "${CYAN}8)${NC} Diagnostics & Troubleshooting"
    echo -e "${CYAN}0)${NC} Exit"
    echo
    
    read -p "Enter your choice [0-8]: " choice
    
    case $choice in
        1)
            install_menu
            ;;
        2)
            user_management_menu
            ;;
        3)
            client_management_menu
            ;;
        4)
            service_management_menu
            ;;
        5)
            openvpn_integration_menu
            ;;
        6)
            view_logs
            ;;
        7)
            backup_restore_menu
            ;;
        8)
            diagnostics_menu
            ;;
        0)
            echo -e "${GREEN}Exiting. Goodbye!${NC}"
            exit 0
            ;;
        *)
            echo -e "${RED}Invalid option. Press Enter to continue...${NC}"
            read
            main_menu
            ;;
    esac
}

# Main function
main() {
    # Support both interactive and command-line usage
    if [ $# -eq 0 ]; then
        # No arguments - run in interactive mode
        main_menu
    else
        # Command-line arguments provided
        # Check if FreeRADIUS is installed for most commands
        if ! check_freeradius_installed && [ "$1" != "help" ] && [ "$1" != "install" ]; then
            error "FreeRADIUS is not installed. Please run the installation script first."
            exit 1
        fi
        
        # Parse arguments
        case "$1" in
            status)
                check_freeradius_status
                ;;
            service)
                if [ $# -lt 2 ]; then
                    error "Missing service action."
                    echo "Usage: radius_manager.sh service [start|stop|restart|reload]"
                    exit 1
                fi
                manage_service "$2"
                ;;
            user)
                if [ $# -lt 2 ]; then
                    error "Missing user action."
                    echo "Usage: radius_manager.sh user [list|add|delete|test] [options]"
                    exit 1
                fi
                shift
                manage_users "$@"
                ;;
            client)
                if [ $# -lt 2 ]; then
                    error "Missing client action."
                    echo "Usage: radius_manager.sh client [list|add|delete] [options]"
                    exit 1
                fi
                shift
                manage_clients "$@"
                ;;
            database-check)
                check_database_connection
                ;;
            logs)
                if [ $# -gt 1 ]; then
                    view_logs "$2"
                else
                    view_logs
                fi
                ;;
            diagnostics)
                run_diagnostics
                ;;
            openvpn-config)
                configure_openvpn_integration
                ;;
            fix)
                fix_common_issues
                ;;
            backup)
                backup_restore "backup"
                ;;
            restore)
                backup_restore "restore"
                ;;
            install)
                install_menu
                ;;
            help)
                show_help
                ;;
            *)
                error "Unknown command: $1"
                show_help
                exit 1
                ;;
        esac
    fi
}

# Run main function with all arguments
main "$@"
