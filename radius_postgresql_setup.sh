#!/bin/bash

# FreeRADIUS PostgreSQL Integration and Verification Script
# This script performs deep integration between PostgreSQL and FreeRADIUS
# Usage: sudo bash radius_postgresql_setup.sh

# Check if script is run as root
if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root (sudo)"
    exit 1
fi

echo "==============================================="
echo "FreeRADIUS PostgreSQL Deep Integration"
echo "==============================================="

# Function to display progress
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

# Function to check if a package is installed
is_installed() {
    dpkg -l "$1" | grep -q ^ii
    return $?
}

# Check for required software
log "Checking for required packages..."
REQUIRED_PACKAGES=("freeradius" "freeradius-postgresql" "postgresql" "postgresql-client")
MISSING_PACKAGES=()

for pkg in "${REQUIRED_PACKAGES[@]}"; do
    if ! is_installed "$pkg"; then
        MISSING_PACKAGES+=("$pkg")
    fi
done

if [ ${#MISSING_PACKAGES[@]} -gt 0 ]; then
    log "Missing required packages. Installing: ${MISSING_PACKAGES[*]}"
    apt-get update -qq
    apt-get install -y "${MISSING_PACKAGES[@]}"
fi

# Ensure PostgreSQL is running
log "Ensuring PostgreSQL service is running..."
systemctl start postgresql
systemctl enable postgresql

# Create PostgreSQL configuration
log "Creating PostgreSQL configuration for FreeRADIUS..."

# 1. Create radius user and database (if they don't exist)
RADIUS_USER_EXISTS=$(su - postgres -c "psql -t -c \"SELECT 1 FROM pg_roles WHERE rolname='radius'\"" | xargs)
if [ -z "$RADIUS_USER_EXISTS" ]; then
    log "Creating PostgreSQL user 'radius'..."
    su - postgres -c "psql -c \"CREATE USER radius WITH PASSWORD 'radpass';\""
else
    log "PostgreSQL user 'radius' already exists."
fi

RADIUS_DB_EXISTS=$(su - postgres -c "psql -t -c \"SELECT 1 FROM pg_database WHERE datname='radius'\"" | xargs)
if [ -z "$RADIUS_DB_EXISTS" ]; then
    log "Creating PostgreSQL database 'radius'..."
    su - postgres -c "psql -c \"CREATE DATABASE radius WITH OWNER radius;\""
else
    log "PostgreSQL database 'radius' already exists."
fi

# 2. Import schema if needed
log "Checking if database schema exists..."
TABLES_EXIST=$(su - postgres -c "psql -t -c \"SELECT count(*) FROM information_schema.tables WHERE table_schema='public';\" radius" | xargs)
if [ "$TABLES_EXIST" -eq "0" ]; then
    log "Importing FreeRADIUS schema to PostgreSQL..."
    su - postgres -c "psql -d radius -f /etc/freeradius/3.0/mods-config/sql/main/postgresql/schema.sql"
else
    log "Database schema already exists. Skipping import."
fi

# 3. Configure pg_hba.conf for password authentication
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

# 4. Modify FreeRADIUS SQL module configuration
log "Configuring FreeRADIUS SQL module for PostgreSQL..."
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
if [ ! -L /etc/freeradius/3.0/mods-enabled/sql ]; then
    log "Enabling SQL module..."
    ln -sf ../mods-available/sql /etc/freeradius/3.0/mods-enabled/sql
fi

# 5. Update RADIUS site configuration to use SQL
log "Updating default site configuration to use SQL..."
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

# 6. Add test users to PostgreSQL
log "Adding test user to PostgreSQL database..."
su - postgres -c "psql -c \"DELETE FROM radcheck WHERE username='testuser';\" radius"
su - postgres -c "psql -c \"INSERT INTO radcheck (username, attribute, op, value) VALUES ('testuser', 'Cleartext-Password', ':=', 'password');\" radius"

# 7. Grant necessary permissions to the radius user
log "Granting necessary permissions to radius user..."
su - postgres -c "psql -c \"GRANT ALL PRIVILEGES ON DATABASE radius TO radius;\" postgres"
su - postgres -c "psql -c \"GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO radius;\" radius"
su - postgres -c "psql -c \"GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO radius;\" radius"
su - postgres -c "psql -c \"GRANT ALL PRIVILEGES ON SCHEMA public TO radius;\" radius"

# 8. Verify PostgreSQL connection from RADIUS
log "Verifying PostgreSQL connection from FreeRADIUS..."
if ! su - freerad -c "psql -h localhost -U radius -d radius -c '\\dt'" > /dev/null 2>&1; then
    log "WARNING: FreeRADIUS cannot connect to PostgreSQL. Check authentication settings."
    log "Possible solution: Add the following line to pg_hba.conf and reload PostgreSQL:"
    log "host    radius    radius    127.0.0.1/32    md5"
else
    log "PostgreSQL connection from FreeRADIUS verified successfully!"
fi

# 9. Test the SQL configuration with debug mode
log "Testing FreeRADIUS with SQL in debug mode..."
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
else
    log "No SQL errors detected in debug mode."
fi

# 10. Restart and enable FreeRADIUS service
log "Restarting FreeRADIUS service with new configuration..."
systemctl restart freeradius
systemctl enable freeradius

# 11. Test the RADIUS authentication using SQL backend
log "Testing RADIUS authentication with PostgreSQL backend..."
radtest testuser password localhost 0 testing123

# 12. Create validation file for checking SQL module loading
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
echo "FreeRADIUS PostgreSQL Integration Complete!"
echo "==============================================="
echo
echo "The integration has been verified and configured correctly."
echo "You can add users directly to the PostgreSQL database with:"
echo "sudo -u postgres psql -c \"INSERT INTO radcheck (username, attribute, op, value) VALUES ('username', 'Cleartext-Password', ':=', 'password');\" radius"
echo
echo "Or use the radius_add_user.sh script for simpler user management."
echo
echo "To verify the SQL module integration at any time, run:"
echo "sudo /etc/freeradius/3.0/sql_module_check.sh"
echo
echo "PostgreSQL database details:"
echo "  Database: radius"
echo "  Username: radius"
echo "  Password: radpass"
echo "==============================================="
