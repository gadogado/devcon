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
  fi
fi

# Optional library (not required for init)
if [ -n "$LIB_SCRIPT" ] && [ -f "$LIB_SCRIPT" ]; then
  source "$LIB_SCRIPT" 2>/dev/null || true
fi

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Function to print colored output
info() { echo -e "${GREEN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; }
header() { echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; echo -e "${BLUE}$1${NC}"; echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; }

# Default values
PROJECT_NAME=""
PROJECT_DIR=""
TEMPLATE=""
INTERACTIVE=false
QUICK=false
TEMPLATE_SOURCE=""

# Find template source (where devcontainer scripts are installed)
find_template_source() {
  # Candidate locations relative to the installed package
  local script_parent
  script_parent="$(cd "$SCRIPT_DIR/.." && pwd)"

  for candidate in "$SCRIPT_DIR" "$script_parent"; do
    if [ -d "$candidate/.devcontainer" ]; then
      echo "$candidate"
      return 0
    fi
  done

  # Check common locations
  for dir in ~/devcontainer-scripts ~/Code/devcontainer-scripts ~/devcon; do
    if [ -d "$dir/.devcontainer" ]; then
      echo "$dir"
      return 0
    fi
  done

  return 1
}

# Detect project type from existing files
detect_project_type() {
  local dir="${1:-.}"

  if [ -f "$dir/package.json" ]; then
    echo "node"
  elif [ -f "$dir/requirements.txt" ] || [ -f "$dir/pyproject.toml" ]; then
    echo "python"
  elif [ -f "$dir/Gemfile" ]; then
    echo "ruby"
  elif [ -f "$dir/go.mod" ]; then
    echo "go"
  elif [ -f "$dir/Cargo.toml" ]; then
    echo "rust"
  else
    echo "generic"
  fi
}

# Prompt for user input
prompt() {
  local prompt_text="$1"
  local default_value="$2"
  local result

  if [ -n "$default_value" ]; then
    read -p "$(echo -e "${CYAN}${prompt_text}${NC} [${default_value}]: ")" result
    echo "${result:-$default_value}"
  else
    read -p "$(echo -e "${CYAN}${prompt_text}${NC}: ")" result
    echo "$result"
  fi
}

# Get template-specific defaults
get_template_defaults() {
  local template="$1"

  case "$template" in
    node)
      echo "node_version=lts"
      echo "app_port=3000"
      echo "admin_port=5555"
      echo "packages=@anthropic-ai/claude-code@latest,pnpm"
      ;;
    python)
      echo "python_version=3.11"
      echo "app_port=8000"
      echo "admin_port=8001"
      echo "packages=poetry,black,pytest"
      ;;
    ruby)
      echo "ruby_version=3.4"
      echo "app_port=3000"
      echo "admin_port=5555"
      echo "packages=bundler"
      ;;
    go)
      echo "go_version=latest"
      echo "app_port=8080"
      echo "admin_port=8081"
      echo "packages=gopls,delve"
      ;;
    *)
      echo "app_port=3000"
      echo "admin_port=5555"
      ;;
  esac
}

# Show help
show_help() {
  cat <<EOF
Usage: devcon init [OPTIONS]

Initialize a new project with devcontainer configuration.

Options:
  --name NAME           Project name (creates new directory)
  --dir PATH            Initialize in specific directory (default: current)
  --template TYPE       Use template (node, python, ruby, go, generic)
  --interactive, -i     Interactive mode (prompt for all settings)
  --quick, -q           Quick mode (use all defaults, no prompts)
  --help                Show this help message

Examples:
  # Initialize current directory (auto-detect)
  devcon init

  # Create new project
  devcon init --name my-new-project

  # Use specific template
  devcon init --template python --name ml-project

  # Interactive setup
  devcon init --interactive

  # Quick setup with defaults
  devcon init --quick --name quick-test

After initialization:
  cd <project-directory>
  devcon up

EOF
}

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --name)
      PROJECT_NAME="$2"
      shift 2
      ;;
    --dir)
      PROJECT_DIR="$2"
      shift 2
      ;;
    --template)
      TEMPLATE="$2"
      shift 2
      ;;
    --interactive|-i)
      INTERACTIVE=true
      shift
      ;;
    --quick|-q)
      QUICK=true
      shift
      ;;
    --help)
      show_help
      exit 0
      ;;
    *)
      error "Unknown option: $1"
      echo "Use --help for usage information"
      exit 1
      ;;
  esac
done

# Find template source
if ! TEMPLATE_SOURCE=$(find_template_source); then
  error "Could not find devcontainer template source"
  error "Please ensure devcontainer-scripts repo is cloned"
  exit 1
fi

TEMPLATE_SOURCE="$(cd "$TEMPLATE_SOURCE" && pwd)"
info "Using template from: $TEMPLATE_SOURCE"

# Determine target directory
if [ -n "$PROJECT_NAME" ]; then
  # Create new project directory
  if [ -n "$PROJECT_DIR" ]; then
    TARGET_DIR="$PROJECT_DIR/$PROJECT_NAME"
  else
    TARGET_DIR="$(pwd)/$PROJECT_NAME"
  fi

  if [ -d "$TARGET_DIR" ]; then
    error "Directory already exists: $TARGET_DIR"
    exit 1
  fi

  info "Creating new project directory: $TARGET_DIR"
  mkdir -p "$TARGET_DIR"
elif [ -n "$PROJECT_DIR" ]; then
  TARGET_DIR="$PROJECT_DIR"
else
  TARGET_DIR="$(pwd)"
fi

cd "$TARGET_DIR"
TARGET_DIR_ABS="$(pwd)"
TEMPLATE_SELF=0
if [ "$TEMPLATE_SOURCE" = "$TARGET_DIR_ABS" ]; then
  TEMPLATE_SELF=1
fi

# Check if .devcontainer already exists
if [ -d ".devcontainer" ]; then
  if [ "$TEMPLATE_SELF" -eq 0 ]; then
    error ".devcontainer directory already exists in $TARGET_DIR"
    read -p "Overwrite? (y/N): " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
      error "Aborted"
      exit 1
    fi
    rm -rf .devcontainer
  else
    info "Template lives in this repository; reusing existing .devcontainer"
  fi
fi

# Detect project type if not specified
if [ -z "$TEMPLATE" ]; then
  DETECTED_TYPE=$(detect_project_type "$TARGET_DIR")
  if [ "$DETECTED_TYPE" != "generic" ]; then
    info "Detected project type: $DETECTED_TYPE"
    TEMPLATE="$DETECTED_TYPE"
  else
    TEMPLATE="node"  # Default to Node.js
  fi
fi

info "Using template: $TEMPLATE"

# Copy .devcontainer directory
if [ "$TEMPLATE_SELF" -eq 0 ]; then
  info "Copying devcontainer configuration..."
  cp -r "$TEMPLATE_SOURCE/.devcontainer" .
fi

# Get template defaults
eval "$(get_template_defaults "$TEMPLATE")"

# Interactive or quick mode
if [ "$INTERACTIVE" = true ]; then
  header "Interactive Configuration"
  echo ""

  APP_PORT=$(prompt "Application port" "${app_port:-3000}")
  ADMIN_PORT=$(prompt "Admin/secondary port" "${admin_port:-5555}")

  echo ""
  info "Additional ports (comma-separated, e.g., 'api:8080,ws:3001'):"
  read -p "  " ADDITIONAL_PORTS

  echo ""
  ENABLE_SECURITY=$(prompt "Enable network security? (true/false)" "false")

  echo ""
  ENABLE_DOPPLER=$(prompt "Enable Doppler secrets? (true/false)" "false")

elif [ "$QUICK" = true ]; then
  info "Using quick defaults for $TEMPLATE"
  APP_PORT="${app_port:-3000}"
  ADMIN_PORT="${admin_port:-5555}"
  ADDITIONAL_PORTS=""
  ENABLE_SECURITY="false"
  ENABLE_DOPPLER="false"
else
  # Smart defaults
  APP_PORT="${app_port:-3000}"
  ADMIN_PORT="${admin_port:-5555}"
  ADDITIONAL_PORTS=""
  ENABLE_SECURITY="false"
  ENABLE_DOPPLER="false"
fi

# Update devcon.yaml with configuration
info "Configuring devcon.yaml..."

# Update ports
if [ -f ".devcontainer/devcon.yaml" ]; then
  # Use yq if available, otherwise sed
  if command -v yq >/dev/null 2>&1; then
    yq eval ".ports.app = $APP_PORT" -i .devcontainer/devcon.yaml
    yq eval ".ports.admin = $ADMIN_PORT" -i .devcontainer/devcon.yaml
    yq eval ".network.security.enabled = $ENABLE_SECURITY" -i .devcontainer/devcon.yaml
    yq eval ".doppler.enabled = $ENABLE_DOPPLER" -i .devcontainer/devcon.yaml
  else
    # Fallback to sed (basic replacement)
    sed -i.bak "s/app: [0-9]*/app: $APP_PORT/" .devcontainer/devcon.yaml
    sed -i.bak "s/admin: [0-9]*/admin: $ADMIN_PORT/" .devcontainer/devcon.yaml
    rm -f .devcontainer/devcon.yaml.bak
  fi
fi

# Success message
echo ""
header "✅ Project Initialized Successfully!"
echo ""
info "Project directory: $TARGET_DIR"
info "Template: $TEMPLATE"
info "Configuration: .devcontainer/devcon.yaml"
echo ""
echo -e "${CYAN}Next steps:${NC}"
echo "  1. Review and customize: .devcontainer/devcon.yaml"
echo "  2. Start the devcontainer: devcon up"
echo "  3. Or create a worktree: devcon worktree --branch feature/my-feature"
echo ""
echo -e "${CYAN}Quick commands:${NC}"
echo "  devcon up              # Start container (auto-assigns free ports)"
echo "  devcon up --no-cleanup # Keep container running after exit"
echo "  devcon status          # View all containers"
echo ""
echo "See README.md for full documentation"
echo ""
