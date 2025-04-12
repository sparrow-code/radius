# FreeRADIUS Server Setup

A comprehensive set of scripts to automate the installation, configuration, and management of a FreeRADIUS server with PostgreSQL integration.

## Features

- **Automated Installation**: Streamlined installation and configuration of FreeRADIUS with PostgreSQL backend
- **User Management**: Efficient tools to add, update, and manage RADIUS users and groups
- **Client Management**: Simple interface for adding and managing RADIUS clients
- **OpenVPN Integration**: Seamless integration with OpenVPN for authentication
- **PostgreSQL Integration**: Deep integration with PostgreSQL for scalable user and client data storage
- **Diagnostics**: Advanced diagnostic scripts for system verification and troubleshooting

## Prerequisites

- Ubuntu 18.04+ or Debian 10+ server
- Root or sudo privileges
- Basic knowledge of networking concepts

## Installation

1. Clone this repository:

   ```bash
   git clone https://github.com/sparrow-code/radius.git
   cd radius
   ```

2. Make the scripts executable:

   ```bash
   chmod +x *.sh
   ```

3. Run the main setup script:

   ```bash
   sudo ./start.sh
   ```

   Follow the interactive prompts to complete the installation.

## Usage

### Adding Users

To add a new RADIUS user:

```bash
sudo ./radius_add_user.sh <username> <password> [group]
```

Example:

```bash
sudo ./radius_add_user.sh john password123 vpnusers
```

### Adding Clients

To add a new RADIUS client:

```bash
sudo ./radius_add_client.sh <shortname> <ip_address> <shared_secret> [nastype]
```

Example:

```bash
sudo ./radius_add_client.sh vpn_server 192.168.1.10 mysecret openvpn
```

### OpenVPN Integration

To configure FreeRADIUS for OpenVPN integration:

```bash
sudo ./radius_openvpn_config.sh
```

Follow the prompts to complete the integration.

### PostgreSQL Integration

To set up PostgreSQL for FreeRADIUS:

```bash
sudo ./radius_postgresql_setup.sh
```

## Troubleshooting

### Common Issues

- **Service Not Starting**: Check the logs using `journalctl -u freeradius`.
- **Database Connection Issues**: Verify PostgreSQL settings in `pg_hba.conf`.
- **Authentication Failures**: Use `radtest` to test user authentication.

### Diagnostics

Run the diagnostics script to identify and fix common issues:

```bash
sudo ./vpn_diagnostics.sh
```

## PostgreSQL Configuration Details

The `radius_postgresql_setup.sh` script configures PostgreSQL with optimized settings for FreeRADIUS:

```
sql {
    # Connection pool optimization
    pool {
        start = 5
        min = 4
        max = 10
        idle_timeout = 300
        uses = 0
        lifetime = 0
        retry_delay = 30
        # Other pool settings...
    }

    # Read configuration
    read_clients = yes
    client_table = "nas"

    # Table configuration
    accounting_table = "radacct"
    # Other table settings...
}
```

## File Structure

```
radius/
├── start.sh                  # Main setup script
├── radius_add_user.sh        # User management script
├── radius_add_client.sh      # Client management script
├── radius_openvpn_config.sh  # OpenVPN integration script
├── radius_postgresql_setup.sh # PostgreSQL setup script
├── install_freeradius.sh     # FreeRADIUS installation script
├── vpn_diagnostics.sh        # Diagnostics script
└── README.md                 # Documentation
```

## Security Considerations

- Use strong passwords for RADIUS users and clients
- Restrict access to the RADIUS server using firewall rules
- Regularly update the server and scripts to patch vulnerabilities
- Follow the principle of least privilege for database access
- Enable TLS encryption for sensitive authentication data

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

1. Fork the repository
2. Create your feature branch (`git checkout -b feature/amazing-feature`)
3. Commit your changes (`git commit -m 'Add some amazing feature'`)
4. Push to the branch (`git push origin feature/amazing-feature`)
5. Open a Pull Request

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## Acknowledgements

- The FreeRADIUS team for their excellent authentication server
- The PostgreSQL community for their robust database system
- All contributors who have helped improve this project
