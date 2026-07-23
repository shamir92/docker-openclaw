#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# Restrict the Caddy-published port 443 so ONLY Cloudflare edge IPs can reach
# it. This is REQUIRED with trusted-proxy auth: the only thing protecting the
# gateway is a header that Cloudflare Access injects. If an attacker can reach
# your origin directly (bypassing Cloudflare), they can spoof that header.
#
# Docker publishes ports via the DOCKER-USER iptables chain, which BYPASSES ufw,
# so we must filter there — plain `ufw` rules will NOT protect a published port.
#
# Run as root:  sudo ./lock-origin-to-cloudflare.sh
# Re-run any time to refresh the Cloudflare IP list.
# ---------------------------------------------------------------------------

CHAIN="DOCKER-USER"
PORT=443

command -v iptables  >/dev/null || { echo "iptables not found";  exit 1; }
command -v ip6tables >/dev/null || { echo "ip6tables not found"; exit 1; }

echo "[*] Resetting $CHAIN ..."
iptables  -F "$CHAIN"
ip6tables -F "$CHAIN"

# Always allow return traffic for established connections.
iptables  -A "$CHAIN" -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN
ip6tables -A "$CHAIN" -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN

echo "[*] Allowing Cloudflare IPv4 ranges to tcp/$PORT ..."
for ip in $(curl -fsSL https://www.cloudflare.com/ips-v4); do
  iptables -A "$CHAIN" -p tcp --dport "$PORT" -s "$ip" -j RETURN
done

echo "[*] Allowing Cloudflare IPv6 ranges to tcp/$PORT ..."
for ip in $(curl -fsSL https://www.cloudflare.com/ips-v6); do
  ip6tables -A "$CHAIN" -p tcp --dport "$PORT" -s "$ip" -j RETURN
done

# Drop anyone else hitting the published app port.
iptables  -A "$CHAIN" -p tcp --dport "$PORT" -j DROP
ip6tables -A "$CHAIN" -p tcp --dport "$PORT" -j DROP

# Let all other Docker traffic pass through unchanged.
iptables  -A "$CHAIN" -j RETURN
ip6tables -A "$CHAIN" -j RETURN

echo "[*] Done."
echo "[*] Persist across reboots with:"
echo "      sudo apt-get install -y iptables-persistent"
echo "      sudo netfilter-persistent save"
echo "    (Note: Docker recreates DOCKER-USER on daemon restart; re-run this"
echo "     script or install it as a systemd unit ordered After=docker.service.)"
