#!/bin/bash
set -e

# Load configuration library
# Resolve symlinks to find actual script location (for npm link)
SCRIPT_PATH="${BASH_SOURCE[0]}"
while [ -L "$SCRIPT_PATH" ]; do
  SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"
  SCRIPT_PATH="$(readlink "$SCRIPT_PATH")"
  [[ $SCRIPT_PATH != /* ]] && SCRIPT_PATH="$SCRIPT_DIR/$SCRIPT_PATH"
done
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"
LIB_SCRIPT="$SCRIPT_DIR/lib.sh"

if [ ! -f "$LIB_SCRIPT" ]; then
  echo "ERROR: Cannot find lib.sh"
  exit 1
fi

source "$LIB_SCRIPT"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Default values
CONTAINER_NAME=""
AUTO_CLEANUP=""  # Will be set from config if not provided via CLI
DEVCONTAINER_CONFIG=""
NO_CACHE=false
PORT_MAPPINGS=()
TEMP_DEVCON_DIR=""
WORKSPACE_PATH="$(pwd -P 2>/dev/null || pwd)"
WORKSPACE_LABEL="devcontainer.local_folder=${WORKSPACE_PATH}"

# Function to print colored output
info() { echo -e "${GREEN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Function to get worktree info
get_worktree_info() {
  local branch_name=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
  local worktree_dir=$(basename "$(pwd)")
  echo "${worktree_dir}_${branch_name}"
}

# Ensure container name components only use Docker-safe characters
sanitize_container_component() {
  local input="$1"
  local fallback="${2:-segment}"
  local sanitized
  sanitized=$(printf '%s' "$input" | tr -c '[:alnum:]_.-' '-')
  sanitized=$(printf '%s' "$sanitized" | sed -e 's/-\{2,\}/-/g' -e 's/^[^[:alnum:]]*//' -e 's/-$//')
  if [ -z "$sanitized" ]; then
    sanitized="$fallback"
  fi
  echo "$sanitized"
}

# Validate the final container name before handing it to Docker
validate_container_name() {
  local name="$1"
  if [[ -z "$name" ]]; then
    error "Container name cannot be empty"
    exit 1
  fi

  if [[ ! "$name" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]*$ ]]; then
    error "Invalid container name: $name"
    error "Container names must match the pattern [a-zA-Z0-9][a-zA-Z0-9_.-]*"
    exit 1
  fi
}

# Function to find devcontainer config
find_devcontainer_config() {
  # First check current directory
  if [ -f ".devcontainer/devcontainer.json" ]; then
    echo "$(pwd)/.devcontainer"
    return 0
  fi

  # If we're in a worktree, check the main repo
  local main_worktree=$(git worktree list --porcelain | grep "worktree" | head -1 | cut -d' ' -f2)
  if [ -n "$main_worktree" ] && [ -f "$main_worktree/.devcontainer/devcontainer.json" ]; then
    echo "$main_worktree/.devcontainer"
    return 0
  fi

  return 1
}

# Function to find an available port starting from a base port
find_available_port() {
  local base_port=$1
  local port=$base_port
  while lsof -Pi :$port -sTCP:LISTEN -t >/dev/null 2>&1; do
    port=$((port + 1))
  done
  echo $port
}

is_port_in_use() {
  local port=$1
  lsof -Pi :$port -sTCP:LISTEN -t >/dev/null 2>&1
}

# Function to load port mappings without relying on mapfile (works on older bash)
load_port_mappings() {
  PORT_MAPPINGS=()
  while IFS= read -r mapping; do
    if [ -n "$mapping" ]; then
      PORT_MAPPINGS+=("$mapping")
    fi
  done < <(get_all_port_mappings)
}

# Prepare a temporary devcontainer config with additional runArgs (for container name/ports)
# and optional Doppler removal
prepare_devcontainer_config() {
  local source_dir="$1"
  shift
  local skip_doppler="$1"
  shift
  local extra_run_args=("$@")

  local source_config="$source_dir/devcontainer.json"

  if [ ! -f "$source_config" ]; then
    error "devcontainer.json not found in $source_dir"
    exit 1
  fi

  if [ "${#extra_run_args[@]}" -eq 0 ] && [ "$skip_doppler" != "true" ]; then
    echo "$source_dir"
    return 0
  fi

  local parent_dir
  parent_dir=$(dirname "$source_dir")
  TEMP_DEVCON_DIR=$(mktemp -d "$parent_dir/.devcontainer-temp.XXXXXX")
  cp -R "$source_dir/." "$TEMP_DEVCON_DIR/"
  local target_config="$TEMP_DEVCON_DIR/devcontainer.json"

  node - "$target_config" "$skip_doppler" "${extra_run_args[@]}" <<'NODE'
const fs = require('fs');
const targetPath = process.argv[2];
const skipDoppler = process.argv[3] === 'true';
const extraArgs = process.argv.slice(4);

const stripJsonComments = (input) => {
  let insideString = false;
  let insideSingleLineComment = false;
  let insideMultiLineComment = false;
  let result = '';
  let escape = false;

  for (let i = 0; i < input.length; i++) {
    const current = input[i];
    const next = input[i + 1];

    if (insideSingleLineComment) {
      if (current === '\n') {
        insideSingleLineComment = false;
        result += current;
      }
      continue;
    }

    if (insideMultiLineComment) {
      if (current === '*' && next === '/') {
        insideMultiLineComment = false;
        i++;
      }
      continue;
    }

    if (insideString) {
      result += current;
      if (current === '"' && !escape) {
        insideString = false;
      }
      escape = current === '\\' && !escape;
      if (current !== '\\') {
        escape = false;
      }
      continue;
    }

    if (current === '"') {
      insideString = true;
      result += current;
      escape = false;
      continue;
    }

    if (current === '/' && next === '/') {
      insideSingleLineComment = true;
      i++;
      continue;
    }

    if (current === '/' && next === '*') {
      insideMultiLineComment = true;
      i++;
      continue;
    }

    result += current;
  }

  return result;
};

const removeTrailingCommas = (input) => {
  let result = '';
  let insideString = false;
  let escape = false;

  for (let i = 0; i < input.length; i++) {
    const current = input[i];

    if (insideString) {
      result += current;
      if (current === '"' && !escape) {
        insideString = false;
      }
      escape = current === '\\' && !escape;
      if (current !== '\\') {
        escape = false;
      }
      continue;
    }

    if (current === '"') {
      insideString = true;
      result += current;
      escape = false;
      continue;
    }

    if (current === ',') {
      let j = i + 1;
      while (j < input.length && /\s/.test(input[j])) {
        j++;
      }
      if (j < input.length && (input[j] === '}' || input[j] === ']')) {
        continue;
      }
    }

    result += current;
  }

  return result;
};

const readConfig = () => {
  const raw = fs.readFileSync(targetPath, 'utf-8').replace(/^\uFEFF/, '');
  const sanitized = removeTrailingCommas(stripJsonComments(raw));
  try {
    return JSON.parse(sanitized);
  } catch (error) {
    console.error(`Failed to parse devcontainer config: ${sourcePath}`);
    throw error;
  }
};

const config = readConfig();

if (extraArgs.length) {
  const existing = Array.isArray(config.runArgs) ? config.runArgs : [];
  config.runArgs = existing.concat(extraArgs);
}

config.containerEnv = config.containerEnv || {};

// Set DOPPLER_ENABLED based on config
config.containerEnv.DOPPLER_ENABLED = skipDoppler ? "false" : "true";

// Inject DOPPLER_PROJECT and DOPPLER_CONFIG from devcon.yaml if set
const dopplerProject = process.env.DEVCON_DOPPLER_PROJECT;
const dopplerConfig = process.env.DEVCON_DOPPLER_CONFIG;
if (dopplerProject) {
  config.containerEnv.DOPPLER_PROJECT = dopplerProject;
}
if (dopplerConfig) {
  config.containerEnv.DOPPLER_CONFIG = dopplerConfig;
}

// Read token from configured host env var (default: DOPPLER_TOKEN)
const tokenEnvVar = process.env.DEVCON_DOPPLER_TOKEN_ENV || 'DOPPLER_TOKEN';
const tokenValue = process.env[tokenEnvVar];
if (tokenValue) {
  config.containerEnv.DOPPLER_TOKEN = tokenValue;
}

// Build mounts from DEVCON_MOUNTS config
const mountsJson = process.env.DEVCON_MOUNTS;
if (mountsJson) {
  const mountsConfig = JSON.parse(mountsJson);
  const mounts = [];

  // Always include bash history volume
  mounts.push('source=claude-code-bashhistory-${devcontainerId},target=/commandhistory,type=volume');

  // Shorthand mounts map: key -> [hostPath, containerPath]
  const shorthandMounts = {
    claude: ['.claude', '/home/node/.claude'],
    codex: ['.codex', '/home/node/.codex'],
    cursor: ['.cursor', '/home/node/.cursor'],
    azure: ['.azure', '/home/node/.azure'],
    aws: ['.aws', '/home/node/.aws'],
    gcloud: ['.config/gcloud', '/home/node/.config/gcloud'],
    ssh: ['.ssh', '/home/node/.ssh'],
  };

  // Add shorthand mounts
  for (const [key, [hostPath, containerPath]] of Object.entries(shorthandMounts)) {
    if (mountsConfig[key] === true) {
      mounts.push(`source=\${localEnv:HOME}/${hostPath},target=${containerPath},type=bind`);
    }
  }

  // Add custom mounts
  if (Array.isArray(mountsConfig.custom)) {
    for (const custom of mountsConfig.custom) {
      if (custom.source && custom.target) {
        // Expand ~ to ${localEnv:HOME}
        const source = custom.source.replace(/^~\//, '${localEnv:HOME}/');
        mounts.push(`source=${source},target=${custom.target},type=bind`);
      }
    }
  }

  config.mounts = mounts;
}

fs.writeFileSync(targetPath, JSON.stringify(config, null, 2));
NODE

  echo "$TEMP_DEVCON_DIR"
}

# Cleanup hook for temporary config directories and auto-clean containers
get_workspace_containers() {
  docker ps -a --filter "label=${WORKSPACE_LABEL}" --format '{{.ID}} {{.Names}}' 2>/dev/null || true
}

remove_workspace_containers() {
  local reason="${1:-Removing devcontainers for this workspace}"
  local containers=()
  while IFS= read -r entry; do
    [ -n "$entry" ] && containers+=("$entry")
  done < <(get_workspace_containers)

  if [ ${#containers[@]} -eq 0 ]; then
    return 0
  fi

  info "$reason"
  for entry in "${containers[@]}"; do
    local id="${entry%% *}"
    local name="${entry#* }"
    name="${name:-$id}"
    info "  - Stopping $name"
    docker stop "$id" >/dev/null 2>&1 || true
    info "  - Removing $name"
    docker rm "$id" >/dev/null 2>&1 || true
  done
}

cleanup_resources() {
  if [ "$AUTO_CLEANUP" = true ]; then
    remove_workspace_containers "Auto-cleanup: removing devcontainers for this workspace"
  fi

  if [ -n "$TEMP_DEVCON_DIR" ] && [ -d "$TEMP_DEVCON_DIR" ]; then
    rm -rf "$TEMP_DEVCON_DIR"
  fi
}

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --name)
      CONTAINER_NAME="$2"
      shift 2
      ;;
    --no-cleanup)
      AUTO_CLEANUP=false
      shift
      ;;
    --no-cache)
      NO_CACHE=true
      shift
      ;;
    --config)
      DEVCONTAINER_CONFIG="$2"
      shift 2
      ;;
    --help)
      echo "Usage: devcon up [OPTIONS]"
      echo ""
      echo "Start/create devcontainer in current directory"
      echo ""
      echo "Options:"
      echo "  --name NAME        Custom container name (auto-generated if not provided)"
      echo "  --no-cleanup       Disable auto-cleanup after the container exits"
      echo "  --no-cache         Rebuild the Docker image without using cache"
      echo "  --config PATH      Path to devcontainer config directory"
      echo "  --help             Show this help message"
      echo ""
      echo "Examples:"
      echo "  devcon up                                    # Auto-assigns ports and starts container"
      echo "  devcon up --name preview                     # Custom container name"
      echo "  devcon up --no-cleanup                       # Keep container running after exit"
      echo "  devcon up --no-cache                         # Force rebuild without Docker cache"
      echo ""
      echo "Configuration:"
      echo "  Project config: .devcontainer/devcon.yaml"
      echo "  User config:    ~/.devcon/config.yaml"
      exit 0
      ;;
    *)
      error "Unknown option: $1"
      echo "Use --help for usage information"
      exit 1
      ;;
  esac
done

# Set AUTO_CLEANUP from config if not provided via CLI
if [ -z "$AUTO_CLEANUP" ]; then
  if [ "$(get_auto_cleanup)" = "true" ]; then
    AUTO_CLEANUP=true
  else
    AUTO_CLEANUP=false
  fi
fi

trap cleanup_resources EXIT

# Get port configuration
APP_PORT=$(get_app_port)
ADMIN_PORT=$(get_admin_port)
CONTAINER_PREFIX=$(sanitize_container_component "$(get_container_prefix)" "devcontainer")
SHELL_CMD=$(get_default_shell_config)

# Find devcontainer config
if [ -z "$DEVCONTAINER_CONFIG" ]; then
  DEVCONTAINER_CONFIG=$(find_devcontainer_config)
  if [ -z "$DEVCONTAINER_CONFIG" ]; then
    error "Could not find .devcontainer/devcontainer.json"
    error "Please ensure you're in a repo with devcontainer configuration"
    exit 1
  fi
fi

info "Using devcontainer config from: $DEVCONTAINER_CONFIG"

DOPPLER_ENABLED=$(get_doppler_enabled)
DOPPLER_TOKEN_ENV=$(get_doppler_token_env)
DOPPLER_DISABLED="false"
if [ "$DOPPLER_ENABLED" != "true" ]; then
  DOPPLER_DISABLED="true"
elif [ -z "${!DOPPLER_TOKEN_ENV:-}" ]; then
  warn "Doppler enabled but ${DOPPLER_TOKEN_ENV} not set on host"
  warn "Get a personal token at https://dashboard.doppler.com"
  warn "Then: export ${DOPPLER_TOKEN_ENV}=dp.pt.xxx"
fi

# Generate container name (auto if not provided)
if [ -z "$CONTAINER_NAME" ]; then
  if git rev-parse --git-dir >/dev/null 2>&1; then
    WORKTREE_INFO=$(get_worktree_info)
  else
    WORKTREE_INFO=$(basename "$(pwd)")
  fi
  WORKTREE_INFO=$(sanitize_container_component "$WORKTREE_INFO" "workspace")
  UUID=$(uuidgen | cut -d'-' -f1 | tr '[:upper:]' '[:lower:]')
  CONTAINER_NAME="${CONTAINER_PREFIX}-${WORKTREE_INFO}-${UUID}"
  info "Generated container name: $CONTAINER_NAME"
else
  info "Using custom container name: $CONTAINER_NAME"
fi

validate_container_name "$CONTAINER_NAME"

if [ "$AUTO_CLEANUP" = true ]; then
  info "Auto-cleanup enabled - container will be removed on exit"
fi

# Remove existing container with same name if it exists
EXISTING_LABELED_CONTAINERS=$(get_workspace_containers)
if [ -n "$EXISTING_LABELED_CONTAINERS" ]; then
  remove_workspace_containers "Removing existing devcontainers for this workspace"
elif docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
  warn "Container $CONTAINER_NAME already exists, removing..."
  docker stop "$CONTAINER_NAME" >/dev/null 2>&1 || true
  docker rm "$CONTAINER_NAME" >/dev/null 2>&1 || true
fi

# Get all port mappings from config
load_port_mappings

# Find available ports for each configured port
PORT_MAPPING_RESULTS=()
PORT_STRATEGY=$(get_port_allocation_strategy | tr '[:upper:]' '[:lower:]')

if [ "$PORT_STRATEGY" = "static" ]; then
  info "Using static host ports from .devcontainer/devcon.yaml"
else
  info "Auto-assigning available host ports:"
fi

CONFLICTING_PORTS=()
for mapping in "${PORT_MAPPINGS[@]}"; do
  name="${mapping%%:*}"
  port="${mapping##*:}"

  if [ "$PORT_STRATEGY" = "static" ]; then
    if is_port_in_use "$port"; then
      CONFLICTING_PORTS+=("${name}:${port}")
      continue
    fi
    host_port="$port"
    PORT_MAPPING_RESULTS+=("${name}:${host_port}:${port}")
    info "  ${name}: http://localhost:${host_port}"
  else
    host_port=$(find_available_port "$port")
    PORT_MAPPING_RESULTS+=("${name}:${host_port}:${port}")
    if [ "$host_port" -ne "$port" ]; then
      info "  ${name}: http://localhost:${host_port} (container:${port})"
    else
      info "  ${name}: http://localhost:${host_port}"
    fi
  fi
done

if [ ${#CONFLICTING_PORTS[@]} -gt 0 ]; then
  error "Cannot start container because these static ports are busy:"
  for entry in "${CONFLICTING_PORTS[@]}"; do
    name="${entry%%:*}"
    port="${entry##*:}"
    echo "  - ${name}: host port ${port}"
  done
  echo ""
  echo "Free the ports, change '.devcontainer/devcon.yaml', or switch to dynamic allocation by setting"
  echo "`ports.allocation_strategy: dynamic`."
  exit 1
fi

# Prepare additional docker run arguments (name + dynamic ports)
EXTRA_RUN_ARGS=("--name=${CONTAINER_NAME}" "--label=${WORKSPACE_LABEL}")
for entry in "${PORT_MAPPING_RESULTS[@]}"; do
  name="${entry%%:*}"
  rest="${entry#*:}"
  host_port="${rest%%:*}"
  container_port="${rest##*:}"
  EXTRA_RUN_ARGS+=("-p")
  EXTRA_RUN_ARGS+=("${host_port}:${container_port}")
done

EFFECTIVE_DEVCON_DIR=$(prepare_devcontainer_config "$DEVCONTAINER_CONFIG" "$DOPPLER_DISABLED" "${EXTRA_RUN_ARGS[@]}")
CONFIG_TO_USE="${EFFECTIVE_DEVCON_DIR:-$DEVCONTAINER_CONFIG}/devcontainer.json"

# Create devcontainer with dynamic port mappings
info "Creating devcontainer..."
DEVCONTAINER_UP_ARGS=(
  --workspace-folder .
  --config "$CONFIG_TO_USE"
  --id-label "$WORKSPACE_LABEL"
  --remove-existing-container
)
if [ "$NO_CACHE" = true ]; then
  info "Building without cache..."
  DEVCONTAINER_UP_ARGS+=(--build-no-cache)
fi
devcontainer up "${DEVCONTAINER_UP_ARGS[@]}"

# Display all port mappings
echo ""
info "Container ready! Access your services at:"
for entry in "${PORT_MAPPING_RESULTS[@]}"; do
  name="${entry%%:*}"
  rest="${entry#*:}"
  host_port="${rest%%:*}"
  info "  ${name}: http://localhost:${host_port}"
done
echo ""

# Exec into the container
info "Executing ${SHELL_CMD} in container..."
echo ""
devcontainer exec \
  --workspace-folder . \
  --config "$CONFIG_TO_USE" \
  --id-label "$WORKSPACE_LABEL" \
  -- "$SHELL_CMD"

# Note: cleanup trap will run automatically if AUTO_CLEANUP=true
