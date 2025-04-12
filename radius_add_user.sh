#!/bin/bash

# FreeRADIUS User Management Script
# Usage: sudo bash radius_add_user.sh <username> <password> [group]

# Check if script is run as root
if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root (sudo)"
    exit 1
fi

# Check arguments
if [ $# -lt 2 ]; then
    echo "Usage: $0 <username> <password> [group]"
    echo "Example: $0 john password123 vpnusers"
    exit 1
fi

USERNAME=$1
PASSWORD=$2
GROUP=${3:-"users"}  # Default group is "users" if not specified

echo "==============================================="
echo "Adding RADIUS user: $USERNAME"
echo "==============================================="

# Function to check if user exists
user_exists() {
    local count=$(su - postgres -c "psql -t -c \"SELECT COUNT(*) FROM radcheck WHERE username='$USERNAME';\" radius")
    if [ "$(echo $count | tr -d ' ')" -gt 0 ]; then
        return 0  # True, user exists
    else
        return 1  # False, user doesn't exist
    fi
}

# Add user to radcheck table (authentication)
if user_exists; then
    echo "User $USERNAME already exists. Updating password..."
    su - postgres -c "psql -c \"UPDATE radcheck SET value='$PASSWORD' WHERE username='$USERNAME' AND attribute='Cleartext-Password';\" radius"
else
    echo "Creating new user: $USERNAME"
    su - postgres -c "psql -c \"INSERT INTO radcheck (username, attribute, op, value) VALUES ('$USERNAME', 'Cleartext-Password', ':=', '$PASSWORD');\" radius"
fi

# Add user to group if specified
if [ "$GROUP" != "users" ]; then
    echo "Adding user to group: $GROUP"
    
    # Check if group exists, create if not
    GROUP_COUNT=$(su - postgres -c "psql -t -c \"SELECT COUNT(*) FROM radgroupcheck WHERE groupname='$GROUP';\" radius")
    if [ "$(echo $GROUP_COUNT | tr -d ' ')" -eq 0 ]; then
        echo "Creating new group: $GROUP"
        su - postgres -c "psql -c \"INSERT INTO radgroupcheck (groupname, attribute, op, value) VALUES ('$GROUP', 'Simultaneous-Use', ':=', '3');\" radius"
    fi
    
    # Remove any existing group assignments for this user
    su - postgres -c "psql -c \"DELETE FROM radusergroup WHERE username='$USERNAME';\" radius"
    
    # Add user to the specified group
    su - postgres -c "psql -c \"INSERT INTO radusergroup (username, groupname, priority) VALUES ('$USERNAME', '$GROUP', 1);\" radius"
fi

# Also add to flat file for backup purposes
USER_FILE="/etc/freeradius/3.0/users/$USERNAME"
echo "Creating user file: $USER_FILE"
cat > "$USER_FILE" << EOF
$USERNAME Cleartext-Password := "$PASSWORD"
EOF

# If group is specified, add group attributes
if [ "$GROUP" != "users" ]; then
    echo "        Group := \"$GROUP\"" >> "$USER_FILE"
fi

# Set proper permissions
chown freerad:freerad "$USER_FILE"
chmod 640 "$USER_FILE"

echo "Restarting FreeRADIUS service..."
systemctl restart freeradius

# Test the user authentication
echo "Testing user authentication..."
radtest "$USERNAME" "$PASSWORD" localhost 0 testing123

echo
echo "==============================================="
echo "User '$USERNAME' added/updated successfully!"
echo "Group: $GROUP"
echo "==============================================="
