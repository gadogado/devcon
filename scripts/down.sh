#!/bin/bash
set -e

# Load configuration library
SCRIPT_PATH="${BASH_SOURCE[0]}"
while [ -L "$SCRIPT_PATH" ]; do
  SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"
  SCRIPT_PATH="$(readlink "$SCRIPT_PATH")"
  [[ $SCRIPT_PATH != /* ]] && SCRIPT_PATH="$SCRIPT_DIR/$SCRIPT_PATH"
done
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"
LIB_SCRIPT="$SCRIPT_DIR/lib.sh"

if [ ! -f "$LIB_SCRIPT" ]; then
  if command -v lib.sh >/dev/null 2>&1; then
    LIB_SCRIPT="lib.sh"
  else
    echo "ERROR: Cannot find lib.sh"
    exit 1
  fi
fi

source "$LIB_SCRIPT"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info() { echo -e "${GREEN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; }

WORKSPACE="$(pwd -P 2>/dev/null || pwd)"
LABEL_FILTER="label=devcontainer.local_folder=${WORKSPACE}"

if ! command -v docker >/dev/null 2>&1; then
  error "Docker is required for this command"
  exit 1
fi

RUNNING_CONTAINERS=$(docker ps --filter "$LABEL_FILTER" --format '{{.ID}}\t{{.Names}}')

if [ -z "$RUNNING_CONTAINERS" ]; then
  info "No running devcontainers found for $WORKSPACE"
  exit 0
fi

COUNT=0
while IFS=$'\t' read -r ID NAME; do
  [ -z "$ID" ] && continue
  info "Stopping $NAME..."
  docker stop "$ID" >/dev/null
  COUNT=$((COUNT + 1))
done <<< "$RUNNING_CONTAINERS"

info "Stopped $COUNT container(s)"
