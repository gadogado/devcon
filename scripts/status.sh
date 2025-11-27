#!/bin/bash

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

# If not found in same directory, try PATH
if [ ! -f "$LIB_SCRIPT" ]; then
  if command -v lib.sh >/dev/null 2>&1; then
    LIB_SCRIPT="lib.sh"
  fi
fi

# Source library if available (optional for status script)
if [ -n "$LIB_SCRIPT" ] && [ -f "$LIB_SCRIPT" ]; then
  source "$LIB_SCRIPT"
fi

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --help)
      echo "Usage: devcon status [OPTIONS]"
      echo ""
      echo "Display status of all devcontainers and their workspace mappings."
      echo ""
      echo "Options:"
      echo "  --help           Show this help message"
      echo ""
      echo "Configuration:"
      echo "  Project config: .devcontainer/devcon.yaml"
      echo "  User config:    ~/.devcon/config.yaml"
      exit 0
      ;;
    *)
      echo "Unknown option: $1"
      echo "Use --help for usage information"
      exit 1
      ;;
  esac
  shift
done

# Colors
BLUE='\033[0;34m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
GRAY='\033[0;90m'
NC='\033[0m'

# Track port mappings even on older macOS bash (no associative arrays)
SUPPORTS_ASSOC_ARRAYS=0
if [ "${BASH_VERSINFO:-0}" -ge 4 ]; then
  SUPPORTS_ASSOC_ARRAYS=1
fi

if [ "$SUPPORTS_ASSOC_ARRAYS" -eq 1 ]; then
  declare -A PORT_NAMES  # port_number -> custom_name
else
  PORT_NAME_KEYS=()
  PORT_NAME_VALUES=()
fi

set_port_name() {
  local port="$1"
  local name="$2"

  if [ "$SUPPORTS_ASSOC_ARRAYS" -eq 1 ]; then
    PORT_NAMES["$port"]="$name"
    return
  fi

  local idx
  for idx in "${!PORT_NAME_KEYS[@]}"; do
    if [ "${PORT_NAME_KEYS[$idx]}" = "$port" ]; then
      PORT_NAME_VALUES[$idx]="$name"
      return
    fi
  done

  PORT_NAME_KEYS+=("$port")
  PORT_NAME_VALUES+=("$name")
}

get_port_name() {
  local port="$1"

  if [ "$SUPPORTS_ASSOC_ARRAYS" -eq 1 ]; then
    if [ -n "${PORT_NAMES[$port]:-}" ]; then
      echo "${PORT_NAMES[$port]}"
      return 0
    fi
    return 1
  fi

  local idx
  for idx in "${!PORT_NAME_KEYS[@]}"; do
    if [ "${PORT_NAME_KEYS[$idx]}" = "$port" ]; then
      echo "${PORT_NAME_VALUES[$idx]}"
      return 0
    fi
  done

  return 1
}

# Get all port mappings if library is loaded
if command -v get_all_port_mappings >/dev/null 2>&1; then
  while IFS= read -r mapping; do
    name="${mapping%%:*}"
    port="${mapping##*:}"
    set_port_name "$port" "$name"
  done < <(get_all_port_mappings)
else
  # Fallback to defaults if no library
  set_port_name "3000" "app"
  set_port_name "5555" "admin"
fi

echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}           Devcontainer Status${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

# Check if docker is available
if ! command -v docker &> /dev/null; then
  echo -e "${YELLOW}Docker not found${NC}"
  exit 1
fi

# Find all devcontainers (running and stopped)
ALL_CONTAINERS=$(docker ps -a --filter "label=devcontainer.local_folder" --format "{{.Names}}" 2>/dev/null)

if [ -z "$ALL_CONTAINERS" ]; then
  echo -e "${YELLOW}No devcontainers found${NC}"
  echo ""
  echo "Create one with:"
  echo "  devcon up                         # In project directory"
  echo "  devcon worktree --branch X        # With worktree"
  exit 0
fi

# Show running containers
echo -e "${GREEN}🟢 Running Containers:${NC}"
echo ""

RUNNING_COUNT=0
while IFS= read -r container_name; do
  STATUS=$(docker inspect --format='{{.State.Status}}' "$container_name" 2>/dev/null)

  if [ "$STATUS" = "running" ]; then
    RUNNING_COUNT=$((RUNNING_COUNT + 1))

    # Get workspace mount
    WORKSPACE=$(docker inspect --format='{{range .Mounts}}{{if eq .Destination "/workspace"}}{{.Source}}{{end}}{{end}}' "$container_name" 2>/dev/null)

    # Get creation time
    CREATED=$(docker inspect --format='{{.Created}}' "$container_name" 2>/dev/null | cut -d'T' -f1)

    # Get all port mappings
    PORTS=$(docker port "$container_name" 2>/dev/null)

    echo -e "  ${CYAN}${container_name}${NC}"
    echo "    ├─ Status:    $STATUS"
    echo "    ├─ Workspace: $WORKSPACE"
    echo "    ├─ Created:   $CREATED"

    if [ -n "$PORTS" ]; then
      echo "    └─ Ports:"
      echo "$PORTS" | while IFS= read -r port_line; do
        # Format: 3000/tcp -> 0.0.0.0:3000
        CONTAINER_PORT=$(echo "$port_line" | cut -d'/' -f1)
        HOST_PORT=$(echo "$port_line" | grep -o '[0-9]*$')

        # Look up custom name from config
        PORT_NAME=$(get_port_name "$CONTAINER_PORT")
        if [ -n "$PORT_NAME" ]; then
          echo "       • ${PORT_NAME}: http://localhost:$HOST_PORT"
        else
          echo "       • Port $CONTAINER_PORT: http://localhost:$HOST_PORT"
        fi
      done
    else
      echo "    └─ Ports:     None exposed"
    fi
    echo ""
  fi
done <<< "$ALL_CONTAINERS"

if [ $RUNNING_COUNT -eq 0 ]; then
  echo "  ${GRAY}No running containers${NC}"
  echo ""
fi

# Show stopped containers
echo -e "${YELLOW}⏸️  Stopped Containers:${NC}"
echo ""

STOPPED_COUNT=0
while IFS= read -r container_name; do
  STATUS=$(docker inspect --format='{{.State.Status}}' "$container_name" 2>/dev/null)

  if [ "$STATUS" != "running" ]; then
    STOPPED_COUNT=$((STOPPED_COUNT + 1))

    # Get workspace mount
    WORKSPACE=$(docker inspect --format='{{range .Mounts}}{{if eq .Destination "/workspace"}}{{.Source}}{{end}}{{end}}' "$container_name" 2>/dev/null)

    # Get stopped time
    STOPPED_AT=$(docker inspect --format='{{.State.FinishedAt}}' "$container_name" 2>/dev/null | cut -d'T' -f1)

    echo -e "  ${GRAY}${container_name}${NC}"
    echo "    ├─ Status:    $STATUS"
    echo "    ├─ Workspace: $WORKSPACE"
    echo "    └─ Stopped:   $STOPPED_AT"
    echo ""
  fi
done <<< "$ALL_CONTAINERS"

if [ $STOPPED_COUNT -eq 0 ]; then
  echo "  ${GRAY}No stopped containers${NC}"
  echo ""
fi

# Show git worktrees if in a git repo
if git rev-parse --git-dir >/dev/null 2>&1; then
  echo -e "${GREEN}📁 Git Worktrees (current repo):${NC}"
  echo ""

  WORKTREES=$(git worktree list --porcelain)

  if [ -n "$WORKTREES" ]; then
    echo "$WORKTREES" | awk '
    BEGIN { count=0 }
    /^worktree/ {
      count++
      path=$2
      printf "  %d. %s\n", count, path
    }
    /^branch/ {
      branch=$2
      gsub("refs/heads/", "", branch)
      printf "     └─ Branch: %s\n", branch
    }
    /^$/ { if (count > 0) printf "\n" }
    '
  else
    echo "  No worktrees found"
    echo ""
  fi
fi

# Summary
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "Summary:"
echo "  Running:  $RUNNING_COUNT"
echo "  Stopped:  $STOPPED_COUNT"
echo "  Total:    $((RUNNING_COUNT + STOPPED_COUNT))"
echo ""
echo "Quick Commands:"
echo "  Start or attach:   devcon up"
echo "  Stop containers:   devcon down"
echo "  Remove containers: devcon remove"
echo "  New worktree:      devcon worktree --branch feature/your-branch"
