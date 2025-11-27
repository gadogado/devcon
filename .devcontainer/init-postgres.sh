#!/bin/bash
set -euo pipefail

# Only run if PostgreSQL init script exists (package installed)
if [ ! -x /etc/init.d/postgresql ]; then
  exit 0
fi

echo "🗄️  Ensuring PostgreSQL service is running..."

ensure_pg_running() {
  if service postgresql status >/dev/null 2>&1; then
    echo "   PostgreSQL already running"
    return 0
  fi

  if service postgresql start >/dev/null 2>&1; then
    echo "   PostgreSQL started successfully"
    return 0
  fi

  PG_BIN=$(command -v pg_ctl || true)
  PG_DATADIR=$(sudo -u postgres sh -c 'psql -tAc "SHOW data_directory;"' 2>/dev/null | tr -d '[:space:]')

  if [ -n "$PG_BIN" ] && [ -n "$PG_DATADIR" ]; then
    echo "   Service start failed; attempting pg_ctl..."
    if sudo -u postgres "$PG_BIN" -D "$PG_DATADIR" start >/dev/null 2>&1; then
      echo "   PostgreSQL started via pg_ctl"
      return 0
    fi
  fi

  echo "⚠️   Unable to start PostgreSQL automatically. Run 'sudo service postgresql start' inside the container if needed."
  return 1
}

ensure_pg_running || exit 0

# Ensure devcon role and database exist
ensure_role() {
  local role="$1"
  if ! sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname = '${role}'" | grep -q 1; then
    echo "   Creating role '${role}'"
    sudo -u postgres psql -c "CREATE ROLE ${role} WITH LOGIN SUPERUSER"
  fi
}

ensure_db() {
  local db="$1"
  local owner="$2"
  if ! sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname = '${db}'" | grep -q 1; then
    echo "   Creating database '${db}' owned by ${owner}"
    sudo -u postgres createdb -O "${owner}" "${db}"
  fi
}

ensure_role "devcon"
ensure_role "node"
ensure_db "devcon" "devcon"
ensure_db "node" "node"

# Ensure pg_hba trusts devcon/node connections (prepend block once)
HBA_FILE=$(sudo -u postgres psql -tAc "SHOW hba_file;" 2>/dev/null | tr -d '[:space:]')
if [ -n "$HBA_FILE" ] && ! grep -q "DEVCON_PG_HBA" "$HBA_FILE"; then
  echo "   Prepending trusted pg_hba entries for devcon/node users"
  cat <<'EOF' | sudo tee /tmp/devcon_hba >/dev/null
# DEVCON_PG_HBA START
local   all   devcon   trust
host    all   devcon   127.0.0.1/32   trust
host    all   devcon   ::1/128        trust
host    all   devcon   0.0.0.0/0      trust
host    all   devcon   ::/0           trust
local   all   node     trust
host    all   node     127.0.0.1/32   trust
host    all   node     ::1/128        trust
host    all   node     0.0.0.0/0      trust
host    all   node     ::/0           trust
# DEVCON_PG_HBA END
EOF
  cat /tmp/devcon_hba "$HBA_FILE" | sudo tee "${HBA_FILE}.devcon" >/dev/null
  sudo mv "${HBA_FILE}.devcon" "$HBA_FILE"
  sudo rm /tmp/devcon_hba
  service postgresql reload >/dev/null 2>&1 || true
fi
