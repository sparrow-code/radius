#!/bin/bash

# FreeRADIUS Server Installation Script for Ubuntu
# This script installs and configures a basic FreeRADIUS server
# Usage: sudo bash install_freeradius.sh

# Check if script is run as root
if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root (sudo)"
    exit 1
fi

echo "==============================================="
echo "FreeRADIUS Server Installation"
echo "==============================================="

# Function to display progress
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

# Update system packages
log "Updating system packages..."
apt-get update -qq

# Install FreeRADIUS and related packages
log "Installing FreeRADIUS and related packages..."
apt-get install -y freeradius freeradius-postgresql freeradius-utils postgresql postgresql-client

# Check if installation was successful
if ! command -v radiusd &> /dev/null && ! command -v freeradius &> /dev/null; then
    log "ERROR: FreeRADIUS installation failed."
    exit 1
fi

# Backup original configuration
log "Creating backup of original configuration..."
TIMESTAMP=$(date +"%Y%m%d-%H%M%S")
mkdir -p /etc/freeradius/backup_$TIMESTAMP
cp -r /etc/freeradius/3.0/* /etc/freeradius/backup_$TIMESTAMP/

# Create directory structure for our custom configs
log "Creating directory structure..."
mkdir -p /etc/freeradius/3.0/certs
mkdir -p /etc/freeradius/3.0/users
mkdir -p /var/log/radius/

# Set proper permissions
log "Setting file permissions..."
chown -R freerad:freerad /etc/freeradius/3.0/
chown -R freerad:freerad /var/log/radius/
chmod 755 /etc/freeradius/3.0/
chmod 660 /etc/freeradius/3.0/clients.conf

# Configure PostgreSQL database
log "Setting up PostgreSQL database for FreeRADIUS..."
# Check if PostgreSQL is running
systemctl start postgresql
systemctl enable postgresql

# 1. Check if radius user already exists
RADIUS_USER_EXISTS=$(su - postgres -c "psql -t -c \"SELECT 1 FROM pg_roles WHERE rolname='radius'\"" | xargs)
if [ -z "$RADIUS_USER_EXISTS" ]; then
    log "Creating PostgreSQL user 'radius'..."
    su - postgres -c "psql -c \"CREATE USER radius WITH PASSWORD 'radpass';\""
else
    log "PostgreSQL user 'radius' already exists."
fi

# 2. Check if radius database already exists
RADIUS_DB_EXISTS=$(su - postgres -c "psql -t -c \"SELECT 1 FROM pg_database WHERE datname='radius'\"" | xargs)
if [ -z "$RADIUS_DB_EXISTS" ]; then
    log "Creating PostgreSQL database 'radius'..."
    su - postgres -c "psql -c \"CREATE DATABASE radius WITH OWNER radius;\""
else
    log "PostgreSQL database 'radius' already exists."
fi

# 3. Import schema if needed
log "Checking if database schema exists..."
TABLES_EXIST=$(su - postgres -c "psql -t -c \"SELECT count(*) FROM information_schema.tables WHERE table_schema='public';\" radius" | xargs)
if [ "$TABLES_EXIST" -eq "0" ]; then
    log "Importing FreeRADIUS schema to PostgreSQL..."
    su - postgres -c "psql -d radius -f /etc/freeradius/3.0/mods-config/sql/main/postgresql/schema.sql"
else
    log "Database schema already exists. Skipping import."
fi

# 4. Configure pg_hba.conf for password authentication
log "Configuring PostgreSQL authentication (pg_hba.conf)..."
PG_HBA_CONF=$(su - postgres -c "psql -t -c \"SHOW hba_file;\"" | xargs)
log "PostgreSQL hba configuration file: $PG_HBA_CONF"

# Check if radius user entry exists in pg_hba.conf
if ! grep -q "^host.*radius.*radius.*md5" "$PG_HBA_CONF"; then
    log "Adding radius user entry to pg_hba.conf..."
    # Add line before the first 'host' line to allow radius user to connect via password
    sed -i '/^host/i host    radius          radius          127.0.0.1/32            md5' "$PG_HBA_CONF"
    
    # Reload PostgreSQL to apply changes
    log "Reloading PostgreSQL configuration..."
    systemctl reload postgresql
fi

# 5. Grant necessary permissions to the radius user
log "Granting necessary permissions to radius user..."
su - postgres -c "psql -c \"GRANT ALL PRIVILEGES ON DATABASE radius TO radius;\" postgres"
su - postgres -c "psql -c \"GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO radius;\" radius"
su - postgres -c "psql -c \"GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO radius;\" radius"
su - postgres -c "psql -c \"GRANT ALL PRIVILEGES ON SCHEMA public TO radius;\" radius"

# Configure FreeRADIUS to use PostgreSQL
log "Configuring FreeRADIUS to use PostgreSQL..."
cat > /etc/freeradius/3.0/mods-available/sql << EOF
sql {
    driver = "rlm_sql_postgresql"
    dialect = "postgresql"

    # Connection info
    server = "localhost"
    port = 5432
    login = "radius"
    password = "radpass"
    radius_db = "radius"
    
    # Connection pool optimization for your hardware (2vCPU, 4GB RAM)
    pool {
        start = 5
        min = 3
        max = 10
        spare = 5
        uses = 0
        lifetime = 0
        idle_timeout = 60
    }

    # Read configuration
    read_clients = yes
    client_table = "nas"

    # Table configuration
    accounting_table = "radacct"
    acct_table1 = "radacct"
    acct_table2 = "radacct"
    postauth_table = "radpostauth"
    authcheck_table = "radcheck"
    authreply_table = "radreply"
    groupcheck_table = "radgroupcheck"
    groupreply_table = "radgroupreply"
    usergroup_table = "radusergroup"
    
    # Query configuration - use default queries from PostgreSQL schema
    read_groups = yes
    deletestalesessions = yes
    sqltrace = no
    num_sql_socks = 10
    connect_failure_retry_delay = 60
}
EOF

# Enable the SQL module if not already enabled
log "Enabling SQL module..."
if [ ! -L /etc/freeradius/3.0/mods-enabled/sql ]; then
    cd /etc/freeradius/3.0/mods-enabled
    ln -sf ../mods-available/sql .
else
    log "SQL module already enabled."
fi

# Update RADIUS site configuration to use SQL
log "Updating site configuration to use SQL throughout authentication process..."
DEFAULT_SITE="/etc/freeradius/3.0/sites-available/default"
INNER_TUNNEL="/etc/freeradius/3.0/sites-available/inner-tunnel"

# Function to update a site config to use SQL
update_site_config() {
    local site_file=$1
    
    # Update authorize section
    if ! grep -q "^[[:space:]]*sql$" "$site_file"; then
        sed -i '/^authorize {/,/^}/ s/^}$/    sql\n}/' "$site_file"
    fi
    
    # Update accounting section
    if ! grep -q "^[[:space:]]*sql$" "$site_file" "$site_file"; then
        sed -i '/^accounting {/,/^}/ s/^}$/    sql\n}/' "$site_file"
    fi
    
    # Update session section
    if ! grep -q "^[[:space:]]*sql$" "$site_file" "$site_file"; then
        sed -i '/^session {/,/^}/ s/^}$/    sql\n}/' "$site_file"
    fi
    
    # Update post-auth section
    if ! grep -q "^[[:space:]]*sql$" "$site_file" "$site_file"; then
        sed -i '/^post-auth {/,/^}/ s/^}$/    sql\n}/' "$site_file"
    fi
}

update_site_config "$DEFAULT_SITE"
update_site_config "$INNER_TUNNEL"

# Configure RADIUS clients (OpenVPN server)
log "Configuring default RADIUS clients..."
cat > /etc/freeradius/3.0/clients.conf << EOF
# Default RADIUS client configuration
client localhost {
    ipaddr = 127.0.0.1
    secret = testing123
    shortname = localhost
    nastype = other
}

# Replace with your OpenVPN server IP
client openvpn_server {
    ipaddr = 127.0.0.1
    secret = vpn_secret
    shortname = openvpn
    nastype = other
}

# Add more clients as needed using the radius_add_client.sh script
EOF

# Configure users file with a test user
log "Creating a test user..."
cat > /etc/freeradius/3.0/users/default << EOF
# Test user - remove in production
testuser Cleartext-Password := "password"
        Reply-Message := "Hello, %{User-Name}"
EOF

# Configure radiusd.conf for better performance on your hardware
log "Optimizing RADIUS configuration for your hardware..."
sed -i 's/^max_requests =.*/max_requests = 4096/' /etc/freeradius/3.0/radiusd.conf
sed -i 's/^max_request_time =.*/max_request_time = 30/' /etc/freeradius/3.0/radiusd.conf
sed -i 's/^max_servers =.*/max_servers = 12/' /etc/freeradius/3.0/radiusd.conf

# Update log settings
log "Updating log settings..."
cat > /etc/freeradius/3.0/radiusd.conf.d/logging << EOF
log {
    destination = files
    file = /var/log/radius/radius.log
    syslog_facility = daemon
    stripped_names = yes
    auth = yes
    auth_badpass = yes
    auth_goodpass = yes
}
EOF

# Restart FreeRADIUS to apply changes
log "Restarting FreeRADIUS service..."
systemctl restart freeradius

# Check if service is running
if systemctl is-active --quiet freeradius; then
    log "FreeRADIUS service started successfully!"
else
    log "ERROR: FreeRADIUS service failed to start. Check /var/log/syslog for errors."
    systemctl status freeradius
    exit 1
fi

# Configure firewall to allow RADIUS ports
log "Configuring firewall..."
if command -v ufw &> /dev/null; then
    ufw allow 1812/udp comment "RADIUS Authentication"
    ufw allow 1813/udp comment "RADIUS Accounting"
    log "Added UFW rules for RADIUS ports."
elif command -v firewall-cmd &> /dev/null; then
    firewall-cmd --permanent --add-port=1812/udp
    firewall-cmd --permanent --add-port=1813/udp
    firewall-cmd --reload
    log "Added FirewallD rules for RADIUS ports."
else
    log "WARNING: Could not detect UFW or FirewallD. Please manually configure your firewall to allow UDP ports 1812 and 1813."
    log "Example: iptables -A INPUT -p udp --dport 1812 -j ACCEPT"
    log "Example: iptables -A INPUT -p udp --dport 1813 -j ACCEPT"
fi

# Add test user to PostgreSQL database
log "Adding test user to PostgreSQL database..."
su - postgres -c "psql -c \"DELETE FROM radcheck WHERE username='testuser';\" radius"
su - postgres -c "psql -c \"INSERT INTO radcheck (username, attribute, op, value) VALUES ('testuser', 'Cleartext-Password', ':=', 'password');\" radius"

# Verify PostgreSQL connection from RADIUS
log "Verifying PostgreSQL connection from FreeRADIUS..."
if ! su - freerad -c "psql -h localhost -U radius -d radius -c '\\dt'" > /dev/null 2>&1; then
    log "WARNING: FreeRADIUS cannot connect to PostgreSQL. Check authentication settings."
    log "This may cause issues with SQL-based authentication."
    log "Possible solution: Add the following line to pg_hba.conf and reload PostgreSQL:"
    log "host    radius    radius    127.0.0.1/32    md5"
else
    log "PostgreSQL connection from FreeRADIUS verified successfully!"
fi

# Test the SQL configuration with debug mode
log "Testing FreeRADIUS SQL configuration..."
systemctl stop freeradius
freeradius -X -l /tmp/radius_sql_test.log &
FR_PID=$!
sleep 2

# Kill the debug process after testing
kill $FR_PID 2>/dev/null

# Look for SQL-related errors
SQL_ERRORS=$(grep -i "sql.*error" /tmp/radius_sql_test.log)
if [ -n "$SQL_ERRORS" ]; then
    log "SQL connection errors detected:"
    echo "$SQL_ERRORS"
    log "Please check your PostgreSQL configuration. Authentication may still work but without SQL backend."
else
    log "No SQL errors detected in debug mode."
fi

# Test RADIUS server
log "Testing RADIUS authentication with PostgreSQL backend..."
radtest testuser password localhost 0 testing123

# Create validation file for checking SQL module loading
log "Creating SQL module validation file..."
cat > /etc/freeradius/3.0/sql_module_check.sh << 'EOF'
#!/bin/bash

echo "Checking FreeRADIUS SQL module status..."

# Check if SQL module is enabled
if [ -L /etc/freeradius/3.0/mods-enabled/sql ]; then
    echo "✅ SQL module is enabled"
else
    echo "❌ SQL module is not enabled"
    echo "Run: ln -sf ../mods-available/sql /etc/freeradius/3.0/mods-enabled/sql"
    exit 1
fi

# Check if PostgreSQL is running
if systemctl is-active --quiet postgresql; then
    echo "✅ PostgreSQL service is running"
else
    echo "❌ PostgreSQL service is not running"
    echo "Run: systemctl start postgresql"
    exit 1
fi

# Check database connection
if su - freerad -c "psql -h localhost -U radius -d radius -c '\dt'" > /dev/null 2>&1; then
    echo "✅ FreeRADIUS can connect to PostgreSQL"
else
    echo "❌ FreeRADIUS cannot connect to PostgreSQL"
    echo "Check pg_hba.conf and PostgreSQL authentication settings"
    exit 1
fi

# Check if test user exists in database
TESTUSER=$(su - postgres -c "psql -t -c \"SELECT COUNT(*) FROM radcheck WHERE username='testuser';\" radius" | xargs)
if [ "$TESTUSER" -gt 0 ]; then
    echo "✅ Test user exists in database"
else
    echo "❌ Test user does not exist in database"
    echo "Add test user with: INSERT INTO radcheck VALUES (username, attribute, op, value)"
    exit 1
fi

# Test authentication
if radtest testuser password localhost 0 testing123 | grep -q "Access-Accept"; then
    echo "✅ RADIUS authentication is working with PostgreSQL backend"
else
    echo "❌ RADIUS authentication failed with PostgreSQL backend"
    echo "Check FreeRADIUS debug logs: freeradius -X"
    exit 1
fi

echo "All checks passed! PostgreSQL is properly integrated with FreeRADIUS."
EOF

chmod +x /etc/freeradius/3.0/sql_module_check.sh

echo
echo "==============================================="
echo "FreeRADIUS installation complete!"
echo "==============================================="
echo
echo "Default test user created:"
echo "  Username: testuser"
echo "  Password: password"
echo
echo "Default client shared secret for localhost: testing123"
echo "Default client shared secret for OpenVPN: vpn_secret"
echo
echo "To add users, use: ./radius_add_user.sh <username> <password> [group]"
echo "To add clients, use: ./radius_add_client.sh <name> <ip> <secret> [nastype]"
echo "To configure OpenVPN with RADIUS, use: ./radius_openvpn_config.sh"
echo
echo "To verify the SQL module integration at any time, run:"
echo "sudo /etc/freeradius/3.0/sql_module_check.sh"
echo
echo "PostgreSQL database details:"
echo "  Database: radius"
echo "  Username: radius"
echo "  Password: radpass"
echo
echo "RADIUS logs are stored in /var/log/radius/radius.log"
echo "==============================================="
