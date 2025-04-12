#!/bin/bash

# FreeRADIUS Manager - Consolidated Script
# This script provides a complete management interface for FreeRADIUS server
# Usage: sudo bash radius.sh [command] [options]
# 
# Author: [Your Name]
# Date: April 2025
# Version: 1.0

# Script directory
SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
UTILS_DIR="$SCRIPT_DIR/utils"
MODULES_DIR="$SCRIPT_DIR/modules"

# Source common utilities
source "$UTILS_DIR/common.sh" || {
    echo "Error: Could not load common utilities"
    exit 1
}

# Check if running as root
check_root

# Create modules directory if it doesn't exist
mkdir -p "$MODULES_DIR"

# Source module files
for module in "$MODULES_DIR"/*.sh; do
    if [ -f "$module" ]; then
        source "$module"
    fi
done

# Function to display help information
show_help() {
    echo -e "${BLUE}FreeRADIUS Manager ${NC}- Complete management tool for FreeRADIUS server"
    echo
    echo -e "Usage: ${GREEN}radius.sh${NC} [command] [options]"
    echo
    echo "Commands:"
    echo "  install             - Install and configure FreeRADIUS"
    echo "  fix                 - Fix common installation issues"
    echo "  status              - Check FreeRADIUS service status"
    echo "  service [action]    - Manage service (start|stop|restart|reload)"
    echo "  user [action]       - Manage users (list|add|delete|test)"
    echo "  client [action]     - Manage clients (list|add|delete)"
    echo "  database            - Configure and check PostgreSQL database"
    echo "  openvpn             - Configure OpenVPN integration"
    echo "  backup              - Back up FreeRADIUS configuration"
    echo "  restore             - Restore FreeRADIUS configuration from backup"
    echo "  logs [lines]        - View service logs"
    echo "  diagnostics         - Run diagnostics and fix common issues"
    echo "  menu                - Launch interactive menu interface"
    echo "  help                - Show this help information"
    echo
    echo "Examples:"
    echo "  radius.sh menu                     - Launch interactive menu"
    echo "  radius.sh install                  - Install FreeRADIUS with default settings"
    echo "  radius.sh user add username pwd    - Add/update a user"
    echo "  radius.sh client add name ip secret - Add/update a client"
    echo "  radius.sh openvpn                  - Configure OpenVPN integration"
    echo "  radius.sh logs 50                  - Show last 50 log lines"
}

# Main function
main() {
    if [ $# -eq 0 ]; then
        # No arguments - launch interactive menu
        launch_menu
    else
        # Parse command-line arguments
        case "$1" in
            install)
                shift
                install_freeradius "$@"
                ;;
            fix)
                shift
                fix_installation "$@"
                ;;
            status)
                check_status
                ;;
            service)
                if [ -z "$2" ]; then
                    error "Missing service action. Use: start, stop, restart, reload"
                    return 1
                fi
                manage_service "$2"
                ;;
            user)
                if [ -z "$2" ]; then
                    error "Missing user action. Use: list, add, delete, test"
                    return 1
                fi
                shift
                manage_users "$@"
                ;;
            client)
                if [ -z "$2" ]; then
                    error "Missing client action. Use: list, add, delete"
                    return 1
                fi
                shift
                manage_clients "$@"
                ;;
            database)
                shift
                manage_database "$@"
                ;;
            openvpn)
                shift
                configure_openvpn "$@"
                ;;
            backup)
                backup_config
                ;;
            restore)
                restore_config "$2"
                ;;
            logs)
                view_logs "${2:-20}"  # Default to 20 lines if not specified
                ;;
            diagnostics)
                run_diagnostics
                ;;
            menu)
                launch_menu
                ;;
            help|--help|-h)
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

# Run main with all arguments
main "$@"
