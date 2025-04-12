# FreeRADIUS with PostgreSQL Integration

This document provides detailed information about the FreeRADIUS server installation, configuration, and integration with PostgreSQL.

## 1. Installation Process

The installation script (`install_freeradius.sh`) performs the following operations:

1. Updates the package repository
2. Installs FreeRADIUS and PostgreSQL packages
3. Creates the RADIUS database in PostgreSQL
4. Configures PostgreSQL for RADIUS access
5. Loads the PostgreSQL schema for RADIUS tables
6. Configures FreeRADIUS to use PostgreSQL
7. Sets up firewall rules for RADIUS ports
8. Creates a test user for verification

```bash
# Main installation packages
apt update && apt upgrade -y
apt install -y freeradius freeradius-postgresql postgresql postgresql-client

# Create database and user
su - postgres -c "psql -c \"CREATE USER radius WITH PASSWORD 'radpass';\""
su - postgres -c "psql -c \"CREATE DATABASE radius WITH OWNER radius;\""

# Load schema files
su - postgres -c "psql -d radius -f /etc/freeradius/3.0/mods-config/sql/main/postgresql/schema.sql"
su - postgres -c "psql -d radius -f /etc/freeradius/3.0/mods-config/sql/main/postgresql/setup.sql"
```

## 2. PostgreSQL Integration

The PostgreSQL integration (`radius_postgresql_setup.sh`) configures FreeRADIUS to use PostgreSQL as a backend for:

- User authentication data
- Group membership
- Client information
- Accounting records
- Post-auth logging

### SQL Module Configuration

```
sql {
    # Connection pool settings
    pool {
        start = 5
        min = 4
        max = 10
        idle_timeout = 300
        uses = 0
        lifetime = 0
        retry_delay = 30
    }

    # Connection information
    driver = "rlm_sql_postgresql"
    dialect = "postgresql"
    server = "localhost"
    port = 5432
    login = "radius"
    password = "radpass"
    database = "radius"

    # Tables configuration
    read_clients = yes
    client_table = "nas"
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
```

## 3. User Management

Users in FreeRADIUS with PostgreSQL are stored in the database tables. The `radius_add_user.sh` script provides a convenient way to add users:

```bash
./radius_add_user.sh username password [groupname]
```

### Database Tables

- `radcheck`: Stores user authentication information (username, attribute, value)
- `radreply`: Stores attributes to be returned to users after successful authentication
- `radusergroup`: Maps users to groups
- `radgroupcheck`: Stores authentication checks for groups
- `radgroupreply`: Stores attributes for groups

## 4. Client Management

The `radius_add_client.sh` script adds NAS clients to the database:

```bash
./radius_add_client.sh name ipaddress secret [nastype]
```

### Client Configuration

Clients are stored in the `nas` table with the following information:
- Shortname (identifier)
- IP address or network
- Shared secret
- NAS type (optional)

## 5. OpenVPN Integration

The `radius_openvpn_config.sh` script configures FreeRADIUS for OpenVPN authentication:

1. Creates specific users or groups for OpenVPN access
2. Configures attribute settings specific to OpenVPN
3. Sets up the required OpenVPN NAS client

### Example Configuration

```
# OpenVPN client entry
client openvpn_server {
    ipaddr = 192.168.1.10
    secret = vpn_shared_secret
    shortname = openvpn
    nastype = other
    
    # OpenVPN specific attributes
    Framed-Protocol = PPP
    Service-Type = Framed-User
}
```

## 6. Performance Optimization

The scripts configure FreeRADIUS with performance settings suitable for most environments:

```
# Connection pool optimization
max_requests = 4096
max_request_time = 30
max_servers = 12

# Database connection optimization
sql {
    pool {
        start = 5
        min = 4
        max = 10
        idle_timeout = 300
        uses = 0
    }
}
```

## 7. Security Considerations

- Use strong passwords for the radius database user
- Use strong shared secrets for RADIUS clients
- Consider using TLS for RADIUS authentication
- Implement regular security updates
- Restrict database access to the RADIUS server only
- Configure proper firewall rules for RADIUS ports (1812/1813 UDP)

## 8. Troubleshooting

Common issues and their solutions:

1. **FreeRADIUS service fails to start**
   - Check logs: `journalctl -u freeradius`
   - Verify SQL configuration
   - Check database connectivity

2. **Authentication failures**
   - Use `radtest` to test authentication
   - Verify user exists in database
   - Check client configuration

3. **Database connection issues**
   - Verify PostgreSQL is running
   - Check pg_hba.conf settings
   - Test connection with `psql -h localhost -U radius -d radius`

4. **SQL module issues**
   - Run the validation script: `/etc/freeradius/3.0/sql_module_check.sh`
   - Enable SQL in site configurations
   - Check SQL module is enabled in mods-enabled

## 9. Logging and Monitoring

FreeRADIUS logs are configured to provide detailed information:

```
log {
    destination = files
    file = /var/log/radius/radius.log
    syslog_facility = daemon
    stripped_names = yes
    auth = yes
    auth_badpass = yes
    auth_goodpass = yes
}
```

Monitor these logs for authentication issues and access patterns.
