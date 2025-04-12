#!/bin/bash
# User Management module for FreeRADIUS Manager

# Manage RADIUS users (list, add, delete, test)
manage_users() {
    local action=$1
    shift
    
    # Ensure FreeRADIUS is installed
    if ! check_freeradius_installed; then
        return 1
    fi
    
    case $action in
        list)
            list_users
            ;;
        add)
            if [ $# -lt 2 ]; then
                error "Usage: radius.sh user add <username> <password> [group]"
                return 1
            fi
            add_user "$1" "$2" "$3"
            ;;
        delete)
            if [ $# -lt 1 ]; then
                error "Usage: radius.sh user delete <username>"
                return 1
            fi
            delete_user "$1"
            ;;
        test)
            if [ $# -lt 2 ]; then
                error "Usage: radius.sh user test <username> <password>"
                return 1
            fi
            test_user "$1" "$2"
            ;;
        *)
            error "Unknown user action: $action"
            echo "Available actions: list, add, delete, test"
            return 1
            ;;
    esac
    
    return 0
}

# List all RADIUS users
list_users() {
    section "RADIUS User List"
    
    # Check if PostgreSQL is used
    if systemctl is-active --quiet postgresql; then
        log "Listing all RADIUS users from database..."
        su - postgres -c "psql -c \"SELECT username, attribute, value FROM radcheck WHERE attribute='Cleartext-Password';\" radius" || true
    else
        # Check users directory
        local radius_dir=$(find_freeradius_dir)
        local users_dir="$radius_dir/users"
        
        if [ -d "$users_dir" ]; then
            log "Listing users from $users_dir:"
            grep -l 'Cleartext-Password' "$users_dir"/* | while read -r file; do
                username=$(basename "$file")
                password=$(grep -oP 'Cleartext-Password\s*:=\s*"\K[^"]+' "$file")
                echo "$username: $password"
            done
        else
            # Check users file
            local users_file="$radius_dir/users"
            if [ -f "$users_file" ]; then
                log "Listing users from $users_file:"
                grep -A 1 'Cleartext-Password' "$users_file"
            else
                error "No user files found."
            fi
        fi
    fi
    
    return 0
}

# Add or update a RADIUS user
add_user() {
    local username="$1"
    local password="$2"
    local group="$3"
    
    section "Add/Update User"
    log "Processing user: $username"
    
    # Check if PostgreSQL is used
    if systemctl is-active --quiet postgresql; then
        log "Using PostgreSQL database..."
        
        # Check if user exists
        local user_exists=$(su - postgres -c "psql -t -c \"SELECT COUNT(*) FROM radcheck WHERE username='$username' AND attribute='Cleartext-Password';\" radius" | xargs)
        
        if [ "$user_exists" -gt 0 ]; then
            log "User already exists. Updating password..."
            su - postgres -c "psql -c \"UPDATE radcheck SET value='$password' WHERE username='$username' AND attribute='Cleartext-Password';\" radius" || true
        else
            log "Creating new user..."
            su - postgres -c "psql -c \"INSERT INTO radcheck (username, attribute, op, value) VALUES ('$username', 'Cleartext-Password', ':=', '$password');\" radius" || true
        fi
        
        # Handle group if specified
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
    else
        # Use flat files
        local radius_dir=$(find_freeradius_dir)
        
        # Create users directory if it doesn't exist
        mkdir -p "$radius_dir/users"
        
        # Add user to a separate file
        local user_file="$radius_dir/users/$username"
        
        # Create user file
        cat > "$user_file" << EOF
# User: $username
$username Cleartext-Password := "$password"
EOF
        
        if [ -n "$group" ]; then
            echo "        Group := \"$group\"" >> "$user_file"
        fi
        
        # Set proper permissions
        if getent group | grep -q "^freerad:"; then
            RADIUS_USER="freerad"
        elif getent group | grep -q "^radiusd:"; then
            RADIUS_USER="radiusd"
        else
            RADIUS_USER="freerad"
        fi
        
        chown $RADIUS_USER:$RADIUS_USER "$user_file"
        chmod 640 "$user_file"
    fi
    
    log "User $username has been added/updated successfully!"
    
    return 0
}

# Delete a RADIUS user
delete_user() {
    local username="$1"
    
    section "Delete User"
    log "Deleting user: $username"
    
    # Check if PostgreSQL is used
    if systemctl is-active --quiet postgresql; then
        log "Using PostgreSQL database..."
        
        # Delete user from tables
        su - postgres -c "psql -c \"DELETE FROM radcheck WHERE username='$username';\" radius" || true
        su - postgres -c "psql -c \"DELETE FROM radreply WHERE username='$username';\" radius" || true
        su - postgres -c "psql -c \"DELETE FROM radusergroup WHERE username='$username';\" radius" || true
    else
        # Use flat files
        local radius_dir=$(find_freeradius_dir)
        local user_file="$radius_dir/users/$username"
        
        if [ -f "$user_file" ]; then
            rm -f "$user_file"
            log "Removed user file: $user_file"
        else
            warn "User file not found: $user_file"
            
            # Check and remove from users file
            local users_file="$radius_dir/users"
            if [ -f "$users_file" ]; then
                log "Checking main users file..."
                if grep -q "^$username" "$users_file"; then
                    log "Removing user from $users_file..."
                    sed -i "/^$username Cleartext-Password/,/^$/d" "$users_file"
                fi
            fi
        fi
    fi
    
    log "User $username has been deleted."
    
    return 0
}

# Test user authentication
test_user() {
    local username="$1"
    local password="$2"
    
    section "Test User Authentication"
    log "Testing authentication for user: $username"
    
    if ! command -v radtest &> /dev/null; then
        error "radtest command not found. Install FreeRADIUS utils first."
        return 1
    fi
    
    # Run authentication test
    echo
    radtest "$username" "$password" localhost 0 testing123
    local result=$?
    echo
    
    if [ $result -eq 0 ]; then
        log "Authentication successful for user $username!"
    else
        warn "Authentication failed for user $username. Check username and password."
    fi
    
    return $result
}
