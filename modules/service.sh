#!/bin/bash
# Service Management module for FreeRADIUS

# Check FreeRADIUS service status
check_status() {
    section "FreeRADIUS Service Status"
    
    if ! check_freeradius_installed; then
        return 1
    fi
    
    echo "FreeRADIUS service status:"
    systemctl status freeradius --no-pager
    
    return 0
}

# Manage FreeRADIUS service (start, stop, restart, reload)
manage_service() {
    local action=$1
    
    if ! check_freeradius_installed; then
        return 1
    fi
    
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
            log "Reloading FreeRADIUS service..."
            systemctl reload-or-restart freeradius
            ;;
        *)
            error "Unknown service action: $action"
            echo "Available actions: start, stop, restart, reload"
            return 1
            ;;
    esac
    
    # Check if action was successful
    sleep 2
    if [ "$action" == "stop" ]; then
        if ! systemctl is-active --quiet freeradius; then
            log "FreeRADIUS service has been stopped."
            return 0
        else
            error "Failed to stop FreeRADIUS service."
            return 1
        fi
    else
        if systemctl is-active --quiet freeradius; then
            log "FreeRADIUS service is now running."
            return 0
        else
            error "FreeRADIUS service is not running."
            log "Checking logs for errors..."
            journalctl -u freeradius -n 20 --no-pager
            return 1
        fi
    fi
}

# View FreeRADIUS logs
view_logs() {
    local lines=${1:-50}  # Default to last 50 lines
    
    section "FreeRADIUS Logs"
    
    # Check if log file exists
    local log_file="/var/log/radius/radius.log"
    
    if [ -f "$log_file" ]; then
        log "Showing last $lines lines of $log_file:"
        echo
        tail -n "$lines" "$log_file"
    else
        log "Log file $log_file not found. Checking system logs..."
        echo
        journalctl -u freeradius -n "$lines" --no-pager
    fi
    
    return 0
}

# Run diagnostics
run_diagnostics() {
    section "FreeRADIUS Diagnostics"
    
    # Check if installed
    log "Checking installation..."
    if ! dpkg -l | grep -q freeradius; then
        error "FreeRADIUS is not installed."
        return 1
    else
        echo -e "FreeRADIUS installation: ${GREEN}FOUND${NC}"
        dpkg -l | grep freeradius | awk '{print $2 " - " $3}'
    fi
    
    # Check service status
    log "Checking service status..."
    if systemctl is-active --quiet freeradius; then
        echo -e "FreeRADIUS service: ${GREEN}RUNNING${NC}"
    else
        echo -e "FreeRADIUS service: ${RED}NOT RUNNING${NC}"
    fi
    
    # Check configuration directory
    log "Checking configuration..."
    local config_dir=$(find_freeradius_dir)
    if [ -n "$config_dir" ]; then
        echo -e "Configuration directory: ${GREEN}$config_dir${NC}"
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
        echo -e "SELinux status: ${YELLOW}$SELINUX${NC}"
        if [ "$SELINUX" == "Enforcing" ]; then
            warn "SELinux is enforcing, which might cause permission issues."
            echo "Consider setting SELinux to permissive mode or creating proper policies."
        fi
    fi
    
    # Check for firewall rules
    if command_exists ufw; then
        echo -e "\nUFW firewall status:"
        ufw status | grep -E "1812|1813" || echo "No RADIUS ports found in UFW rules."
    elif command_exists firewall-cmd; then
        echo -e "\nFirewallD status:"
        firewall-cmd --list-ports | grep -E "1812|1813" || echo "No RADIUS ports found in FirewallD rules."
    fi
    
    # Check for syntax errors in config files
    if command_exists radiusd; then
        echo -e "\nChecking for configuration errors..."
        radiusd -XC 2>&1 | grep -i "error" || echo "No syntax errors found."
    elif command_exists freeradius; then
        echo -e "\nChecking for configuration errors..."
        freeradius -XC 2>&1 | grep -i "error" || echo "No syntax errors found."
    fi
    
    return 0
}

# Check database connection
check_database_connection() {
    log "Checking database connection..."
    
    if ! systemctl is-active --quiet postgresql; then
        echo -e "PostgreSQL service: ${RED}NOT RUNNING${NC}"
        return 1
    fi
    
    echo -e "PostgreSQL service: ${GREEN}RUNNING${NC}"
    
    # Check if radius database exists
    local db_exists=$(su - postgres -c "psql -l | grep -c radius")
    
    if [ "$db_exists" -eq 0 ]; then
        echo -e "Radius database: ${RED}NOT FOUND${NC}"
        return 1
    fi
    
    echo -e "Radius database: ${GREEN}FOUND${NC}"
    
    # Check if radius user exists
    local user_exists=$(su - postgres -c "psql -t -c \"SELECT 1 FROM pg_roles WHERE rolname='radius'\"" | xargs)
    
    if [ -z "$user_exists" ]; then
        echo -e "Radius database user: ${RED}NOT FOUND${NC}"
        return 1
    fi
    
    echo -e "Radius database user: ${GREEN}FOUND${NC}"
    
    # Check if required tables exist
    local tables_count=$(su - postgres -c "psql -t -c \"SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='public';\" radius" | xargs)
    
    if [ "$tables_count" -eq 0 ]; then
        echo -e "Radius database tables: ${RED}NOT FOUND${NC}"
        return 1
    fi
    
    echo -e "Radius database tables: ${GREEN}$tables_count tables found${NC}"
    
    return 0
}

# Fix common installation issues
fix_installation() {
    section "Fixing Common Issues"
    
    # Ensure FreeRADIUS is installed
    if ! dpkg -l | grep -q freeradius; then
        error "FreeRADIUS is not installed. Please install it first."
        return 1
    fi
    
    log "Checking for common issues..."
    
    # Fix directory permissions
    local config_dir=$(find_freeradius_dir)
    if [ -n "$config_dir" ]; then
        log "Fixing directory permissions..."
        
        # Detect FreeRADIUS user
        if getent group | grep -q "^freerad:"; then
            RADIUS_USER="freerad"
        elif getent group | grep -q "^radiusd:"; then
            RADIUS_USER="radiusd"
        else
            RADIUS_USER="freerad"
        fi
        
        find "$config_dir" -type d -exec chmod 755 {} \; 2>/dev/null || true
        find "$config_dir" -type f -exec chmod 644 {} \; 2>/dev/null || true
        chown -R $RADIUS_USER:$RADIUS_USER "$config_dir" 2>/dev/null || true
        
        # Fix client.conf permissions
        if [ -f "$config_dir/clients.conf" ]; then
            chmod 640 "$config_dir/clients.conf" 2>/dev/null || true
            chown $RADIUS_USER:$RADIUS_USER "$config_dir/clients.conf" 2>/dev/null || true
        fi
        
        # Fix log directory
        mkdir -p /var/log/radius
        touch /var/log/radius/radius.log 2>/dev/null || true
        chmod 755 /var/log/radius 2>/dev/null || true
        chmod 644 /var/log/radius/radius.log 2>/dev/null || true
        chown -R $RADIUS_USER:$RADIUS_USER /var/log/radius 2>/dev/null || true
    fi
    
    # Check for OpenVPN policy syntax errors
    if [ -f "$config_dir/policy.d/openvpn" ]; then
        log "Checking OpenVPN policy syntax..."
        
        # Fix common syntax errors in the policy file
        sed -i 's/ok[[:space:]]*}/ok\n    }/g' "$config_dir/policy.d/openvpn" 2>/dev/null || true
        
        # Check for extra closing braces
        local brace_count=$(grep -o "}" "$config_dir/policy.d/openvpn" | wc -l)
        local open_brace_count=$(grep -o "{" "$config_dir/policy.d/openvpn" | wc -l)
        
        if [ "$brace_count" -gt "$open_brace_count" ]; then
            log "Found mismatched braces in OpenVPN policy. Fixing..."
            # Create a correct version of the file
            cat > "$config_dir/policy.d/openvpn.new" << EOF
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
            mv "$config_dir/policy.d/openvpn.new" "$config_dir/policy.d/openvpn"
            chown $RADIUS_USER:$RADIUS_USER "$config_dir/policy.d/openvpn" 2>/dev/null || true
            chmod 644 "$config_dir/policy.d/openvpn" 2>/dev/null || true
        fi
    fi
    
    # Restart service to apply changes
    log "Restarting FreeRADIUS service..."
    systemctl stop freeradius 2>/dev/null || true
    sleep 2
    systemctl start freeradius
    
    # Check if service started
    if systemctl is-active --quiet freeradius; then
        log "FreeRADIUS service is now running."
    else
        error "FreeRADIUS service failed to start."
        journalctl -u freeradius -n 20 --no-pager
    fi
    
    return 0
}

# Backup FreeRADIUS configuration
backup_config() {
    section "Backup FreeRADIUS Configuration"
    
    # Check if FreeRADIUS is installed
    if ! check_freeradius_installed; then
        return 1
    fi
    
    # Create backup directory
    local backup_dir="/var/backups/freeradius"
    mkdir -p "$backup_dir"
    
    local timestamp=$(date +%Y%m%d%H%M%S)
    local backup_file="$backup_dir/radius-backup-$timestamp.tar.gz"
    local db_backup_file="$backup_dir/radius-db-$timestamp.sql"
    
    # Backup configuration files
    log "Backing up configuration files..."
    local config_dir=$(find_freeradius_dir)
    
    if [ -n "$config_dir" ]; then
        tar -czf "$backup_file" -C "$(dirname "$config_dir")" "$(basename "$config_dir")" 2>/dev/null
    else
        error "Cannot find FreeRADIUS configuration directory."
        return 1
    fi
    
    # Backup database if PostgreSQL is used
    if systemctl is-active --quiet postgresql; then
        log "Backing up PostgreSQL database..."
        su - postgres -c "pg_dump radius > $db_backup_file" 2>/dev/null
        
        # Add database backup to archive
        tar -rf "${backup_file%.tar.gz}.tar" -C "$(dirname "$db_backup_file")" "$(basename "$db_backup_file")" 2>/dev/null
        gzip -f "${backup_file%.tar.gz}.tar"
        
        # Remove temporary SQL file
        rm -f "$db_backup_file"
    fi
    
    # Verify backup file exists
    if [ -f "$backup_file" ]; then
        log "Backup completed: $backup_file"
        chmod 640 "$backup_file"
        
        # Calculate file size
        local size=$(du -sh "$backup_file" | cut -f1)
        echo -e "Backup size: ${GREEN}$size${NC}"
    else
        error "Backup failed."
        return 1
    fi
    
    return 0
}

# Restore FreeRADIUS configuration from backup
restore_config() {
    local backup_file="$1"
    
    section "Restore FreeRADIUS Configuration"
    
    # Ensure FreeRADIUS is installed
    if ! dpkg -l | grep -q freeradius; then
        error "FreeRADIUS is not installed. Please install it first."
        return 1
    fi
    
    # If no backup file specified, list available backups
    if [ -z "$backup_file" ]; then
        local backup_dir="/var/backups/freeradius"
        
        if [ ! -d "$backup_dir" ]; then
            error "Backup directory not found: $backup_dir"
            return 1
        fi
        
        log "Available backups:"
        ls -lh "$backup_dir" | grep "radius-backup-"
        
        read -p "Enter backup filename to restore: " backup_file
        
        if [ -z "$backup_file" ]; then
            error "No backup file specified."
            return 1
        fi
        
        # Check if path is absolute
        if [[ "$backup_file" != /* ]]; then
            backup_file="$backup_dir/$backup_file"
        fi
    fi
    
    # Check if backup file exists
    if [ ! -f "$backup_file" ]; then
        error "Backup file not found: $backup_file"
        return 1
    fi
    
    log "Restoring from backup: $backup_file"
    
    # Stop FreeRADIUS service
    log "Stopping FreeRADIUS service..."
    systemctl stop freeradius
    
    # Create temporary directory for extraction
    local temp_dir=$(mktemp -d)
    
    # Extract backup
    log "Extracting backup..."
    tar -xzf "$backup_file" -C "$temp_dir"
    
    # Find configuration directory in backup
    local backup_config_dir=$(find "$temp_dir" -type d -name "freeradius" -o -name "raddb" -o -name "3.0" | head -1)
    
    # Find actual configuration directory
    local config_dir=$(find_freeradius_dir)
    
    # Check if configuration was found in backup
    if [ -n "$backup_config_dir" ] && [ -n "$config_dir" ]; then
        log "Restoring configuration files..."
        
        # Create a timestamp for backup of current config
        local timestamp=$(date +%Y%m%d%H%M%S)
        
        # Backup current config
        mv "$config_dir" "${config_dir}.old.${timestamp}" || true
        
        # Restore from backup
        mkdir -p "$config_dir"
        cp -r "$backup_config_dir"/* "$config_dir"/
        
        log "Configuration files restored."
    else
        warn "No configuration files found in backup or current system."
    fi
    
    # Check for database backup
    local db_backup=$(find "$temp_dir" -name "radius-db-*.sql" | head -1)
    
    if [ -n "$db_backup" ] && systemctl is-active --quiet postgresql; then
        log "Restoring database..."
        
        # Create a backup of current database
        su - postgres -c "pg_dump radius > /tmp/radius-db-before-restore-${timestamp}.sql" || true
        
        # Check if radius database exists
        local db_exists=$(su - postgres -c "psql -l | grep -c radius")
        
        if [ "$db_exists" -eq 0 ]; then
            # Create database and user if they don't exist
            log "Creating radius database..."
            su - postgres -c "psql -c 'CREATE ROLE radius WITH LOGIN PASSWORD \"radpass\";'" || true
            su - postgres -c "psql -c 'CREATE DATABASE radius WITH OWNER radius;'" || true
        else
            # Drop and recreate database
            log "Dropping existing radius database..."
            su - postgres -c "psql -c 'DROP DATABASE radius;'" || true
            su - postgres -c "psql -c 'CREATE DATABASE radius WITH OWNER radius;'" || true
        fi
        
        # Restore from backup
        log "Importing database from backup..."
        su - postgres -c "psql radius < $db_backup"
        
        log "Database restored."
    elif [ -n "$db_backup" ]; then
        warn "Database backup found but PostgreSQL is not active."
    else
        warn "No database backup found."
    fi
    
    # Clean up
    log "Cleaning up temporary files..."
    rm -rf "$temp_dir"
    
    # Set proper permissions
    if [ -n "$config_dir" ]; then
        log "Setting proper permissions..."
        
        # Detect FreeRADIUS user
        if getent group | grep -q "^freerad:"; then
            RADIUS_USER="freerad"
        elif getent group | grep -q "^radiusd:"; then
            RADIUS_USER="radiusd"
        else
            RADIUS_USER="freerad"
        fi
        
        find "$config_dir" -type d -exec chmod 755 {} \; 2>/dev/null || true
        find "$config_dir" -type f -exec chmod 644 {} \; 2>/dev/null || true
        chown -R $RADIUS_USER:$RADIUS_USER "$config_dir" 2>/dev/null || true
        
        # Fix client.conf permissions
        if [ -f "$config_dir/clients.conf" ]; then
            chmod 640 "$config_dir/clients.conf" 2>/dev/null || true
            chown $RADIUS_USER:$RADIUS_USER "$config_dir/clients.conf" 2>/dev/null || true
        fi
    fi
    
    # Start FreeRADIUS service
    log "Starting FreeRADIUS service..."
    systemctl start freeradius
    
    # Check if service started
    if systemctl is-active --quiet freeradius; then
        log "FreeRADIUS service is now running. Restoration completed successfully."
    else
        error "FreeRADIUS service failed to start after restore."
        journalctl -u freeradius -n 20 --no-pager
    fi
    
    return 0
}
