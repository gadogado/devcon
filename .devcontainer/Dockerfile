FROM node:lts

ARG TZ=UTC
ENV TZ="$TZ"

ARG GIT_DELTA_VERSION=0.18.2
ARG ZSH_IN_DOCKER_VERSION=1.2.0
ARG PYTHON_VERSION=3.11
ARG RUBY_VERSION

# Install basic development tools
RUN apt-get update && apt-get install -y --no-install-recommends \
  less \
  git \
  procps \
  sudo \
  fzf \
  zsh \
  man-db \
  unzip \
  gnupg2 \
  gh \
  iptables \
  ipset \
  iproute2 \
  dnsutils \
  aggregate \
  jq \
  nano \
  vim \
  curl \
  lsof \
  wget \
  locales \
  python3 \
  python3-pip \
  python3-venv \
  build-essential \
  libssl-dev \
  libreadline-dev \
  zlib1g-dev \
  libyaml-dev \
  libffi-dev \
  && apt-get clean && rm -rf /var/lib/apt/lists/*


RUN sed -i 's/# en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen && locale-gen en_US.UTF-8
ENV LANG=en_US.UTF-8
ENV LC_ALL=en_US.UTF-8
# Install yq for YAML parsing
ARG YQ_VERSION=v4.44.3
RUN ARCH=$(dpkg --print-architecture) && \
  wget "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_linux_${ARCH}" -O /usr/local/bin/yq && \
  chmod +x /usr/local/bin/yq

# Project configuration for optional dependencies
COPY devcon.yaml /tmp/devcon-config.yaml
RUN chmod 644 /tmp/devcon-config.yaml

# Install additional system packages from stack.system_packages (if any)
RUN bash <<'BASH'
set -euo pipefail
CONFIG_PATH="/tmp/devcon-config.yaml"
if [ -f "$CONFIG_PATH" ] && command -v yq >/dev/null 2>&1; then
  mapfile -t EXTRA_PACKAGES < <(yq eval '.stack.system_packages[]' "$CONFIG_PATH" 2>/dev/null || true)
  if [ "${#EXTRA_PACKAGES[@]}" -gt 0 ]; then
    echo "Installing extra system packages: ${EXTRA_PACKAGES[*]}"
    apt-get update
    apt-get install -y --no-install-recommends "${EXTRA_PACKAGES[@]}"
    apt-get clean
    rm -rf /var/lib/apt/lists/*
  else
    echo "No additional system packages requested"
  fi
else
  echo "Config missing or yq unavailable; skipping extra system packages"
fi
BASH

# Install Ruby only when stack.ruby_version (or RUBY_VERSION arg) is set
RUN bash <<'BASH'
set -euo pipefail
CONFIG_PATH="/tmp/devcon-config.yaml"
EFFECTIVE_RUBY_VERSION="${RUBY_VERSION:-}"
if [ -z "$EFFECTIVE_RUBY_VERSION" ] && [ -f "$CONFIG_PATH" ] && command -v yq >/dev/null 2>&1; then
  EFFECTIVE_RUBY_VERSION=$(yq eval -r '.stack.ruby_version // ""' "$CONFIG_PATH" 2>/dev/null || echo "")
fi

if [ -z "$EFFECTIVE_RUBY_VERSION" ]; then
  echo "No ruby_version configured; skipping Ruby install"
  exit 0
fi

if [[ "$EFFECTIVE_RUBY_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  RUBY_SERIES=$(echo "$EFFECTIVE_RUBY_VERSION" | awk -F. '{print $1 "." $2}')
  RUBY_TARBALL="$EFFECTIVE_RUBY_VERSION"
elif [[ "$EFFECTIVE_RUBY_VERSION" =~ ^[0-9]+\.[0-9]+$ ]]; then
  RUBY_SERIES="$EFFECTIVE_RUBY_VERSION"
  RUBY_TARBALL="${EFFECTIVE_RUBY_VERSION}.0"
else
  echo "Invalid ruby_version format: $EFFECTIVE_RUBY_VERSION"
  echo "Use values like '3.3.5' or '3.4'"
  exit 1
fi

echo "Installing Ruby ${RUBY_TARBALL} (series ${RUBY_SERIES})"
curl -fsSL "https://cache.ruby-lang.org/pub/ruby/${RUBY_SERIES}/ruby-${RUBY_TARBALL}.tar.gz" -o /tmp/ruby.tar.gz
tar -xzf /tmp/ruby.tar.gz -C /tmp
cd /tmp/ruby-${RUBY_TARBALL}
./configure --prefix=/usr/local --disable-install-doc
make -j"$(nproc)"
make install
gem update --system
gem install bundler
rm -rf /tmp/ruby.tar.gz /tmp/ruby-${RUBY_TARBALL}
BASH

# Install PostgreSQL only when stack.postgres_version is set
RUN bash <<'BASH'
set -euo pipefail
CONFIG_PATH="/tmp/devcon-config.yaml"
POSTGRES_VERSION=""
if [ -f "$CONFIG_PATH" ] && command -v yq >/dev/null 2>&1; then
  POSTGRES_VERSION=$(yq eval -r '.stack.postgres_version // ""' "$CONFIG_PATH" 2>/dev/null || echo "")
fi

if [ -z "$POSTGRES_VERSION" ]; then
  echo "No postgres_version configured; skipping PostgreSQL install"
  exit 0
fi

echo "Installing PostgreSQL ${POSTGRES_VERSION}"
CODENAME=$(grep -Poi '(?<=VERSION_CODENAME=).+' /etc/os-release || true)
if [ -z "$CODENAME" ]; then
  if command -v lsb_release >/dev/null 2>&1; then
    CODENAME=$(lsb_release -sc)
  else
    echo "Unable to determine Debian codename for PostgreSQL install"
    exit 1
  fi
fi
echo "Using Debian codename: ${CODENAME}"

curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc | gpg --dearmor -o /usr/share/keyrings/pgdg-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/pgdg-archive-keyring.gpg] http://apt.postgresql.org/pub/repos/apt ${CODENAME}-pgdg main" > /etc/apt/sources.list.d/pgdg.list

apt-get update
if ! apt-get install -y --no-install-recommends "postgresql-${POSTGRES_VERSION}" "postgresql-client-${POSTGRES_VERSION}"; then
  echo "Failed to install PostgreSQL ${POSTGRES_VERSION}"
  exit 1
fi
apt-get clean
rm -rf /var/lib/apt/lists/*
BASH

# Install Doppler CLI
RUN curl -sLf --retry 3 --tlsv1.2 --proto "=https" 'https://packages.doppler.com/public/cli/gpg.DE2A7741A397C129.key' | gpg --dearmor -o /usr/share/keyrings/doppler-archive-keyring.gpg && \
  echo "deb [signed-by=/usr/share/keyrings/doppler-archive-keyring.gpg] https://packages.doppler.com/public/cli/deb/debian any-version main" | tee /etc/apt/sources.list.d/doppler-cli.list && \
  apt-get update && apt-get install -y doppler && \
  apt-get clean && rm -rf /var/lib/apt/lists/*

# Ensure default node user has access to /usr/local/share
RUN mkdir -p /usr/local/share/npm-global && \
  chown -R node:node /usr/local/share

ARG USERNAME=node

# Persist bash history
RUN SNIPPET="export PROMPT_COMMAND='history -a' && export HISTFILE=/commandhistory/.bash_history" \
  && mkdir /commandhistory \
  && touch /commandhistory/.bash_history \
  && chown -R $USERNAME /commandhistory

ENV DEVCONTAINER=true

RUN mkdir -p /workspace /home/node/.claude && \
  chown -R node:node /workspace /home/node/.claude

WORKDIR /workspace

# Install git-delta
RUN ARCH=$(dpkg --print-architecture) && \
  wget "https://github.com/dandavison/delta/releases/download/${GIT_DELTA_VERSION}/git-delta_${GIT_DELTA_VERSION}_${ARCH}.deb" && \
  sudo dpkg -i "git-delta_${GIT_DELTA_VERSION}_${ARCH}.deb" && \
  rm "git-delta_${GIT_DELTA_VERSION}_${ARCH}.deb"

USER node

ENV NPM_CONFIG_PREFIX=/usr/local/share/npm-global
ENV PNPM_HOME=/home/node/.local/share/pnpm
ENV PATH=$PATH:/usr/local/share/npm-global/bin:$PNPM_HOME:/home/node/.local/bin
ENV SHELL=/bin/zsh
ENV EDITOR=vim
ENV VISUAL=vim
ENV PYTHONUNBUFFERED=1
ENV PGUSER=devcon
ENV PGDATABASE=devcon
ENV PGHOST=localhost

RUN mkdir -p "$PNPM_HOME" /home/node/.local/bin

# Default powerline10k theme
RUN sh -c "$(wget -O- https://github.com/deluan/zsh-in-docker/releases/download/v${ZSH_IN_DOCKER_VERSION}/zsh-in-docker.sh)" -- \
  -p git \
  -p fzf \
  -a "source /usr/share/doc/fzf/examples/key-bindings.zsh" \
  -a "source /usr/share/doc/fzf/examples/completion.zsh" \
  -a "export PROMPT_COMMAND='history -a' && export HISTFILE=/commandhistory/.bash_history" \
  -x

RUN npm install -g pnpm

# Install any opt-in global pnpm packages
RUN bash <<'BASH'
set -euo pipefail
CONFIG_PATH="/tmp/devcon-config.yaml"
if [ -f "$CONFIG_PATH" ] && command -v yq >/dev/null 2>&1; then
  mapfile -t GLOBAL_PACKAGES < <(yq eval '.stack.global_packages[]' "$CONFIG_PATH" 2>/dev/null || true)
  if [ "${#GLOBAL_PACKAGES[@]}" -gt 0 ]; then
    echo ""
    echo "📦 Installing global packages..."
    echo "────────────────────────────────"
    for pkg in "${GLOBAL_PACKAGES[@]}"; do
      case "$pkg" in
        cursor-agent)
          echo "⏳ Installing $pkg (via official installer)..."
          if curl -fsSL https://cursor.com/install -o /tmp/cursor-install.sh 2>/dev/null; then
            chmod +x /tmp/cursor-install.sh
            if /tmp/cursor-install.sh >/dev/null 2>&1; then
              echo "✅ $pkg installed"
            else
              echo "❌ $pkg failed to install"
            fi
            rm -f /tmp/cursor-install.sh
          else
            echo "❌ $pkg failed to download installer"
          fi
          ;;
        *)
          echo "⏳ Installing $pkg..."
          if pnpm install -g "$pkg" >/dev/null 2>&1; then
            echo "✅ $pkg installed"
          else
            echo "❌ $pkg failed to install"
            exit 1
          fi
          ;;
      esac
    done
    echo "────────────────────────────────"
    echo "📦 Global packages complete"
    echo ""
  else
    echo "📦 No global packages configured"
  fi
else
  echo "⚠️  Config missing or yq unavailable; skipping global packages"
fi
BASH

# Install uv (optional) and try to provision requested Python version
RUN bash -c 'set -euo pipefail; \
  if curl -fsSL https://astral.sh/uv/install.sh | sh; then \
    /home/node/.local/bin/uv python install --default '"${PYTHON_VERSION}"'; \
  else \
    echo "Skipping uv install (download failed)"; \
  fi'

USER root
COPY init-firewall.sh /usr/local/bin/
COPY init-container.sh /usr/local/bin/
COPY init-postgres.sh /usr/local/bin/
RUN chmod 755 /usr/local/bin/init-firewall.sh /usr/local/bin/init-container.sh /usr/local/bin/init-postgres.sh && \
  usermod -aG sudo node && \
  echo "node ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/devcon-nopasswd && \
  chmod 0440 /etc/sudoers.d/devcon-nopasswd

# Run custom setup commands from devcon.yaml
RUN bash <<'BASH'
set -euo pipefail
CONFIG_PATH="/tmp/devcon-config.yaml"
if [ -f "$CONFIG_PATH" ] && command -v yq >/dev/null 2>&1; then
  mapfile -t SETUP_COMMANDS < <(yq eval '.stack.setup_commands[]' "$CONFIG_PATH" 2>/dev/null || true)
  if [ "${#SETUP_COMMANDS[@]}" -gt 0 ]; then
    echo ""
    echo "🔧 Running setup commands..."
    echo "────────────────────────────────"
    for cmd in "${SETUP_COMMANDS[@]}"; do
      echo "⏳ $cmd"
      if bash -c "$cmd"; then
        echo "✅ Done"
      else
        echo "❌ Failed"
        exit 1
      fi
    done
    echo "────────────────────────────────"
    echo "🔧 Setup commands complete"
    echo ""
  fi
fi
BASH

# Cleanup copied config
RUN rm -f /tmp/devcon-config.yaml
USER node
