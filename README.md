# FreeRADIUS Server Setup

A comprehensive set of scripts to automate the installation, configuration, and management of a FreeRADIUS server with PostgreSQL integration.

## Features

- **Automated Installation**: Install and configure FreeRADIUS with PostgreSQL backend.
- **User Management**: Add, update, and manage RADIUS users and groups.
- **Client Management**: Add and manage RADIUS clients.
- **OpenVPN Integration**: Seamless integration with OpenVPN for authentication.
- **PostgreSQL Integration**: Deep integration with PostgreSQL for user and client data storage.
- **Diagnostics**: Scripts to verify and troubleshoot the setup.

## Prerequisites

- Ubuntu 18.04+ or Debian 10+ server
- Root or sudo privileges
- Basic knowledge of networking concepts

## Installation

1. Clone this repository:

   ```bash
   git clone https://github.com/yourusername/freeradius-setup.git
   cd freeradius-setup
   ```

2. Make the scripts executable:

   ```bash
   chmod +x *.sh
   ```

3. Run the main setup script:

   ```bash
   sudo ./start.sh
   ```

   Follow the interactive prompts to complete the setup.

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

## File Structure

```
freeradius-setup/
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

- Use strong passwords for RADIUS users and clients.
- Restrict access to the RADIUS server using firewall rules.
- Regularly update the server and scripts to patch vulnerabilities.

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

## License

This project is licensed under the MIT License - see the LICENSE file for details.
