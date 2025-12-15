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

# Configure Doppler if enabled
if [ "${DOPPLER_ENABLED:-true}" != "true" ]; then
  echo "ℹ️  Doppler integration disabled by configuration"
elif [ -n "${DOPPLER_TOKEN:-}" ]; then
  echo "🔐 Configuring Doppler..."

  # Verify token works
  if doppler secrets --no-read-only >/dev/null 2>&1; then
    echo "✅ Doppler secrets accessible"
    echo "    Usage: doppler run -- <command>"
  else
    echo "⚠️  DOPPLER_TOKEN provided but unable to fetch secrets"
    echo "    Check token permissions and project/config settings"
  fi
else
  echo "ℹ️  DOPPLER_TOKEN not set - Doppler secrets unavailable"
  echo "    Get a personal token at https://dashboard.doppler.com"
  echo "    Then: export DOPPLER_TOKEN=dp.pt.xxx on your host"
fi

echo "✨ Container initialization complete"
