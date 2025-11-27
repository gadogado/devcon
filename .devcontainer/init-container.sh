#!/bin/bash
set -e

echo "🔧 Initializing devcontainer..."

# Initialize firewall
echo "🔥 Setting up firewall rules..."
sudo /usr/local/bin/init-firewall.sh

# Start PostgreSQL if available
if [ -x /usr/local/bin/init-postgres.sh ]; then
  sudo /usr/local/bin/init-postgres.sh || true
fi

# Configure Doppler if enabled and token is available
if [ "${DOPPLER_ENABLED:-true}" != "true" ]; then
  echo "ℹ️  Doppler integration disabled by configuration"
elif [ -n "$DOPPLER_TOKEN" ]; then
  echo "🔐 Configuring Doppler..."

  # Configure Doppler CLI
  doppler configure set token "$DOPPLER_TOKEN" --silent --scope /

  # Verify Doppler is working
  if doppler secrets --no-read-only >/dev/null 2>&1; then
    echo "✅ Doppler configured successfully"

    # Inject secrets into shell environment via .zshrc
    # This makes secrets available in all new shell sessions
    if ! grep -q "doppler run" /home/node/.zshrc 2>/dev/null; then
      echo '' >> /home/node/.zshrc
      echo '# Auto-inject Doppler secrets' >> /home/node/.zshrc
      echo 'if command -v doppler >/dev/null 2>&1 && doppler secrets --no-read-only >/dev/null 2>&1; then' >> /home/node/.zshrc
      echo '  eval "$(doppler secrets download --no-file --format env-no-quotes)"' >> /home/node/.zshrc
      echo 'fi' >> /home/node/.zshrc
    fi

    # Also inject into current environment for postStartCommand processes
    eval "$(doppler secrets download --no-file --format env-no-quotes)"

  else
    echo "⚠️  Doppler token present but unable to fetch secrets"
    echo "    Check token permissions and project configuration"
  fi
else
  echo "⚠️  DOPPLER_TOKEN not set - secrets will not be available"
  echo "    Set DOPPLER_TOKEN in your host environment to enable secret injection"
fi

echo "✨ Container initialization complete"
