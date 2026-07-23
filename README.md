# OpenClaw + Caddy + Cloudflare (Access / trusted-proxy auth)

Self-hosted OpenClaw gateway behind Caddy, with Cloudflare DNS (proxied/orange),
TLS via the Cloudflare DNS-01 challenge, and authentication delegated to
**Cloudflare Access** using OpenClaw's **trusted-proxy** auth model.

```
Browser
  │  (user logs in via Cloudflare Access: Google / GitHub / one-time PIN)
  ▼
Cloudflare edge ──► injects  Cf-Access-Authenticated-User-Email
  │
  ▼  (:443, firewalled to Cloudflare IPs only)
Caddy  ──► maps that email to  X-Forwarded-User
  │        + auto-sets X-Forwarded-Proto / X-Forwarded-Host
  ▼  (internal docker network 172.28.0.0/24)
OpenClaw gateway :18789
        auth.mode = trusted-proxy, trustedProxies = [Caddy IP]
```

Files in this folder:

| Path | What it is |
|------|------------|
| `docker-compose.yml` | Caddy + OpenClaw gateway on an isolated bridge network |
| `caddy/Dockerfile` | Caddy built with the `caddy-dns/cloudflare` plugin |
| `caddy/Caddyfile` | TLS + reverse proxy + Access→header mapping |
| `.env.example` | Domain, ACME email, Cloudflare API token |
| `openclaw/config/openclaw.gateway-snippet.json` | The `gateway` block to merge into the generated config |
| `scripts/lock-origin-to-cloudflare.sh` | Firewall the origin to Cloudflare IPs (**required**) |

Replace `openclaw.example.com` / `you@example.com` everywhere with your real values.

---

## 0. Prerequisites (Ubuntu 26.04)

```bash
# Docker Engine + Compose v2
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker "$USER"   # log out/in afterwards

# Copy this folder to the server, then:
cd openclaw-caddy
cp .env.example .env
$EDITOR .env                       # set DOMAIN, ACME_EMAIL, CLOUDFLARE_API_TOKEN
```

---

## 1. Cloudflare DNS

In the Cloudflare dashboard for your zone → **DNS → Records**:

- Add an **A** record: `openclaw` → your server's public IPv4.
- **Proxy status: Proxied (orange cloud).**

Then **SSL/TLS → Overview → set encryption mode to `Full (strict)`.**
(Caddy will hold a real Let's Encrypt cert, so strict validation passes.)
Also enable **SSL/TLS → Edge Certificates → Always Use HTTPS**.

## 2. Cloudflare API token (for Caddy's TLS)

**My Profile → API Tokens → Create Token → "Edit zone DNS" template**:
- Permissions: `Zone → DNS → Edit` **and** `Zone → Zone → Read`
- Zone Resources: Include → your zone

Put the token in `.env` as `CLOUDFLARE_API_TOKEN`.

## 3. Cloudflare Access (Zero Trust) — this is the "auth"

**Zero Trust dashboard → Access → Applications → Add an application → Self-hosted:**

1. **Application domain:** `openclaw.example.com`
2. **Identity providers:** enable at least one (Google, GitHub, or One-time PIN).
3. **Policies →** Add a policy:
   - Action: **Allow**
   - Include → **Emails** → the address(es) allowed in (e.g. `you@example.com`).
4. Save. (Optional: note the **Application Audience (AUD) tag** under the app's
   Overview — needed only if you later add JWT validation, see Hardening.)

> Access now sits in front of the hostname. Every request is authenticated at
> Cloudflare's edge before it ever reaches your server, and Cloudflare injects
> the `Cf-Access-Authenticated-User-Email` header that Caddy forwards.

## 4. Prepare local directories & permissions

The gateway container runs as uid **1000** (`node`), so bind-mounted dirs must
be owned by it:

```bash
mkdir -p openclaw/config openclaw/secret caddy/data caddy/config
sudo chown -R 1000:1000 openclaw/config openclaw/secret
```

## 5. First start (generate default config)

Bring up the gateway once so it writes a default `openclaw.json`:

```bash
docker compose up -d --build
docker compose logs -f openclaw-gateway    # watch until it's serving on :18789, then Ctrl-C
```

## 6. Enable trusted-proxy auth

Merge the `gateway` block from `openclaw/config/openclaw.gateway-snippet.json`
into the generated `openclaw/config/openclaw.json` (keep any other keys the
gateway already wrote). Edit these values in the snippet first:

- `allowedOrigins`  → `["https://openclaw.example.com"]`
- `allowUsers`      → your Access email(s)
- `trustedProxies`  → keep `["172.28.0.2/32"]` (Caddy's fixed IP from compose)

Then restart and confirm auth mode is active:

```bash
docker compose restart openclaw-gateway
docker compose logs --tail=50 openclaw-gateway   # should show trusted-proxy auth, no token error
```

> If startup errors about a token being set, ensure `OPENCLAW_GATEWAY_TOKEN` is
> **not** in your `.env`/environment and `gateway.auth.token` is **not** in
> `openclaw.json` — trusted-proxy mode refuses to run alongside a shared token.

## 7. Lock the origin to Cloudflare (REQUIRED)

Because the gateway trusts a header, an exposed origin = full auth bypass.
Docker bypasses `ufw`, so use the provided script (filters the `DOCKER-USER`
chain):

```bash
sudo bash scripts/lock-origin-to-cloudflare.sh

# also allow SSH from your admin IP and enable ufw for everything else:
sudo ufw allow from <YOUR_ADMIN_IP> to any port 22 proto tcp
sudo ufw --force enable
```

## 8. Verify

```bash
# From a machine that is NOT Cloudflare — should hang/refuse (origin locked):
curl -m 5 -k https://<SERVER_PUBLIC_IP>/ -H "Host: openclaw.example.com" ; echo

# In a browser: https://openclaw.example.com
#   → Cloudflare Access login → after auth, the OpenClaw Control UI loads,
#     already signed in as your email (no gateway token prompt).
```

Add your LLM provider API keys from inside the Control UI once you're in.

---

## Hardening (recommended, in order of value)

1. **Validate the Access JWT at Caddy**, not just the email header. The email
   header alone is trustworthy *only* because the origin is firewalled to
   Cloudflare. Validating `Cf-Access-Jwt-Assertion` against your team's JWKS
   (`https://<team>.cloudflareaccess.com/cdn-cgi/access/certs`) + the app AUD
   removes reliance on the IP allowlist. Requires a Caddy build with a JWT/auth
   plugin (e.g. `caddy-security`).
2. **Cloudflare Tunnel instead of open ports.** Run `cloudflared` pointed at
   Caddy; the origin then has *no* inbound ports at all and only Cloudflare can
   reach it — this removes the DOCKER-USER firewall complexity entirely and is
   arguably the cleaner design. Say the word and I'll convert this stack to it.
3. **Authenticated Origin Pulls** (mTLS from Cloudflare to your origin) as an
   alternative/additional origin lock.
4. **Pin the OpenClaw image** to a version tag instead of `latest`.
5. `docker compose run --rm --entrypoint openclaw openclaw-gateway security audit`
   — note: this intentionally reports trusted-proxy auth as a *critical* finding
   to remind you that security depends on the proxy/firewall in front.

## Notes & gotchas

- **WebSockets:** the Control UI uses WS; Cloudflare proxied + Access + Caddy
  all pass WebSockets through by default. `allowedOrigins` must exactly match
  your `https://` origin or the WS handshake is rejected.
- **`bind: "all"`** makes the gateway listen on its container interface so Caddy
  can reach it. The port is never published to the host and is firewalled, so
  this is safe here.
- **DNS-01 works behind orange cloud** — Caddy writes a temporary `_acme-challenge`
  TXT record via the API; proxy status doesn't matter for DNS validation.
- **Adding users later:** add their email to the Cloudflare Access policy *and*
  to `allowUsers` in `openclaw.json` (or leave `allowUsers` empty to accept any
  Access-authenticated user).
