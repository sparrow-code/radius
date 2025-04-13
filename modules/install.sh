#!/bin/bash
# Installation module for FreeRADIUS Manager

# Install FreeRADIUS and related packages
install_freeradius() {
    local db_type="${1:-postgresql}"  # Default to PostgreSQL
    
    section "FreeRADIUS Installation"
    
    # Check if already installed
    if dpkg -l | grep -q freeradius; then
        warn "FreeRADIUS is already installed."
        read -p "Do you want to reinstall? This may overwrite your configuration. [y/N]: " confirm
        if [[ ! $confirm =~ ^[Yy]$ ]]; then
            log "Installation aborted."
            return 0
        fi
        
        # Remove existing installation
        log "Removing existing installation..."
        apt-get remove --purge -y freeradius freeradius-postgresql freeradius-utils || true
    fi
    
    # Update system packages
    log "Updating system packages..."
    apt-get update -qq
    
    # Fix any broken packages
    log "Fixing any broken packages..."
    apt-get -f install -y
    dpkg --configure -a
    
    # Install FreeRADIUS and related packages
    log "Installing FreeRADIUS and related packages..."
    
    if [[ "$db_type" == "postgresql" ]]; then
        log "Installing FreeRADIUS with PostgreSQL support..."
        DEBIAN_FRONTEND=noninteractive apt-get install -y freeradius freeradius-postgresql freeradius-utils postgresql postgresql-client
        
        # Configure PostgreSQL if installation was successful
        if dpkg -l | grep -q freeradius; then
            configure_postgresql
        fi
    else
        log "Installing FreeRADIUS with standard configuration..."
        DEBIAN_FRONTEND=noninteractive apt-get install -y freeradius freeradius-utils
    fi
    
    # Check if installation was successful
    if ! command -v radiusd &> /dev/null && ! command -v freeradius &> /dev/null; then
        error "FreeRADIUS installation failed."
        return 1
    fi
    
    # Create directory structure
    create_directory_structure
    
    # Configure SQL module if that function exists and PostgreSQL is in use
    if [[ "$db_type" == "postgresql" ]] && type configure_sql_module &>/dev/null; then
        configure_sql_module
    fi
    
    # Configure radiusd.conf if function exists
    if type configure_main_settings &>/dev/null; then
        configure_main_settings
    else
        log "Skipping main settings configuration (function not available)"
    fi
    
    # Configure clients.conf if function exists
    if type configure_default_clients &>/dev/null; then
        configure_default_clients
    else
        log "Skipping default clients configuration (function not available)"
    fi
    
    # Create test user if function exists
    if type create_test_user &>/dev/null; then
        create_test_user
    else
        log "Skipping test user creation (function not available)"
    fi
    
    # Configure firewall if function exists
    if type configure_firewall &>/dev/null; then
        configure_firewall
    else
        log "Skipping firewall configuration (function not available)"
    fi
    
    # Enable and start the service
    log "Starting FreeRADIUS service..."
    systemctl enable freeradius
    systemctl restart freeradius
    
    # Check if service started successfully
    if systemctl is-active --quiet freeradius; then
        log "FreeRADIUS service started successfully!"
        display_installation_summary
    else
        error "FreeRADIUS service failed to start."
        log "Checking logs..."
        journalctl -u freeradius -n 20
        return 1
    fi
    
    return 0
}

# Create standard directory structure for FreeRADIUS
create_directory_structure() {
    log "Creating directory structure..."
    
    # Ensure log directory exists with proper permissions first
    mkdir -p /var/log/radius/
    
    local radius_dir=$(find_freeradius_dir)
    if [ -z "$radius_dir" ]; then
        # Create directories if they don't exist
        mkdir -p /etc/freeradius/3.0/certs
        mkdir -p /etc/freeradius/3.0/users
        mkdir -p /etc/freeradius/3.0/policy.d
        mkdir -p /etc/freeradius/3.0/radiusd.conf.d
        
        radius_dir="/etc/freeradius/3.0"
    fi
    
    # Detect FreeRADIUS user
    if getent group | grep -q "^freerad:"; then
        RADIUS_USER="freerad"
    elif getent group | grep -q "^radiusd:"; then
        RADIUS_USER="radiusd"
    else
        RADIUS_USER="freerad"
    fi
    
    # Set proper permissions
    log "Setting file permissions..."
    find "$radius_dir" -type d -exec chmod 755 {} \; || true
    find "$radius_dir" -type f -exec chmod 644 {} \; || true
    chown -R $RADIUS_USER:$RADIUS_USER "$radius_dir" || true
    chown -R $RADIUS_USER:$RADIUS_USER /var/log/radius/ || true
    
    return 0
}

# Configure PostgreSQL for FreeRADIUS
configure_postgresql() {
    section "PostgreSQL Configuration"
    
    # Check if PostgreSQL is running
    log "Starting PostgreSQL service..."
    systemctl start postgresql
    systemctl enable postgresql
    
    if ! systemctl is-active --quiet postgresql; then
        error "PostgreSQL service is not running. Cannot continue with database setup."
        return 1
    fi
    
    # Check if radius user exists
    RADIUS_USER_EXISTS=$(su - postgres -c "psql -t -c \"SELECT 1 FROM pg_roles WHERE rolname='radius'\"" | xargs)
    
    if [ -z "$RADIUS_USER_EXISTS" ]; then
        log "Creating PostgreSQL user 'radius'..."
        su - postgres -c "psql -c \"CREATE USER radius WITH PASSWORD 'radpass';\""
    else
        log "PostgreSQL user 'radius' already exists."
    fi
    
    # Check if radius database exists
    DB_EXISTS=$(su - postgres -c "psql -l | grep -c radius")
    
    if [ "$DB_EXISTS" -eq 0 ]; then
        log "Creating 'radius' database..."
        su - postgres -c "psql -c \"CREATE DATABASE radius WITH OWNER radius;\""
    else
        log "Database 'radius' already exists."
    fi
    
    # Import schema if tables don't exist
    TABLES_COUNT=$(su - postgres -c "psql -t -c \"SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='public';\" radius" | xargs)
    
    if [ "$TABLES_COUNT" -eq 0 ]; then
        log "Importing database schema..."
        # Create basic schema
        su - postgres -c "psql -d radius -c \"
            CREATE TABLE IF NOT EXISTS radcheck (
                id SERIAL PRIMARY KEY,
                username VARCHAR(64) NOT NULL DEFAULT '',
                attribute VARCHAR(64) NOT NULL DEFAULT '',
                op CHAR(2) NOT NULL DEFAULT '==',
                value VARCHAR(253) NOT NULL DEFAULT ''
            );
            CREATE TABLE IF NOT EXISTS radreply (
                id SERIAL PRIMARY KEY,
                username VARCHAR(64) NOT NULL DEFAULT '',
                attribute VARCHAR(64) NOT NULL DEFAULT '',
                op CHAR(2) NOT NULL DEFAULT '=',
                value VARCHAR(253) NOT NULL DEFAULT ''
            );
            CREATE TABLE IF NOT EXISTS radgroupcheck (
                id SERIAL PRIMARY KEY,
                groupname VARCHAR(64) NOT NULL DEFAULT '',
                attribute VARCHAR(64) NOT NULL DEFAULT '',
                op CHAR(2) NOT NULL DEFAULT '==',
                value VARCHAR(253) NOT NULL DEFAULT ''
            );
            CREATE TABLE IF NOT EXISTS radgroupreply (
                id SERIAL PRIMARY KEY,
                groupname VARCHAR(64) NOT NULL DEFAULT '',
                attribute VARCHAR(64) NOT NULL DEFAULT '',
                op CHAR(2) NOT NULL DEFAULT '=',
                value VARCHAR(253) NOT NULL DEFAULT ''
            );
            CREATE TABLE IF NOT EXISTS radusergroup (
                id SERIAL PRIMARY KEY,
                username VARCHAR(64) NOT NULL DEFAULT '',
                groupname VARCHAR(64) NOT NULL DEFAULT '',
                priority INTEGER NOT NULL DEFAULT 1
            );
            CREATE TABLE IF NOT EXISTS radacct (
                radacctid BIGSERIAL PRIMARY KEY,
                acctsessionid VARCHAR(64) NOT NULL,
                acctuniqueid VARCHAR(32) NOT NULL,
                username VARCHAR(253),
                realm VARCHAR(64),
                nasipaddress VARCHAR(15) NOT NULL,
                nasportid VARCHAR(15),
                nasporttype VARCHAR(32),
                acctstarttime TIMESTAMP WITH TIME ZONE,
                acctupdatetime TIMESTAMP WITH TIME ZONE,
                acctstoptime TIMESTAMP WITH TIME ZONE,
                acctinterval INTEGER,
                acctsessiontime INTEGER,
                acctauthentic VARCHAR(32),
                connectinfo_start VARCHAR(50),
                connectinfo_stop VARCHAR(50),
                acctinputoctets BIGINT,
                acctoutputoctets BIGINT,
                calledstationid VARCHAR(50),
                callingstationid VARCHAR(50),
                acctterminatecause VARCHAR(32),
                servicetype VARCHAR(32),
                framedprotocol VARCHAR(32),
                framedipaddress VARCHAR(15)
            );
            CREATE TABLE IF NOT EXISTS radpostauth (
                id BIGSERIAL PRIMARY KEY,
                username VARCHAR(64) NOT NULL,
                pass VARCHAR(64) NOT NULL,
                reply VARCHAR(32) NOT NULL,
                authdate TIMESTAMP WITH TIME ZONE NOT NULL default now()
            );
            CREATE TABLE IF NOT EXISTS nas (
                id SERIAL PRIMARY KEY,
                nasname VARCHAR(128) NOT NULL,
                shortname VARCHAR(32),
                type VARCHAR(30),
                ports INTEGER,
                secret VARCHAR(60),
                server VARCHAR(64),
                community VARCHAR(50),
                description VARCHAR(200)
            );
        \""
    else
        log "Database schema already exists. Skipping import."
    fi
    
    # Configure pg_hba.conf for password authentication
    log "Configuring PostgreSQL authentication..."
    PG_HBA_CONF=$(su - postgres -c "psql -t -c \"SHOW hba_file;\"" | xargs)
    log "PostgreSQL hba configuration file: $PG_HBA_CONF"
    
    # Check if radius user entry exists
    if ! grep -q "^host.*radius.*radius.*md5" "$PG_HBA_CONF"; then
        log "Adding radius user entry to pg_hba.conf..."
        # Add line before the first 'host' line
        sed -i '/^host/i host    radius          radius          127.0.0.1/32            md5' "$PG_HBA_CONF"
        
        # Reload PostgreSQL to apply changes
        log "Reloading PostgreSQL configuration..."
        systemctl reload postgresql
    fi
    
    # Grant necessary permissions to the radius user
    log "Granting necessary permissions to radius user..."
    su - postgres -c "psql -c \"GRANT ALL PRIVILEGES ON DATABASE radius TO radius;\" postgres"
    su - postgres -c "psql -c \"GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO radius;\" radius"
    su - postgres -c "psql -c \"GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO radius;\" radius"
    
    # Configure SQL module for FreeRADIUS
    configure_sql_module
    
    return 0
}

# Configure SQL module for FreeRADIUS
configure_sql_module() {
    log "Configuring SQL module..."
    
    local radius_dir=$(find_freeradius_dir)
    local mods_dir="$radius_dir/mods-available"
    
    if [ -f "$mods_dir/sql" ]; then
        log "Backing up original SQL module configuration..."
        cp -a "$mods_dir/sql" "$mods_dir/sql.orig.$(date +%Y%m%d%H%M%S)" || true
    fi
    
    log "Creating SQL module configuration..."
    cat > "$mods_dir/sql" << EOF
sql {
    driver = "rlm_sql_postgresql"
    dialect = "postgresql"

    # Connection info
    server = "localhost"
    port = 5432
    login = "radius"
    password = "radpass"
    radius_db = "radius"
    
    # Connection pool optimization
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
    
    # Query configuration
    read_groups = yes
    deletestalesessions = yes
    sqltrace = no
    num_sql_socks = 10
    connect_failure_retry_delay = 60
}
EOF
    
    # Enable SQL module
    log "Enabling SQL module..."
    cd "$radius_dir/mods-enabled"
    ln -sf ../mods-available/sql .
    
    # Update site configuration to use SQL
    log "Updating site configuration to use SQL..."
    
    # Function to update a site config to use SQL
    update_site_config() {
        local site_file=$1
        
        if [ ! -f "$site_file" ]; then
            warn "Site file not found: $site_file"
            return 1
        fi
        
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
        
        return 0
    }
    
    # Update default and inner-tunnel sites
    update_site_config "$radius_dir/sites-available/default"
    update_site_config "$radius_dir/sites-available/inner-tunnel"
    
    return 0
}

# Configure main radiusd.conf settings
configure_main_settings() {
    log "Configuring main radiusd.conf settings..."
    
    local radius_dir=$(find_freeradius_dir)
    local radiusd_conf="$radius_dir/radiusd.conf"
    
    if [ ! -f "$radiusd_conf" ]; then
        warn "radiusd.conf not found at $radiusd_conf"
        return 1
    fi
    
    # Optimize performance settings
    log "Optimizing performance settings..."
    sed -i 's/^max_requests =.*/max_requests = 4096/' "$radiusd_conf"
    sed -i 's/^max_request_time =.*/max_request_time = 30/' "$radiusd_conf"
    sed -i 's/^max_servers =.*/max_servers = 12/' "$radiusd_conf"
    
    # Update log settings
    log "Updating log settings..."
    mkdir -p "$radius_dir/radiusd.conf.d"
    mkdir -p /var/log/radius
    touch /var/log/radius/radius.log
    
    # Create main logging configuration
    cat > "$radius_dir/radiusd.conf.d/logging" << EOF
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
    
    # Create main log file with proper permissions
    touch /var/log/radius/radius.log
    
    # Set permissions
    if getent group | grep -q "^freerad:"; then
        RADIUS_USER="freerad"
    elif getent group | grep -q "^radiusd:"; then
        RADIUS_USER="radiusd"
    else
        RADIUS_USER="freerad"
    fi
    
    chown $RADIUS_USER:$RADIUS_USER /var/log/radius/radius.log
    chmod 644 /var/log/radius/radius.log
    
    return 0
}

# Configure default RADIUS clients
configure_default_clients() {
    log "Configuring default RADIUS clients..."
    
    local radius_dir=$(find_freeradius_dir)
    local clients_conf="$radius_dir/clients.conf"
    
    if [ ! -f "$clients_conf" ]; then
        touch "$clients_conf"
    fi
    
    # Backup original clients.conf
    cp -a "$clients_conf" "$clients_conf.orig.$(date +%Y%m%d%H%M%S)" || true
    
    # Create default clients
    cat > "$clients_conf" << EOF
# Default RADIUS client configuration
client localhost {
    ipaddr = 127.0.0.1
    secret = testing123
    shortname = localhost
    nastype = other
}

# OpenVPN server client
client openvpn_server {
    ipaddr = 10.8.0.1
    secret = vpn_radius_secret
    shortname = openvpn
    nastype = other
    require_message_authenticator = no
}
EOF
    
    # Set proper permissions
    if getent group | grep -q "^freerad:"; then
        RADIUS_USER="freerad"
    elif getent group | grep -q "^radiusd:"; then
        RADIUS_USER="radiusd"
    else
        RADIUS_USER="freerad"
    fi
    
    chown $RADIUS_USER:$RADIUS_USER "$clients_conf"
    chmod 640 "$clients_conf"
    
    return 0
}

# Create test user
create_test_user() {
    log "Creating test user..."
    
    local radius_dir=$(find_freeradius_dir)
    
    # Create test user in SQL if PostgreSQL is used
    if systemctl is-active --quiet postgresql; then
        su - postgres -c "psql -c \"INSERT INTO radcheck (username, attribute, op, value) 
                            VALUES ('testuser', 'Cleartext-Password', ':=', 'password') 
                            ON CONFLICT (username, attribute, op) 
                            DO UPDATE SET value = 'password';\" radius" || true
    fi
    
    # Also create in users file for backward compatibility
    mkdir -p "$radius_dir/users"
    cat > "$radius_dir/users/testuser" << EOF
# Test user - remove in production
testuser Cleartext-Password := "password"
        Reply-Message := "Hello, %{User-Name}"
EOF
    
    return 0
}

# Configure firewall for RADIUS
configure_firewall() {
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
        warn "Could not detect UFW or FirewallD. Please manually configure your firewall."
        log "Example: iptables -A INPUT -p udp --dport 1812 -j ACCEPT"
        log "Example: iptables -A INPUT -p udp --dport 1813 -j ACCEPT"
    fi
    
    return 0
}

# Display installation summary
display_installation_summary() {
    section "Installation Summary"
    
    echo -e "${GREEN}FreeRADIUS has been successfully installed and configured!${NC}"
    echo
    echo "Default test user created:"
    echo "  Username: testuser"
    echo "  Password: password"
    echo
    echo "Default client shared secret for localhost: testing123"
    echo "Default client shared secret for OpenVPN: vpn_radius_secret"
    echo
    if systemctl is-active --quiet postgresql; then
        echo "PostgreSQL database details:"
        echo "  Database: radius"
        echo "  Username: radius"
        echo "  Password: radpass"
    fi
    echo
    echo "To verify your installation, run:"
    echo "  radtest testuser password localhost 0 testing123"
    echo
    echo "To manage your FreeRADIUS server, use:"
    echo "  sudo bash radius.sh menu"
}
