#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# Restrict the Caddy-published port 443 so ONLY Cloudflare edge IPs can reach
# it. REQUIRED with trusted-proxy auth: the only thing protecting the gateway
# is a header Cloudflare Access injects. An attacker who reaches your origin
# directly (bypassing Cloudflare) could spoof that header.
#
# Docker publishes ports via the DOCKER-USER iptables chain, which BYPASSES ufw,
# so we must filter there — plain `ufw` rules do NOT protect a published port.
#
# Persistence: install as a systemd unit (see scripts/cloudflare-lock.service)
# so it re-applies at boot and whenever the Docker daemon restarts. Do NOT rely
# on iptables-persistent on a Docker host — restoring a saved ruleset conflicts
# with Docker's dynamically-created chains.
#
# Run as root:  sudo /usr/local/sbin/lock-origin-to-cloudflare.sh
# ---------------------------------------------------------------------------

CHAIN="DOCKER-USER"
PORT=443
CACHE_DIR="/var/lib/cloudflare-lock"

command -v iptables  >/dev/null || { echo "iptables not found";  exit 1; }
command -v ip6tables >/dev/null || { echo "ip6tables not found"; exit 1; }
mkdir -p "$CACHE_DIR"

# Fetch a Cloudflare IP list, but keep the last-good copy if the fetch fails.
fetch() { # $1=url  $2=cachefile
  local tmp; tmp="$(mktemp)"
  if curl -fsSL --max-time 10 "$1" -o "$tmp" && [ -s "$tmp" ]; then
    mv "$tmp" "$2"
  else
    rm -f "$tmp"
    echo "[!] fetch failed for $1 — falling back to cached $2 (if present)"
  fi
}

fetch https://www.cloudflare.com/ips-v4 "$CACHE_DIR/ips-v4"
fetch https://www.cloudflare.com/ips-v6 "$CACHE_DIR/ips-v6"

# Never proceed with an empty IPv4 list: we'd DROP all :443 including Cloudflare
# itself and take the site down. Abort without touching the firewall instead.
if [ ! -s "$CACHE_DIR/ips-v4" ]; then
  echo "[x] No Cloudflare IPv4 list (fetch failed and no cache). Aborting, no changes made."
  exit 1
fi

echo "[*] Resetting $CHAIN ..."
iptables  -F "$CHAIN"
ip6tables -F "$CHAIN"

# Allow return traffic for established connections.
iptables  -A "$CHAIN" -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN
ip6tables -A "$CHAIN" -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN

echo "[*] Allowing Cloudflare IPv4 ranges to tcp/$PORT ..."
while read -r ip; do
  [ -n "$ip" ] && iptables -A "$CHAIN" -p tcp --dport "$PORT" -s "$ip" -j RETURN
done < "$CACHE_DIR/ips-v4"

if [ -s "$CACHE_DIR/ips-v6" ]; then
  echo "[*] Allowing Cloudflare IPv6 ranges to tcp/$PORT ..."
  while read -r ip; do
    [ -n "$ip" ] && ip6tables -A "$CHAIN" -p tcp --dport "$PORT" -s "$ip" -j RETURN
  done < "$CACHE_DIR/ips-v6"
fi

# Drop everyone else hitting the published app port.
iptables  -A "$CHAIN" -p tcp --dport "$PORT" -j DROP
ip6tables -A "$CHAIN" -p tcp --dport "$PORT" -j DROP

# Let all other Docker traffic pass through unchanged.
iptables  -A "$CHAIN" -j RETURN
ip6tables -A "$CHAIN" -j RETURN

echo "[*] Cloudflare origin lock applied on tcp/$PORT."
