#!/bin/bash
set -euo pipefail # Exit on error, undefined vars, and pipeline failures
IFS=$'\n\t' # Stricter word splitting

# ============================================================================
# Network Security Firewall Initialization
# Based on: https://github.com/anthropics/claude-code/.devcontainer/init-firewall.sh
# Enhanced with YAML configuration support
# ============================================================================

CONFIG_FILE="/workspace/.devcontainer/devcon.yaml"

# Check if security is enabled via YAML config
if [ -f "$CONFIG_FILE" ] && command -v yq >/dev/null 2>&1; then
  SECURITY_ENABLED=$(yq eval '.network.security.enabled' "$CONFIG_FILE" 2>/dev/null || echo "false")

  if [ "$SECURITY_ENABLED" != "true" ]; then
    echo "Network security is disabled in config. Skipping firewall setup."
    exit 0
  fi

  echo "Network security enabled. Configuring firewall..."
else
  # No config file or yq - default to disabled
  echo "No configuration found or yq not available. Skipping firewall setup."
  exit 0
fi

# Read config values with defaults
LOG_BLOCKED=$(yq eval '.network.security.log_blocked' "$CONFIG_FILE" 2>/dev/null || echo "true")
DEFAULT_POLICY=$(yq eval '.network.security.default_policy' "$CONFIG_FILE" 2>/dev/null || echo "DROP")

# ============================================================================
# 1. Preserve Docker DNS Rules
# ============================================================================

DOCKER_DNS_RULES=$(iptables-save -t nat | grep "127.0.0.11" || true)

# Flush existing rules and delete existing ipsets
echo "Flushing existing firewall rules..."
iptables -F
iptables -X
iptables -t nat -F
iptables -t nat -X
iptables -t mangle -F
iptables -t mangle -X
ipset destroy allowed-domains 2>/dev/null || true

# Restore Docker DNS rules
if [ -n "$DOCKER_DNS_RULES" ]; then
  echo "Restoring Docker DNS rules..."
  iptables -t nat -N DOCKER_OUTPUT 2>/dev/null || true
  iptables -t nat -N DOCKER_POSTROUTING 2>/dev/null || true
  echo "$DOCKER_DNS_RULES" | xargs -L 1 iptables -t nat
else
  echo "No Docker DNS rules to restore"
fi

# ============================================================================
# 2. Allow Basic Connectivity
# ============================================================================

echo "Setting up basic connectivity rules..."

# Get allowed ports from config
ALLOWED_PORTS=(53 22 9418)  # DNS, SSH, Git protocol (defaults)

if [ -f "$CONFIG_FILE" ]; then
  # Add ALL configured ports from the ports section (except allocation_strategy)
  echo "Reading configured ports from YAML..."
  while IFS=: read -r name port; do
    if [ -n "$port" ] && [ "$port" != "null" ] && [ "$port" != "allocation_strategy" ]; then
      echo "  Adding port: $port ($name)"
      ALLOWED_PORTS+=("$port")
    fi
  done < <(yq eval '.ports | to_entries | .[] | select(.key != "allocation_strategy") | .key + ":" + (.value | tostring)' "$CONFIG_FILE" 2>/dev/null || echo "")

  # Add explicitly allowed ports from network.security.allowed_ports
  while IFS= read -r port; do
    if [ -n "$port" ] && [ "$port" != "null" ]; then
      echo "  Adding extra port: $port"
      ALLOWED_PORTS+=("$port")
    fi
  done < <(yq eval '.network.security.allowed_ports[]' "$CONFIG_FILE" 2>/dev/null || echo "")
fi

# Deduplicate ports
ALLOWED_PORTS=($(printf "%s\n" "${ALLOWED_PORTS[@]}" | sort -u))

echo "Allowed ports: ${ALLOWED_PORTS[*]}"

# Allow DNS (always needed)
iptables -A OUTPUT -p udp --dport 53 -j ACCEPT
iptables -A INPUT -p udp --sport 53 -j ACCEPT

# Allow configured ports
for port in "${ALLOWED_PORTS[@]}"; do
  if [ "$port" != "53" ]; then  # Skip DNS, already added
    iptables -A OUTPUT -p tcp --dport "$port" -j ACCEPT
    iptables -A INPUT -p tcp --sport "$port" -m state --state ESTABLISHED -j ACCEPT
  fi
done

# Allow localhost
iptables -A INPUT -i lo -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT

# ============================================================================
# 3. Create IP Allowlist
# ============================================================================

echo "Creating IP allowlist..."
ipset create allowed-domains hash:net

# ============================================================================
# 4. Base Domains (Claude Official - Always Included When Security Enabled)
# ============================================================================

BASE_DOMAINS=(
  "registry.npmjs.org"
  "api.anthropic.com"
  "sentry.io"
  "statsig.anthropic.com"
  "statsig.com"
  "marketplace.visualstudio.com"
  "vscode.blob.core.windows.net"
  "update.code.visualstudio.com"
)

echo "Base domains (Claude official):"
printf '  - %s\n' "${BASE_DOMAINS[@]}"

# ============================================================================
# 5. Additional Domains from YAML Config
# ============================================================================

ADDITIONAL_DOMAINS=()

if [ -f "$CONFIG_FILE" ]; then
  echo "Reading additional domains from YAML config..."

  # Read allowed_hosts array from YAML
  while IFS= read -r domain; do
    if [ -n "$domain" ] && [ "$domain" != "null" ]; then
      # Skip if it's a wildcard domain (handle separately if needed)
      if [[ "$domain" == *"*"* ]]; then
        echo "  - $domain (wildcard - will resolve base domain)"
        # Strip wildcard and use base domain
        domain="${domain#\*.}"
        ADDITIONAL_DOMAINS+=("$domain")
      else
        ADDITIONAL_DOMAINS+=("$domain")
      fi
    fi
  done < <(yq eval '.network.security.allowed_hosts[]' "$CONFIG_FILE" 2>/dev/null || echo "")

  if [ ${#ADDITIONAL_DOMAINS[@]} -gt 0 ]; then
    echo "Additional domains from config:"
    printf '  - %s\n' "${ADDITIONAL_DOMAINS[@]}"
  else
    echo "No additional domains in config"
  fi
fi

# Merge base and additional domains
ALL_DOMAINS=("${BASE_DOMAINS[@]}" "${ADDITIONAL_DOMAINS[@]}")

# ============================================================================
# 6. Fetch and Add GitHub IP Ranges
# ============================================================================

echo "Fetching GitHub IP ranges from API..."
gh_ranges=$(curl -s https://api.github.com/meta)

if [ -z "$gh_ranges" ]; then
  echo "ERROR: Failed to fetch GitHub IP ranges"
  exit 1
fi

if ! echo "$gh_ranges" | jq -e '.web and .api and .git' >/dev/null; then
  echo "ERROR: GitHub API response missing required fields"
  exit 1
fi

echo "Processing and aggregating GitHub IPs..."
while read -r cidr; do
  if [[ ! "$cidr" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}/[0-9]{1,2}$ ]]; then
    echo "ERROR: Invalid CIDR range from GitHub meta: $cidr"
    exit 1
  fi
  echo "  Adding GitHub range: $cidr"
  ipset add allowed-domains "$cidr"
done < <(echo "$gh_ranges" | jq -r '(.web + .api + .git)[]' | aggregate -q)

# ============================================================================
# 7. Resolve and Add Domain IPs
# ============================================================================

echo "Resolving domain names to IPs..."
for domain in "${ALL_DOMAINS[@]}"; do
  echo "  Resolving: $domain..."
  ips=$(dig +noall +answer A "$domain" | awk '$4 == "A" {print $5}')

  if [ -z "$ips" ]; then
    echo "    WARNING: Failed to resolve $domain (may be offline or DNS issue)"
    continue
  fi

  while read -r ip; do
    if [[ ! "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
      echo "    ERROR: Invalid IP from DNS for $domain: $ip"
      continue
    fi
    echo "    Adding: $ip"
    ipset add allowed-domains "$ip"
  done < <(echo "$ips")
done

# ============================================================================
# 8. Add Direct IPs from YAML Config
# ============================================================================

if [ -f "$CONFIG_FILE" ]; then
  echo "Reading additional IPs from YAML config..."

  while IFS= read -r ip_range; do
    if [ -n "$ip_range" ] && [ "$ip_range" != "null" ]; then
      # Validate CIDR or IP format
      if [[ "$ip_range" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}(/[0-9]{1,2})?$ ]]; then
        echo "  Adding IP/CIDR: $ip_range"
        ipset add allowed-domains "$ip_range"
      else
        echo "  WARNING: Invalid IP/CIDR format: $ip_range"
      fi
    fi
  done < <(yq eval '.network.security.allowed_ips[]' "$CONFIG_FILE" 2>/dev/null || echo "")
fi

# ============================================================================
# 9. Detect and Allow Host Network
# ============================================================================

HOST_IP=$(ip route | grep default | cut -d" " -f3)
if [ -z "$HOST_IP" ]; then
  echo "ERROR: Failed to detect host IP"
  exit 1
fi

HOST_NETWORK=$(echo "$HOST_IP" | sed "s/\.[0-9]*$/.0\/24/")
echo "Host network detected: $HOST_NETWORK"

iptables -A INPUT -s "$HOST_NETWORK" -j ACCEPT
iptables -A OUTPUT -d "$HOST_NETWORK" -j ACCEPT

# ============================================================================
# 10. Apply Default Policy and Rules
# ============================================================================

echo "Applying firewall policy: $DEFAULT_POLICY"

# Set default policies
iptables -P INPUT "$DEFAULT_POLICY"
iptables -P FORWARD "$DEFAULT_POLICY"
iptables -P OUTPUT "$DEFAULT_POLICY"

# Allow established connections
iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

# Allow outbound to allowed domains
iptables -A OUTPUT -m set --match-set allowed-domains dst -j ACCEPT

# ============================================================================
# 11. Logging (if enabled)
# ============================================================================

if [ "$LOG_BLOCKED" = "true" ]; then
  echo "Enabling logging for blocked connections..."

  # Log dropped outbound attempts (before final REJECT)
  iptables -A OUTPUT -m limit --limit 5/min -j LOG --log-prefix "FIREWALL-BLOCKED-OUT: " --log-level 4

  # Log dropped inbound attempts (before final policy)
  iptables -A INPUT -m limit --limit 5/min -j LOG --log-prefix "FIREWALL-BLOCKED-IN: " --log-level 4
fi

# ============================================================================
# 12. Final Reject Rule
# ============================================================================

# Explicitly REJECT all other outbound traffic for immediate feedback
iptables -A OUTPUT -j REJECT --reject-with icmp-admin-prohibited

echo ""
echo "Firewall configuration complete!"
echo ""

# ============================================================================
# 13. Verification Tests
# ============================================================================

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Running firewall verification tests..."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Test 1: Should be blocked
echo -n "Test 1: Verify example.com is blocked... "
if curl --connect-timeout 5 https://example.com >/dev/null 2>&1; then
  echo "❌ FAILED"
  echo "ERROR: Firewall verification failed - was able to reach https://example.com"
  exit 1
else
  echo "✅ PASSED"
fi

# Test 2: Should be allowed (GitHub)
echo -n "Test 2: Verify api.github.com is allowed... "
if ! curl --connect-timeout 5 https://api.github.com/zen >/dev/null 2>&1; then
  echo "❌ FAILED"
  echo "ERROR: Firewall verification failed - unable to reach https://api.github.com"
  exit 1
else
  echo "✅ PASSED"
fi

# Test 3: Should be allowed (npm)
echo -n "Test 3: Verify registry.npmjs.org is allowed... "
if ! curl --connect-timeout 5 https://registry.npmjs.org >/dev/null 2>&1; then
  echo "❌ FAILED"
  echo "ERROR: Firewall verification failed - unable to reach https://registry.npmjs.org"
  exit 1
else
  echo "✅ PASSED"
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✅ All verification tests passed!"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "Firewall Summary:"
echo "  - Base domains: ${#BASE_DOMAINS[@]}"
echo "  - Additional domains: ${#ADDITIONAL_DOMAINS[@]}"
echo "  - Total domains: ${#ALL_DOMAINS[@]}"
echo "  - Allowed ports: ${ALLOWED_PORTS[*]}"
echo "  - Default policy: $DEFAULT_POLICY"
echo "  - Logging: $LOG_BLOCKED"
echo ""
echo "To view blocked connections:"
echo "  sudo dmesg | grep FIREWALL-BLOCKED"
echo ""
