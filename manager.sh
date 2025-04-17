#!/bin/bash
# RADIUS Management Script
# This script provides a standardized interface for the ISP management system
# to interact with the FreeRADIUS server installation.

# Set strict error handling
set -e

# Source utility functions if available
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${SCRIPT_DIR}/utils/common.sh" ]]; then
  source "${SCRIPT_DIR}/utils/common.sh"
fi

# Configuration paths
BASE_DIR="${SCRIPT_DIR}"
RADIUS_CONFIG_DIR="/etc/freeradius/3.0"
CLIENTS_CONFIG="${RADIUS_CONFIG_DIR}/clients.conf"
USERS_FILE="${RADIUS_CONFIG_DIR}/users"

# Function to display usage information
usage() {
  echo "Usage: $0 command [options]"
  echo
  echo "Commands:"
  echo "  list-clients          List all RADIUS clients"
  echo "  get-client            Get details for a specific client"
  echo "  create-client         Create a new RADIUS client"
  echo "  update-client         Update an existing RADIUS client"
  echo "  delete-client         Delete a RADIUS client"
  echo
  echo "  list-users            List all RADIUS users"
  echo "  get-user              Get details for a specific user"
  echo "  create-user           Create a new RADIUS user"
  echo "  update-user           Update an existing RADIUS user"
  echo "  delete-user           Delete a RADIUS user"
  echo "  batch-users           Batch operation for users"
  echo
  echo "  list-groups           List all RADIUS user groups"
  echo "  get-group             Get details for a specific group"
  echo "  create-group          Create a new RADIUS user group"
  echo "  update-group          Update an existing RADIUS user group"
  echo "  delete-group          Delete a RADIUS user group"
  echo
  echo "  server-status         Check RADIUS server status"
  echo "  server-restart        Restart the RADIUS server"
  echo
  echo "Options:"
  echo "  --name=NAME           Client/User name (required for client/user operations)"
  echo "  --shortname=NAME      Short name for client"
  echo "  --ip=IP               Client IP address"
  echo "  --nas=ID              NAS identifier for client"
  echo "  --secret=SECRET       Shared secret for client"
  echo "  --description=DESC    Description for client/user/group"
  echo "  --username=USER       Username (for user operations)"
  echo "  --password=PASS       Password (for user operations)"
  echo "  --group=GROUP         Group name for user"
  echo "  --sim-use=NUM         Simultaneous use limit"
  echo "  --status=STATUS       Status (active/inactive)"
  echo "  --batch=FILE          JSON file for batch operations"
  echo
  exit 1
}

# Function to parse command line arguments
parse_args() {
  for i in "$@"; do
    case $i in
      --name=*)
        NAME="${i#*=}"
        shift
        ;;
      --shortname=*)
        SHORTNAME="${i#*=}"
        shift
        ;;
      --ip=*)
        IP_ADDRESS="${i#*=}"
        shift
        ;;
      --nas=*)
        NAS_IDENTIFIER="${i#*=}"
        shift
        ;;
      --secret=*)
        SECRET="${i#*=}"
        shift
        ;;
      --description=*)
        DESCRIPTION="${i#*=}"
        shift
        ;;
      --username=*)
        USERNAME="${i#*=}"
        shift
        ;;
      --password=*)
        PASSWORD="${i#*=}"
        shift
        ;;
      --group=*)
        GROUP="${i#*=}"
        shift
        ;;
      --sim-use=*)
        SIM_USE="${i#*=}"
        shift
        ;;
      --status=*)
        STATUS="${i#*=}"
        shift
        ;;
      --batch=*)
        BATCH_FILE="${i#*=}"
        shift
        ;;
      *)
        # Unknown option
        ;;
    esac
  done
}

# Function to list all clients
list_clients() {
  echo "==================================================="
  echo "           RADIUS Management System"
  echo "==================================================="
  echo
  echo "List of RADIUS Clients"
  echo

  # Use radclient to list clients or directly parse the clients.conf file
  if [ -f "${CLIENTS_CONFIG}" ]; then
    echo "Client List:"
    grep -E "^client [a-zA-Z0-9_-]+ {" "${CLIENTS_CONFIG}" | sed 's/client \(.*\) {/\1/'
    echo
    echo "Detailed Information:"
    awk '/^client/,/^}/ { if ($0 ~ /ipaddr|secret|shortname|nas_type/) print $0 }' "${CLIENTS_CONFIG}"
  else
    echo "RADIUS clients configuration file not found at ${CLIENTS_CONFIG}"
    exit 1
  fi
}

# Function to get client details
get_client() {
  if [[ -z "${NAME}" ]]; then
    echo "Error: Client name is required"
    usage
    exit 1
  fi
  
  echo "==================================================="
  echo "           RADIUS Management System"
  echo "==================================================="
  echo
  echo "Client Details: ${NAME}"
  echo

  if [ -f "${CLIENTS_CONFIG}" ]; then
    # Extract client block using awk
    client_info=$(awk "/^client ${NAME} {/,/^}/" "${CLIENTS_CONFIG}")
    
    if [ -n "$client_info" ]; then
      echo "$client_info"
    else
      echo "Client '${NAME}' not found."
      exit 1
    fi
  else
    echo "RADIUS clients configuration file not found at ${CLIENTS_CONFIG}"
    exit 1
  fi
}

# Function to create a new client
create_client() {
  if [[ -z "${NAME}" || -z "${IP_ADDRESS}" || -z "${SECRET}" ]]; then
    echo "Error: Client name, IP address and secret are required"
    usage
    exit 1
  fi

  echo "==================================================="
  echo "           RADIUS Management System"
  echo "==================================================="
  echo
  echo "Creating new RADIUS client: ${NAME}"
  echo

  # Check if client already exists
  if grep -q "^client ${NAME} {" "${CLIENTS_CONFIG}"; then
    echo "Error: Client '${NAME}' already exists"
    exit 1
  fi

  # Create the client config block
  cat << EOF >> "${CLIENTS_CONFIG}"

client ${NAME} {
	ipaddr = ${IP_ADDRESS}
	secret = ${SECRET}
	shortname = ${SHORTNAME:-$NAME}
	nas_type = other
	require_message_authenticator = no
EOF

  # Add description if provided
  if [[ -n "${DESCRIPTION}" ]]; then
    echo -e "\t# ${DESCRIPTION}" >> "${CLIENTS_CONFIG}"
  fi

  # Add NAS identifier if provided
  if [[ -n "${NAS_IDENTIFIER}" ]]; then
    echo -e "\t# NAS-Identifier: ${NAS_IDENTIFIER}" >> "${CLIENTS_CONFIG}"
  fi

  # Close the client block
  echo "}" >> "${CLIENTS_CONFIG}"

  # Restart FreeRADIUS to apply changes
  systemctl restart freeradius

  echo "RADIUS client '${NAME}' created successfully"
}

# Function to update a client
update_client() {
  if [[ -z "${NAME}" ]]; then
    echo "Error: Client name is required"
    usage
    exit 1
  fi

  echo "==================================================="
  echo "           RADIUS Management System"
  echo "==================================================="
  echo
  echo "Updating RADIUS client: ${NAME}"
  echo

  # Check if client exists
  if ! grep -q "^client ${NAME} {" "${CLIENTS_CONFIG}"; then
    echo "Error: Client '${NAME}' does not exist"
    exit 1
  fi

  # Create a temporary file
  tmp_file=$(mktemp)

  # Extract client block
  awk -v client="${NAME}" -v ip="${IP_ADDRESS}" -v secret="${SECRET}" -v shortname="${SHORTNAME}" \
      -v nas="${NAS_IDENTIFIER}" -v desc="${DESCRIPTION}" '
    BEGIN { in_block = 0; updated = 0 }
    /^client '"${NAME}"' {/ { 
      in_block = 1; 
      print $0; 
      updated = 1; 
      next;
    }
    in_block && /^}/ { 
      in_block = 0; 
      print $0; 
      next;
    }
    in_block && /ipaddr =/ && ip != "" { 
      print "\tipaddr = " ip; 
      updated = 1; 
      next;
    }
    in_block && /secret =/ && secret != "" { 
      print "\tsecret = " secret; 
      updated = 1; 
      next;
    }
    in_block && /shortname =/ && shortname != "" { 
      print "\tshortname = " shortname; 
      updated = 1; 
      next;
    }
    in_block && /# NAS-Identifier:/ && nas != "" { 
      print "\t# NAS-Identifier: " nas; 
      updated = 1; 
      next;
    }
    in_block && /# / && desc != "" && !updated_desc { 
      print "\t# " desc; 
      updated = 1; 
      updated_desc = 1;
      next;
    }
    { print $0 }
  ' "${CLIENTS_CONFIG}" > "${tmp_file}"

  # Replace the original file
  mv "${tmp_file}" "${CLIENTS_CONFIG}"

  # Restart FreeRADIUS to apply changes
  systemctl restart freeradius

  echo "RADIUS client '${NAME}' updated successfully"
}

# Function to delete a client
delete_client() {
  if [[ -z "${NAME}" ]]; then
    echo "Error: Client name is required"
    usage
    exit 1
  fi

  echo "==================================================="
  echo "           RADIUS Management System"
  echo "==================================================="
  echo
  echo "Deleting RADIUS client: ${NAME}"
  echo

  # Check if client exists
  if ! grep -q "^client ${NAME} {" "${CLIENTS_CONFIG}"; then
    echo "Error: Client '${NAME}' does not exist"
    exit 1
  fi

  # Create a temporary file
  tmp_file=$(mktemp)

  # Remove client block
  awk -v client="${NAME}" '
    BEGIN { skip = 0; }
    /^client '"${NAME}"' {/ { skip = 1; next; }
    /^}/ && skip { skip = 0; next; }
    !skip { print $0; }
  ' "${CLIENTS_CONFIG}" > "${tmp_file}"

  # Replace the original file
  mv "${tmp_file}" "${CLIENTS_CONFIG}"

  # Restart FreeRADIUS to apply changes
  systemctl restart freeradius

  echo "RADIUS client '${NAME}' deleted successfully"
}

# Function to list all users
list_users() {
  echo "==================================================="
  echo "           RADIUS Management System"
  echo "==================================================="
  echo
  echo "List of RADIUS Users"
  echo

  # Check if we're using SQL backend or users file
  if grep -q "sql" "${RADIUS_CONFIG_DIR}/sites-enabled/default"; then
    # Using SQL backend, query the database
    echo "RADIUS is using SQL backend. Users stored in database."
    if command -v mysql >/dev/null 2>&1; then
      # Try to read from MySQL if available
      mysql -N -B -e "SELECT username, attribute, value FROM radcheck;" 2>/dev/null || echo "Unable to query MySQL database"
    elif command -v psql >/dev/null 2>&1; then
      # Try to read from PostgreSQL if available
      psql -t -c "SELECT username, attribute, value FROM radcheck;" 2>/dev/null || echo "Unable to query PostgreSQL database"
    else
      echo "Cannot access the SQL database directly. Consider using the radiusd management tools."
    fi
  elif [ -f "${USERS_FILE}" ]; then
    # Using flat file backend
    grep -v "^#" "${USERS_FILE}" | grep -v "^$" | sort
  else
    echo "Cannot find users configuration. Please check your FreeRADIUS setup."
  fi
}

# Function to get user details
get_user() {
  if [[ -z "${USERNAME}" ]]; then
    echo "Error: Username is required"
    usage
    exit 1
  fi
  
  echo "==================================================="
  echo "           RADIUS Management System"
  echo "==================================================="
  echo
  echo "User Details: ${USERNAME}"
  echo

  # Check if we're using SQL backend or users file
  if grep -q "sql" "${RADIUS_CONFIG_DIR}/sites-enabled/default"; then
    # Using SQL backend
    if command -v mysql >/dev/null 2>&1; then
      mysql -e "SELECT * FROM radcheck WHERE username='${USERNAME}';" 2>/dev/null || echo "Unable to query MySQL database"
      mysql -e "SELECT * FROM radreply WHERE username='${USERNAME}';" 2>/dev/null || echo "Unable to query MySQL database"
    elif command -v psql >/dev/null 2>&1; then
      psql -c "SELECT * FROM radcheck WHERE username='${USERNAME}';" 2>/dev/null || echo "Unable to query PostgreSQL database"
      psql -c "SELECT * FROM radreply WHERE username='${USERNAME}';" 2>/dev/null || echo "Unable to query PostgreSQL database"
    else
      echo "Cannot access the SQL database directly."
    fi
  elif [ -f "${USERS_FILE}" ]; then
    # Using flat file backend
    grep -A 10 "^${USERNAME}" "${USERS_FILE}" | sed '/^$/q'
  else
    echo "Cannot find users configuration. Please check your FreeRADIUS setup."
  fi
}

# Function to create a new user
create_user() {
  if [[ -z "${USERNAME}" || -z "${PASSWORD}" ]]; then
    echo "Error: Username and password are required"
    usage
    exit 1
  fi

  echo "==================================================="
  echo "           RADIUS Management System"
  echo "==================================================="
  echo
  echo "Creating new RADIUS user: ${USERNAME}"
  echo

  # Check if we're using SQL backend or users file
  if grep -q "sql" "${RADIUS_CONFIG_DIR}/sites-enabled/default"; then
    # Using SQL backend
    if command -v mysql >/dev/null 2>&1; then
      # Try MySQL
      mysql -e "INSERT INTO radcheck (username, attribute, op, value) VALUES ('${USERNAME}', 'Cleartext-Password', ':=', '${PASSWORD}');" || echo "Unable to update MySQL database"
      
      # Add group if provided
      if [[ -n "${GROUP}" ]]; then
        mysql -e "INSERT INTO radusergroup (username, groupname, priority) VALUES ('${USERNAME}', '${GROUP}', 1);" || echo "Unable to update MySQL database"
      fi
      
      # Add simultaneous use limit if provided
      if [[ -n "${SIM_USE}" ]]; then
        mysql -e "INSERT INTO radcheck (username, attribute, op, value) VALUES ('${USERNAME}', 'Simultaneous-Use', ':=', '${SIM_USE}');" || echo "Unable to update MySQL database"
      fi
      
    elif command -v psql >/dev/null 2>&1; then
      # Try PostgreSQL
      psql -c "INSERT INTO radcheck (username, attribute, op, value) VALUES ('${USERNAME}', 'Cleartext-Password', ':=', '${PASSWORD}');" || echo "Unable to update PostgreSQL database"
      
      # Add group if provided
      if [[ -n "${GROUP}" ]]; then
        psql -c "INSERT INTO radusergroup (username, groupname, priority) VALUES ('${USERNAME}', '${GROUP}', 1);" || echo "Unable to update PostgreSQL database"
      fi
      
      # Add simultaneous use limit if provided
      if [[ -n "${SIM_USE}" ]]; then
        psql -c "INSERT INTO radcheck (username, attribute, op, value) VALUES ('${USERNAME}', 'Simultaneous-Use', ':=', '${SIM_USE}');" || echo "Unable to update PostgreSQL database"
      fi
      
    else
      echo "Cannot access the SQL database directly."
      exit 1
    fi
  elif [ -f "${USERS_FILE}" ]; then
    # Using flat file backend
    if grep -q "^${USERNAME}" "${USERS_FILE}"; then
      echo "Error: User '${USERNAME}' already exists"
      exit 1
    fi
    
    # Create user entry
    cat << EOF >> "${USERS_FILE}"

${USERNAME}  Cleartext-Password := "${PASSWORD}"
EOF

    # Add group if provided
    if [[ -n "${GROUP}" ]]; then
      echo "       Auth-Type := Local," >> "${USERS_FILE}"
      echo "       Group := \"${GROUP}\"" >> "${USERS_FILE}"
    fi
    
    # Add simultaneous use limit if provided
    if [[ -n "${SIM_USE}" ]]; then
      echo "       Simultaneous-Use := ${SIM_USE}" >> "${USERS_FILE}"
    fi
    
    # Add description if provided
    if [[ -n "${DESCRIPTION}" ]]; then
      echo "       # ${DESCRIPTION}" >> "${USERS_FILE}"
    fi
  else
    echo "Cannot find users configuration. Please check your FreeRADIUS setup."
    exit 1
  fi
  
  # Restart FreeRADIUS to apply changes
  systemctl restart freeradius

  echo "RADIUS user '${USERNAME}' created successfully"
}

# Function to update a user
update_user() {
  if [[ -z "${USERNAME}" ]]; then
    echo "Error: Username is required"
    usage
    exit 1
  fi

  echo "==================================================="
  echo "           RADIUS Management System"
  echo "==================================================="
  echo
  echo "Updating RADIUS user: ${USERNAME}"
  echo

  # Check if we're using SQL backend or users file
  if grep -q "sql" "${RADIUS_CONFIG_DIR}/sites-enabled/default"; then
    # Using SQL backend
    if command -v mysql >/dev/null 2>&1; then
      # Check if user exists
      user_exists=$(mysql -N -B -e "SELECT COUNT(*) FROM radcheck WHERE username='${USERNAME}';" 2>/dev/null)
      
      if [ "$user_exists" -eq 0 ]; then
        echo "Error: User '${USERNAME}' does not exist"
        exit 1
      fi
      
      # Update password if provided
      if [[ -n "${PASSWORD}" ]]; then
        mysql -e "UPDATE radcheck SET value='${PASSWORD}' WHERE username='${USERNAME}' AND attribute='Cleartext-Password';" || echo "Unable to update MySQL database"
      fi
      
      # Update group if provided
      if [[ -n "${GROUP}" ]]; then
        if mysql -N -B -e "SELECT COUNT(*) FROM radusergroup WHERE username='${USERNAME}';" 2>/dev/null | grep -q "0"; then
          mysql -e "INSERT INTO radusergroup (username, groupname, priority) VALUES ('${USERNAME}', '${GROUP}', 1);" || echo "Unable to update MySQL database"
        else
          mysql -e "UPDATE radusergroup SET groupname='${GROUP}' WHERE username='${USERNAME}';" || echo "Unable to update MySQL database"
        fi
      fi
      
      # Update simultaneous use limit if provided
      if [[ -n "${SIM_USE}" ]]; then
        if mysql -N -B -e "SELECT COUNT(*) FROM radcheck WHERE username='${USERNAME}' AND attribute='Simultaneous-Use';" 2>/dev/null | grep -q "0"; then
          mysql -e "INSERT INTO radcheck (username, attribute, op, value) VALUES ('${USERNAME}', 'Simultaneous-Use', ':=', '${SIM_USE}');" || echo "Unable to update MySQL database"
        else
          mysql -e "UPDATE radcheck SET value='${SIM_USE}' WHERE username='${USERNAME}' AND attribute='Simultaneous-Use';" || echo "Unable to update MySQL database"
        fi
      fi
      
    elif command -v psql >/dev/null 2>&1; then
      # Similar logic for PostgreSQL
      user_exists=$(psql -t -c "SELECT COUNT(*) FROM radcheck WHERE username='${USERNAME}';" 2>/dev/null)
      
      if [ "$user_exists" -eq 0 ]; then
        echo "Error: User '${USERNAME}' does not exist"
        exit 1
      fi
      
      # Update password if provided
      if [[ -n "${PASSWORD}" ]]; then
        psql -c "UPDATE radcheck SET value='${PASSWORD}' WHERE username='${USERNAME}' AND attribute='Cleartext-Password';" || echo "Unable to update PostgreSQL database"
      fi
      
      # Other updates similar to MySQL...
    fi
  elif [ -f "${USERS_FILE}" ]; then
    # Using flat file backend - for simplicity, we'll just create a temp file
    if ! grep -q "^${USERNAME}" "${USERS_FILE}"; then
      echo "Error: User '${USERNAME}' does not exist"
      exit 1
    fi
    
    tmp_file=$(mktemp)
    
    # Process the users file, updating the specified user
    awk -v username="${USERNAME}" -v password="${PASSWORD}" -v group="${GROUP}" -v simuse="${SIM_USE}" -v desc="${DESCRIPTION}" '
      BEGIN { in_user = 0; skip_user = 0; updated_pw = 0; updated_group = 0; updated_sim = 0; skip_to_next = 0; }
      
      # Start of our target user section
      $1 == username { 
        in_user = 1;
        print $0;
        next;
      }
      
      # We are inside our user section
      in_user && /Cleartext-Password/ && password != "" {
        print "       Cleartext-Password := \"" password "\"";
        updated_pw = 1;
        skip_to_next = 1;
        next;
      }
      
      # Handle group update
      in_user && /Group/ && group != "" {
        print "       Group := \"" group "\"";
        updated_group = 1;
        skip_to_next = 1;
        next;
      }
      
      # Handle simultaneous use update
      in_user && /Simultaneous-Use/ && simuse != "" {
        print "       Simultaneous-Use := " simuse;
        updated_sim = 1;
        skip_to_next = 1;
        next;
      }
      
      # End of a user section or start of next user
      in_user && ($1 ~ /^[a-zA-Z0-9_]+$/ || $0 ~ /^$/) {
        # We found the end of our user or start of next user
        if (password != "" && !updated_pw) {
          print "       Cleartext-Password := \"" password "\"";
        }
        if (group != "" && !updated_group) {
          print "       Group := \"" group "\"";
        }
        if (simuse != "" && !updated_sim) {
          print "       Simultaneous-Use := " simuse;
        }
        if (desc != "") {
          print "       # " desc;
        }
        in_user = 0;
      }
      
      # Print current line if not skipping
      !skip_to_next { print $0; }
      skip_to_next = 0;
      
    ' "${USERS_FILE}" > "${tmp_file}"
    
    # Replace original file
    mv "${tmp_file}" "${USERS_FILE}"
  else
    echo "Cannot find users configuration. Please check your FreeRADIUS setup."
    exit 1
  fi
  
  # Restart FreeRADIUS to apply changes
  systemctl restart freeradius

  echo "RADIUS user '${USERNAME}' updated successfully"
}

# Function to delete a user
delete_user() {
  if [[ -z "${USERNAME}" ]]; then
    echo "Error: Username is required"
    usage
    exit 1
  fi

  echo "==================================================="
  echo "           RADIUS Management System"
  echo "==================================================="
  echo
  echo "Deleting RADIUS user: ${USERNAME}"
  echo

  # Check if we're using SQL backend or users file
  if grep -q "sql" "${RADIUS_CONFIG_DIR}/sites-enabled/default"; then
    # Using SQL backend
    if command -v mysql >/dev/null 2>&1; then
      # Check if user exists
      user_exists=$(mysql -N -B -e "SELECT COUNT(*) FROM radcheck WHERE username='${USERNAME}';" 2>/dev/null)
      
      if [ "$user_exists" -eq 0 ]; then
        echo "Error: User '${USERNAME}' does not exist"
        exit 1
      fi
      
      # Delete user from all related tables
      mysql -e "DELETE FROM radcheck WHERE username='${USERNAME}';" || echo "Unable to update MySQL database"
      mysql -e "DELETE FROM radreply WHERE username='${USERNAME}';" || echo "Unable to update MySQL database"
      mysql -e "DELETE FROM radusergroup WHERE username='${USERNAME}';" || echo "Unable to update MySQL database"
      
    elif command -v psql >/dev/null 2>&1; then
      # Similar logic for PostgreSQL
      user_exists=$(psql -t -c "SELECT COUNT(*) FROM radcheck WHERE username='${USERNAME}';" 2>/dev/null)
      
      if [ "$user_exists" -eq 0 ]; then
        echo "Error: User '${USERNAME}' does not exist"
        exit 1
      fi
      
      psql -c "BEGIN; DELETE FROM radcheck WHERE username='${USERNAME}'; DELETE FROM radreply WHERE username='${USERNAME}'; DELETE FROM radusergroup WHERE username='${USERNAME}'; COMMIT;" || echo "Unable to update PostgreSQL database"
    fi
  elif [ -f "${USERS_FILE}" ]; then
    # Using flat file backend
    if ! grep -q "^${USERNAME}" "${USERS_FILE}"; then
      echo "Error: User '${USERNAME}' does not exist"
      exit 1
    fi
    
    tmp_file=$(mktemp)
    
    # Process the users file, removing the specified user
    awk -v username="${USERNAME}" '
      BEGIN { skip = 0; }
      $1 == username { skip = 1; next; }
      /^[a-zA-Z0-9_]+/ { if (skip) skip = 0; }
      !skip { print $0; }
    ' "${USERS_FILE}" > "${tmp_file}"
    
    # Replace original file
    mv "${tmp_file}" "${USERS_FILE}"
  else
    echo "Cannot find users configuration. Please check your FreeRADIUS setup."
    exit 1
  fi
  
  # Restart FreeRADIUS to apply changes
  systemctl restart freeradius

  echo "RADIUS user '${USERNAME}' deleted successfully"
}

# Function to perform batch operations on users
batch_users() {
  if [[ -z "${BATCH_FILE}" ]]; then
    echo "Error: Batch file is required"
    usage
    exit 1
  }

  echo "==================================================="
  echo "           RADIUS Management System"
  echo "==================================================="
  echo
  echo "Performing batch operation on RADIUS users"
  echo

  # Check if batch file exists
  if [[ ! -f "${BATCH_FILE}" ]]; then
    echo "Error: Batch file '${BATCH_FILE}' not found"
    exit 1
  fi
  
  # Parse JSON file - requires jq
  if ! command -v jq >/dev/null 2>&1; then
    echo "Error: jq is required for batch operations. Please install it with 'apt-get install jq'"
    exit 1
  }
  
  # Process each user in the batch file
  user_count=$(jq length "${BATCH_FILE}")
  echo "Found ${user_count} users in batch file."
  
  # Check if we're using SQL backend
  using_sql=false
  if grep -q "sql" "${RADIUS_CONFIG_DIR}/sites-enabled/default"; then
    using_sql=true
  fi
  
  for (( i=0; i<${user_count}; i++ )); do
    username=$(jq -r ".[$i].username" "${BATCH_FILE}")
    password=$(jq -r ".[$i].password" "${BATCH_FILE}")
    group=$(jq -r ".[$i].group // \"\"" "${BATCH_FILE}")
    sim_use=$(jq -r ".[$i].simultaneous_use // \"\"" "${BATCH_FILE}")
    status=$(jq -r ".[$i].status // \"active\"" "${BATCH_FILE}")
    operation=$(jq -r ".[$i].operation // \"add\"" "${BATCH_FILE}")
    
    echo "Processing user: ${username} (${operation})"
    
    case "${operation}" in
      "add"|"update")
        # Check if user already exists
        user_exists=false
        if ${using_sql}; then
          if command -v mysql >/dev/null 2>&1; then
            count=$(mysql -N -B -e "SELECT COUNT(*) FROM radcheck WHERE username='${username}';" 2>/dev/null)
            [[ "$count" -gt 0 ]] && user_exists=true
          elif command -v psql >/dev/null 2>&1; then
            count=$(psql -t -c "SELECT COUNT(*) FROM radcheck WHERE username='${username}';" 2>/dev/null)
            [[ "$count" -gt 0 ]] && user_exists=true
          fi
        else
          grep -q "^${username}" "${USERS_FILE}" && user_exists=true
        fi
        
        if ${user_exists} && [ "${operation}" == "add" ]; then
          echo "  User already exists, updating instead."
          operation="update"
        elif ! ${user_exists} && [ "${operation}" == "update" ]; then
          echo "  User doesn't exist, creating new user."
          operation="add"
        fi
        
        # Set variables for the user operation
        USERNAME="${username}"
        PASSWORD="${password}"
        GROUP="${group}"
        SIM_USE="${sim_use}"
        STATUS="${status}"
        
        if [ "${operation}" == "add" ]; then
          create_user
        else
          update_user
        fi
        ;;
        
      "delete")
        USERNAME="${username}"
        delete_user
        ;;
        
      *)
        echo "Unknown operation: ${operation} for user ${username}"
        ;;
    esac
  done
  
  echo "Batch operation completed."
}

# Function to list all groups
list_groups() {
  echo "==================================================="
  echo "           RADIUS Management System"
  echo "==================================================="
  echo
  echo "List of RADIUS User Groups"
  echo

  # Check if we're using SQL backend
  if grep -q "sql" "${RADIUS_CONFIG_DIR}/sites-enabled/default"; then
    # Using SQL backend
    if command -v mysql >/dev/null 2>&1; then
      mysql -e "SELECT DISTINCT groupname FROM radgroupcheck ORDER BY groupname;" 2>/dev/null || echo "Unable to query MySQL database"
    elif command -v psql >/dev/null 2>&1; then
      psql -c "SELECT DISTINCT groupname FROM radgroupcheck ORDER BY groupname;" 2>/dev/null || echo "Unable to query PostgreSQL database"
    else
      echo "Cannot access the SQL database directly."
    fi
  else
    # Using file-based configuration
    echo "Groups are configured in configuration files. Listing from files:"
    for file in "${RADIUS_CONFIG_DIR}/users" "${RADIUS_CONFIG_DIR}/policy.d/"*; do
      if [ -f "$file" ]; then
        echo "From $file:"
        grep -o "Group\s*:=\s*\"[^\"]*\"" "$file" | sort | uniq | sed 's/Group\s*:=\s*\"//;s/\"$//'
      fi
    done
  fi
}

# Function to check server status
server_status() {
  echo "==================================================="
  echo "           RADIUS Management System"
  echo "==================================================="
  echo
  echo "RADIUS Server Status"
  echo
  
  # Check if RADIUS service is running
  systemctl status freeradius --no-pager
  
  echo
  echo "Listening ports:"
  if command -v ss >/dev/null 2>&1; then
    ss -tuln | grep -E '1812|1813' || echo "RADIUS ports not listening"
  elif command -v netstat >/dev/null 2>&1; then
    netstat -tuln | grep -E '1812|1813' || echo "RADIUS ports not listening"
  else
    echo "Cannot check listening ports - ss or netstat not available"
  fi
  
  echo
  echo "Recent authentication attempts:"
  if [ -f /var/log/freeradius/radius.log ]; then
    tail -n 20 /var/log/freeradius/radius.log | grep -E "Auth:|Login|logout"
  elif [ -f /var/log/freeradius/auth.log ]; then
    tail -n 20 /var/log/freeradius/auth.log
  else
    echo "Cannot find RADIUS log files"
  fi
}

# Function to restart server
server_restart() {
  echo "==================================================="
  echo "           RADIUS Management System"
  echo "==================================================="
  echo
  echo "Restarting RADIUS Server"
  echo
  
  # Restart FreeRADIUS service
  systemctl restart freeradius
  
  # Wait a moment for the service to start
  sleep 2
  
  # Check status
  if systemctl is-active --quiet freeradius; then
    echo "RADIUS server restarted successfully"
  else
    echo "Failed to restart RADIUS server"
    echo "Server status:"
    systemctl status freeradius --no-pager
    exit 1
  fi
}

# Main script execution
if [[ $# -lt 1 ]]; then
  usage
fi

# Parse command line arguments
parse_args "$@"

# Execute command
case "$1" in
  list-clients)
    list_clients
    ;;
  get-client)
    get_client
    ;;
  create-client)
    create_client
    ;;
  update-client)
    update_client
    ;;
  delete-client)
    delete_client
    ;;
  list-users)
    list_users
    ;;
  get-user)
    get_user
    ;;
  create-user)
    create_user
    ;;
  update-user)
    update_user
    ;;
  delete-user)
    delete_user
    ;;
  batch-users)
    batch_users
    ;;
  list-groups)
    list_groups
    ;;
  server-status)
    server_status
    ;;
  server-restart)
    server_restart
    ;;
  *)
    echo "Error: Unknown command '$1'"
    usage
    ;;
esac

exit 0
