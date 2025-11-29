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

# If not found in same directory, try PATH
if [ ! -f "$LIB_SCRIPT" ]; then
  if command -v lib.sh >/dev/null 2>&1; then
    LIB_SCRIPT="lib.sh"
  else
    echo "ERROR: Cannot find lib.sh"
    exit 1
  fi
fi

source "$LIB_SCRIPT"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

info() { echo -e "${GREEN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; }
step() { echo -e "${BLUE}[STEP]${NC} $1"; }

# Default values
WORKTREE_BASE=""  # Will be set from config
BRANCH_NAME=""
CONTAINER_NAME=""
AUTO_CLEANUP=""  # Will be set from config

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --branch|-b)
      BRANCH_NAME="$2"
      shift 2
      ;;
    --worktree-base)
      WORKTREE_BASE="$2"
      shift 2
      ;;
    --no-cleanup)
      AUTO_CLEANUP=false
      shift
      ;;
    --name)
      CONTAINER_NAME="$2"
      shift 2
      ;;
    --help)
      echo "Usage: devcon worktree --branch BRANCH_NAME [OPTIONS]"
      echo ""
      echo "Create a git worktree and start a devcontainer in it."
      echo ""
      echo "Required:"
      echo "  --branch, -b NAME       Branch name for the worktree"
      echo ""
      echo "Options:"
      echo "  --worktree-base PATH    Base directory for worktrees (default: ~/devcon-worktrees)"
      echo "  --no-cleanup            Keep the devcontainer running after exit"
      echo "  --name NAME             Custom container name"
      echo "  --help                  Show this help message"
      echo ""
      echo "Examples:"
      echo "  # Create worktree with default auto ports"
      echo "  devcon worktree --branch feature/auth-improvements"
      echo ""
      echo "  # Create worktree + custom container name"
      echo "  devcon worktree --branch feature/schema-migration --name schema-dev"
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

# Helper to expand user-provided paths
expand_path() {
  local input="$1"
  if [ -z "$input" ]; then
    echo ""
    return
  fi

  if [[ "$input" == ~* ]]; then
    input="${input/#\~/$HOME}"
  elif [[ "$input" != /* ]]; then
    input="$HOME/$input"
  fi

  echo "$input"
}

# Sync the current repo's .devcontainer directory into the worktree
sync_devcontainer_config() {
  local source_root="$1"
  local target_root="$2"
  local source_dir="$source_root/.devcontainer"
  local target_dir="$target_root/.devcontainer"

  if [ ! -d "$source_dir" ]; then
    return
  fi

  local source_status=""
  if git -C "$source_root" rev-parse --git-dir >/dev/null 2>&1; then
    source_status=$(git -C "$source_root" status --porcelain -- .devcontainer 2>/dev/null || true)
  fi

  if [ -z "$source_status" ] && [ -d "$target_dir" ]; then
    # Target already has the committed config and there are no local overrides to copy
    return
  fi

  if [ -d "$target_dir" ]; then
    rm -rf "$target_dir"
  fi

  info "Syncing .devcontainer configuration into worktree..."
  cp -R "$source_dir" "$target_dir"
}

# Load config values if not provided via CLI
if [ -z "$WORKTREE_BASE" ]; then
  WORKTREE_BASE=$(get_worktree_base)
else
  WORKTREE_BASE=$(expand_path "$WORKTREE_BASE")
fi

if [ ! -d "$WORKTREE_BASE" ]; then
  warn "Worktree base directory '$WORKTREE_BASE' does not exist."
  read -p "Create it now? (y/n) " -n 1 -r
  echo
  if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    error "Cannot continue without a worktree base directory."
    exit 1
  fi
  mkdir -p "$WORKTREE_BASE"
  info "Created worktree base directory: $WORKTREE_BASE"
fi

if [ -z "$AUTO_CLEANUP" ]; then
  if [ "$(get_auto_cleanup)" = "true" ]; then
    AUTO_CLEANUP=true
  else
    AUTO_CLEANUP=false
  fi
fi

# Validate required arguments
if [ -z "$BRANCH_NAME" ]; then
  error "Branch name is required. Use --branch or -b flag."
  echo "Use --help for usage information"
  exit 1
fi

# Ensure we're in a git repo
if ! git rev-parse --git-dir >/dev/null 2>&1; then
  error "Not in a git repository"
  exit 1
fi

# Get repo root/name for organizing worktrees and config sync
REPO_ROOT=$(git rev-parse --show-toplevel)
REPO_NAME=$(basename "$REPO_ROOT")

# Create worktree directory path
WORKTREE_DIR="$WORKTREE_BASE/$REPO_NAME/$BRANCH_NAME"

# Check if worktree already exists
if [ -d "$WORKTREE_DIR" ]; then
  warn "Worktree directory already exists: $WORKTREE_DIR"
  read -p "Do you want to use the existing worktree? (y/n) " -n 1 -r
  echo
  if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    error "Aborted"
    exit 1
  fi
else
  # Create worktree base directory if it doesn't exist
  mkdir -p "$WORKTREE_BASE/$REPO_NAME"

  # Check if branch exists
  if git show-ref --verify --quiet "refs/heads/$BRANCH_NAME"; then
    step "Branch '$BRANCH_NAME' exists, creating worktree..."
    git worktree add "$WORKTREE_DIR" "$BRANCH_NAME"
  else
    step "Creating new branch '$BRANCH_NAME' and worktree..."
    git worktree add -b "$BRANCH_NAME" "$WORKTREE_DIR"
  fi

  info "Worktree created at: $WORKTREE_DIR"
fi

# Ensure devcontainer config matches the source repo
sync_devcontainer_config "$REPO_ROOT" "$WORKTREE_DIR"

# Change to worktree directory
cd "$WORKTREE_DIR"

# Build devcon up command
DEV_UP_CMD="devcon up"

if [ -n "$CONTAINER_NAME" ]; then
  DEV_UP_CMD="$DEV_UP_CMD --name $CONTAINER_NAME"
fi

if [ "$AUTO_CLEANUP" = false ]; then
  DEV_UP_CMD="$DEV_UP_CMD --no-cleanup"
fi

# Start the devcontainer
step "Starting devcontainer..."
echo ""
$DEV_UP_CMD

# After exiting the container, show cleanup options
echo ""
info "Exited devcontainer"
echo ""
echo "Worktree is still active at: $WORKTREE_DIR"
echo ""
echo "To return to this worktree:"
echo "  cd $WORKTREE_DIR"
echo "  devcon up"
echo ""
echo "To remove this worktree:"
echo "  git worktree remove $WORKTREE_DIR"
