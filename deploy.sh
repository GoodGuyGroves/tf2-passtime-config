#!/usr/bin/env bash

# Failing commands cause the script to exit immediately
set -e
# Errors on undefined variables
set -u
# Don't hide errors in pipes
set -o pipefail

debug_mode=0
_debug() {
    if (( "${debug_mode}" == 0 )); then
        printf "[DEBUG]\t $(date +%T) %s - %s\n" "${1}" "${2}" >&2
    fi
}

_info() {
    printf "[INFO]\t $(date +%T) %s - %s\n" "${1}" "${2}" >&2
}

_error() {
    printf "[ERROR]\t $(date +%T) %s - %s\n" "${1}" "${2}" >&2
}

# Function to escape special characters for sed replacement string
escape_for_sed() {
    # Escape backslashes, forward slashes, ampersands, and newlines
    printf '%s\n' "$1" | sed -e 's/[\/&]/\\&/g' | sed ':a;N;$!ba;s/\n/\\n/g'
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/config.json"
TF_SOURCE="$SCRIPT_DIR/tf"
RCONRC="$HOME/.rconrc"

# Check if jq is installed
if ! command -v jq &> /dev/null; then
  _error "${FUNCNAME[0]}" "jq is required but not installed"
  exit 1
fi

# Read environment variables (passed from GitHub Actions)
DEMOSTF_APIKEY="${DEMOSTF_APIKEY:-changeme}"
LOGSTF_APIKEY="${LOGSTF_APIKEY:-changeme}"
SV_PASSWORD="${SV_PASSWORD:-changeme}"

# Function to update server.cfg with secrets
update_server_cfg() {
  local server_name=$1
  local server_path=$2
  local server_cfg="$server_path/tf/cfg/server.cfg"
    
  # Get server-specific secrets (uppercase server name)
  local server_name_upper=$(echo "$server_name" | tr '[:lower:]' '[:upper:]')
  local rcon_var="${server_name_upper}_RCON"
  local hostname_var="${server_name_upper}_HOSTNAME"
    
  local rcon_password="${!rcon_var:-changeme}"
  local hostname="${!hostname_var:-changeme}"
    
  _debug "${FUNCNAME[0]}" "Updating $server_cfg..."
  
  # Escape special characters for sed
  local hostname_escaped=$(escape_for_sed "$hostname")
  local sv_password_escaped=$(escape_for_sed "$SV_PASSWORD")
  local rcon_password_escaped=$(escape_for_sed "$rcon_password")
  local demostf_apikey_escaped=$(escape_for_sed "$DEMOSTF_APIKEY")
  local logstf_apikey_escaped=$(escape_for_sed "$LOGSTF_APIKEY")
    
  # Use sed with | delimiter and escaped values
  sed -i "s|^hostname[[:space:]]*\".*\"|hostname                       \"$hostname_escaped\"|" "$server_cfg"
  sed -i "s|^sv_password[[:space:]]*\".*\"|sv_password                    \"$sv_password_escaped\"|" "$server_cfg"
  sed -i "s|^rcon_password[[:space:]]*\".*\"|rcon_password                  \"$rcon_password_escaped\"|" "$server_cfg"
  sed -i "s|^sm_demostf_apikey[[:space:]]*\".*\"|sm_demostf_apikey              \"$demostf_apikey_escaped\"|" "$server_cfg"
  sed -i "s|^logstf_apikey[[:space:]]*\".*\"|logstf_apikey                  \"$logstf_apikey_escaped\"|" "$server_cfg"

  _debug "${FUNCNAME[0]}" "✓ Updated secrets in server.cfg"
    
  # Return rcon password for .rconrc update
  echo "$rcon_password"
}

# Function to update .rconrc
update_rconrc() {
  local server_name=$1
  local rcon_password=$2
  local hostname=$3
  local port=$4
  
  # Escape the password for sed
  local rcon_password_escaped=$(escape_for_sed "$rcon_password")
    
  # Check if section exists, if not create it
  if ! grep -q "^\[$server_name\]" "$RCONRC" 2>/dev/null; then
    _debug "${FUNCNAME[0]}" "Creating new rconrc entry for $server_name..."
    cat >> "$RCONRC" << EOF

[$server_name]
hostname = $hostname
port = $port
password = $rcon_password
EOF
  else
    # Update existing entry
    _debug "${FUNCNAME[0]}" "Updating rconrc entry for $server_name..."
    sed -i "/^\[$server_name\]/,/^\[/ s|^password = .*|password = $rcon_password_escaped|" "$RCONRC"
  fi
}

# Function to notify server via rcon
notify_server() {
  local server_name=$1
    
  if command -v rcon &> /dev/null; then
    _debug "${FUNCNAME[0]}" "Notifying server via rcon..."
    rcon -s "$server_name" say "Server configs updated, change map for them to take effect" || {
    _error "${FUNCNAME[0]}" "⚠ Warning: Failed to send rcon notification to $server_name"
    }
  else
    _error "${FUNCNAME[0]}" "⚠ Warning: rcon command not found, skipping notification"
  fi
}

main() {
  _info "${FUNCNAME[0]}" "Starting deployment..."
  _debug "${FUNCNAME[0]}" "Source: ${TF_SOURCE}"
  
  # Read server count
  server_count=$(jq '. | length' "$CONFIG_FILE")
  _debug "${FUNCNAME[0]}" "Found $server_count server(s) in config"
  
  SHARED_RCON_PASSWORD=""
  
  # Loop through each server in config.json
  for i in $(seq 0 $((server_count - 1))); do
    server_name=$(jq -r ".[$i].name" "$CONFIG_FILE")
    server_path=$(jq -r ".[$i].path" "$CONFIG_FILE")
      
    _info "${FUNCNAME[0]}" "[$((i + 1))/$server_count] Deploying to: $server_name"
    _info "${FUNCNAME[0]}" "Path: $server_path"
      
    # Check if server path exists
    if [ ! -d "$server_path" ]; then
      _error "${FUNCNAME[0]}" "⚠ Warning: Server path does not exist, skipping"
      continue
    fi
      
    # Rsync tf directory
    _debug "${FUNCNAME[0]}" "Syncing tf directory..."
    rsync -av "$TF_SOURCE/" "$server_path/tf/"
    _debug "${FUNCNAME[0]}" "✓ Files synced"
      
    # Update server.cfg with secrets
    rcon_password=$(update_server_cfg "$server_name" "$server_path")
    SHARED_RCON_PASSWORD="$rcon_password"
      
    # Just doing a simple increment for now, can also add this to config.json
    port=$((27015 + i))
      
    # Update .rconrc
    update_rconrc "$server_name" "$rcon_password" "tf2.lumabyte.io" "$port"
    _debug "${FUNCNAME[0]}" "✓ Updated .rconrc"
      
    # Notify server
    notify_server "$server_name"
      
    _info "${FUNCNAME[0]}" "✓ Deployment complete for $server_name"
  done

  _info "${FUNCNAME[0]}" "All deployments done!"
}

main "${@}"
