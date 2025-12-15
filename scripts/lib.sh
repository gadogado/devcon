#!/usr/bin/env bash
# Devcon Library - Configuration and utility functions
# Source this file in your scripts: source "$(dirname "$0")/devcon-lib.sh"

set -euo pipefail

# ============================================================================
# ============================================================================
# Configuration Paths
# ============================================================================

# Project-level config (.devcontainer/devcon.yaml)
get_project_config_path() {
  local current_dir="${1:-$(pwd)}"

  # Check current directory
  if [ -f "$current_dir/.devcontainer/devcon.yaml" ]; then
    echo "$current_dir/.devcontainer/devcon.yaml"
    return 0
  fi

  # Check if we're in a git repo and look at root
  if git rev-parse --git-dir >/dev/null 2>&1; then
    local git_root
    git_root=$(git rev-parse --show-toplevel)
    if [ -f "$git_root/.devcontainer/devcon.yaml" ]; then
      echo "$git_root/.devcontainer/devcon.yaml"
      return 0
    fi
  fi

  return 1
}

# User-level config (~/.devcon/config.yaml)
get_user_config_path() {
  local user_config="$HOME/.devcon/config.yaml"
  if [ -f "$user_config" ]; then
    echo "$user_config"
    return 0
  fi
  return 1
}

# ============================================================================
# Configuration Reading Functions
# ============================================================================

# Read config value with fallback chain: CLI flag → project config → user config → default
# Usage: get_config "key.path" "default_value"
get_config() {
  local key="$1"
  local default="${2:-}"
  local value=""

  # Check if yq is available
  if ! command -v yq >/dev/null 2>&1; then
    echo "$default"
    return 0
  fi

  # Try project config first
  local project_config
  if project_config=$(get_project_config_path); then
    value=$(yq eval ".$key" "$project_config" 2>/dev/null || echo "null")
    if [ "$value" != "null" ] && [ -n "$value" ]; then
      echo "$value"
      return 0
    fi
  fi

  # Try user config
  local user_config
  if user_config=$(get_user_config_path); then
    value=$(yq eval ".$key" "$user_config" 2>/dev/null || echo "null")
    if [ "$value" != "null" ] && [ -n "$value" ]; then
      echo "$value"
      return 0
    fi
  fi

  # Return default
  echo "$default"
}

# Read config as boolean (true/false)
# Usage: get_config_bool "key.path" "true"
get_config_bool() {
  local key="$1"
  local default="${2:-false}"
  local value

  value=$(get_config "$key" "$default")

  # Convert to lowercase
  value=$(echo "$value" | tr '[:upper:]' '[:lower:]')

  # Return true/false
  case "$value" in
    true|yes|1|on)
      echo "true"
      ;;
    *)
      echo "false"
      ;;
  esac
}

# Read config as array
# Usage: mapfile -t array < <(get_config_array "key.path")
get_config_array() {
  local key="$1"

  # Check if yq is available
  if ! command -v yq >/dev/null 2>&1; then
    return 1
  fi

  # Try project config first
  local project_config
  if project_config=$(get_project_config_path); then
    local result
    result=$(yq eval ".$key[]" "$project_config" 2>/dev/null || echo "")
    if [ -n "$result" ]; then
      echo "$result"
      return 0
    fi
  fi

  # Try user config
  local user_config
  if user_config=$(get_user_config_path); then
    local result
    result=$(yq eval ".$key[]" "$user_config" 2>/dev/null || echo "")
    if [ -n "$result" ]; then
      echo "$result"
      return 0
    fi
  fi

  return 1
}

# ============================================================================
# Default Configuration Values
# ============================================================================

# Get default values when no config exists
get_default_app_port() {
  echo "3000"
}

get_default_admin_port() {
  echo "5555"
}

get_default_container_prefix() {
  echo "devcontainer"
}

get_default_worktree_base() {
  echo "$HOME/devcon-worktrees"
}

get_default_shell() {
  echo "zsh"
}

get_default_editor() {
  echo "vim"
}

# ============================================================================
# Doppler Helpers
# ============================================================================

get_doppler_enabled() {
  # Check env var first (set by Node.js config loader)
  if [ -n "${DEVCON_DOPPLER_ENABLED:-}" ]; then
    echo "$DEVCON_DOPPLER_ENABLED"
    return 0
  fi
  get_config_bool "doppler.enabled" "false"
}


get_doppler_token_env() {
  # Check env var first (set by Node.js config loader)
  if [ -n "${DEVCON_DOPPLER_TOKEN_ENV:-}" ]; then
    echo "$DEVCON_DOPPLER_TOKEN_ENV"
    return 0
  fi
  get_config "doppler.token_env" "DOPPLER_TOKEN"
}

get_doppler_config_dir() {
  echo "$HOME/.doppler"
}

check_doppler_authenticated() {
  local config_dir
  config_dir=$(get_doppler_config_dir)

  # Check if Doppler config exists (user has run 'doppler login')
  if [ -f "$config_dir/.doppler.yaml" ]; then
    return 0
  fi
  return 1
}

# ============================================================================
# Convenience Wrappers (Common Config Values)
# ============================================================================

# Port configuration
get_app_port() {
  get_config "ports.app" "$(get_default_app_port)"
}

get_admin_port() {
  get_config "ports.admin" "$(get_default_admin_port)"
}

get_port_allocation_strategy() {
  # Check env var first (set by Node.js config loader)
  if [ -n "${DEVCON_PORT_ALLOCATION_STRATEGY:-}" ]; then
    echo "$DEVCON_PORT_ALLOCATION_STRATEGY"
    return 0
  fi
  get_config "ports.allocation_strategy" "dynamic"
}

# Lightweight YAML parser for the ports block when yq isn't installed.
# Extracts entries under `ports:` until the next top-level key.
parse_ports_without_yq() {
  local config_file="$1"
  if [ ! -f "$config_file" ]; then
    return 1
  fi

  local output
  output=$(awk '
    function ltrim(s) { sub(/^[ \t\r\n]+/, "", s); return s }
    function rtrim(s) { sub(/[ \t\r\n]+$/, "", s); return s }
    function trim(s) { return rtrim(ltrim(s)) }
    BEGIN { in_ports=0 }
    {
      line=$0
      if (in_ports == 0) {
        if (line ~ /^[[:space:]]*ports:[[:space:]]*$/) {
          in_ports=1
        }
        next
      }

      if (line ~ /^[[:space:]]*$/) {
        next
      }

      if (line ~ /^[[:space:]]*#/) {
        next
      }

      if (line !~ /^[[:space:]]+/) {
        exit
      }

      entry=line
      sub(/^[[:space:]]+/, "", entry)
      if (entry !~ /:/) {
        next
      }

      key=entry
      sub(/:.*/, "", key)
      value=entry
      sub(/^[^:]+:[[:space:]]*/, "", value)
      sub(/[[:space:]]*#.*$/, "", value)

      key=trim(key)
      value=trim(value)

      if (key == "" || key == "allocation_strategy" || value == "") {
        next
      }

      print key ":" value
    }
  ' "$config_file")

  if [ -n "$output" ]; then
    printf "%s\n" "$output"
    return 0
  fi

  return 1
}

# Get all port mappings as "name:port" pairs
# Usage: mapfile -t port_mappings < <(get_all_port_mappings)
# Output: name:port (one per line)
get_all_port_mappings() {
  local project_config
  local user_config
  local result

  if command -v yq >/dev/null 2>&1; then
    if project_config=$(get_project_config_path 2>/dev/null); then
      result=$(yq eval '.ports | to_entries | .[] | select(.key != "allocation_strategy") | .key + ":" + (.value | tostring)' "$project_config" 2>/dev/null || echo "")
      if [ -n "$result" ]; then
        printf "%s\n" "$result"
        return 0
      fi
    fi

    if user_config=$(get_user_config_path 2>/dev/null); then
      result=$(yq eval '.ports | to_entries | .[] | select(.key != "allocation_strategy") | .key + ":" + (.value | tostring)' "$user_config" 2>/dev/null || echo "")
      if [ -n "$result" ]; then
        printf "%s\n" "$result"
        return 0
      fi
    fi
  else
    if project_config=$(get_project_config_path 2>/dev/null); then
      if result=$(parse_ports_without_yq "$project_config"); then
        printf "%s\n" "$result"
        return 0
      fi
    fi

    if user_config=$(get_user_config_path 2>/dev/null); then
      if result=$(parse_ports_without_yq "$user_config"); then
        printf "%s\n" "$result"
        return 0
      fi
    fi
  fi

  # Fallback to defaults
  echo "app:$(get_default_app_port)"
  echo "admin:$(get_default_admin_port)"
}

# Get all port numbers (without names)
# Usage: mapfile -t ports < <(get_all_ports)
get_all_ports() {
  get_all_port_mappings | cut -d':' -f2
}

# Container configuration
get_container_prefix() {
  # Check env var first (set by Node.js config loader)
  if [ -n "${DEVCON_CONTAINER_PREFIX:-}" ]; then
    echo "$DEVCON_CONTAINER_PREFIX"
    return 0
  fi
  get_config "container.prefix" "$(get_default_container_prefix)"
}

get_container_use_repo_name() {
  # Check env var first (set by Node.js config loader)
  if [ -n "${DEVCON_CONTAINER_USE_REPO_NAME:-}" ]; then
    echo "$DEVCON_CONTAINER_USE_REPO_NAME"
    return 0
  fi
  get_config_bool "container.use_repo_name" "true"
}

# Workflow configuration
get_worktree_base() {
  # Check env var first (set by Node.js config loader)
  if [ -n "${DEVCON_WORKFLOW_WORKTREE_BASE:-}" ]; then
    local base="$DEVCON_WORKFLOW_WORKTREE_BASE"
    echo "${base/#\~/$HOME}"
    return 0
  fi
  local base
  base=$(get_config "workflow.worktree_base" "$(get_default_worktree_base)")
  # Expand tilde
  echo "${base/#\~/$HOME}"
}

get_auto_cleanup() {
  # Check env var first (set by Node.js config loader)
  if [ -n "${DEVCON_WORKFLOW_AUTO_CLEANUP:-}" ]; then
    echo "$DEVCON_WORKFLOW_AUTO_CLEANUP"
    return 0
  fi
  get_config_bool "workflow.auto_cleanup" "true"
}

get_default_shell_config() {
  # Check env var first (set by Node.js config loader)
  if [ -n "${DEVCON_WORKFLOW_SHELL:-}" ]; then
    echo "$DEVCON_WORKFLOW_SHELL"
    return 0
  fi
  get_config "workflow.shell" "$(get_default_shell)"
}

get_doppler_project() {
  # Check env var first (set by Node.js config loader)
  if [ -n "${DEVCON_DOPPLER_PROJECT:-}" ]; then
    echo "$DEVCON_DOPPLER_PROJECT"
    return 0
  fi
  get_config "doppler.project" ""
}

get_doppler_config() {
  # Check env var first (set by Node.js config loader)
  if [ -n "${DEVCON_DOPPLER_CONFIG:-}" ]; then
    echo "$DEVCON_DOPPLER_CONFIG"
    return 0
  fi
  get_config "doppler.config" "dev"
}

# Network security configuration
get_network_security_enabled() {
  # Check env var first (set by Node.js config loader)
  if [ -n "${DEVCON_NETWORK_SECURITY_ENABLED:-}" ]; then
    echo "$DEVCON_NETWORK_SECURITY_ENABLED"
    return 0
  fi
  get_config_bool "network.security.enabled" "false"
}

get_network_log_blocked() {
  # Check env var first (set by Node.js config loader)
  if [ -n "${DEVCON_NETWORK_LOG_BLOCKED:-}" ]; then
    echo "$DEVCON_NETWORK_LOG_BLOCKED"
    return 0
  fi
  get_config_bool "network.security.log_blocked" "true"
}

get_network_default_policy() {
  # Check env var first (set by Node.js config loader)
  if [ -n "${DEVCON_NETWORK_DEFAULT_POLICY:-}" ]; then
    echo "$DEVCON_NETWORK_DEFAULT_POLICY"
    return 0
  fi
  get_config "network.security.default_policy" "DROP"
}

# Editor configuration
get_editor() {
  get_config "editor.default" "$(get_default_editor)"
}

# ============================================================================
# Utility Functions
# ============================================================================

# Check if config exists
has_project_config() {
  get_project_config_path >/dev/null 2>&1
}

has_user_config() {
  get_user_config_path >/dev/null 2>&1
}

# ============================================================================
# Export Functions (if needed)
# ============================================================================

# Uncomment to make functions available to subshells
# export -f get_config get_config_bool get_config_array
# export -f get_app_port get_admin_port get_container_prefix
# export -f get_worktree_base get_auto_cleanup
