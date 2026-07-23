# OpenClaw + Caddy + Cloudflare (Access / trusted-proxy auth)

Self-hosted OpenClaw gateway behind Caddy, with Cloudflare DNS (proxied/orange),
TLS via a **Cloudflare Origin Certificate**, and authentication delegated to
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
| `docker-compose.yml` | Caddy (stock `caddy:2`) + OpenClaw gateway on an isolated bridge network |
| `caddy/Dockerfile` | Optional — only for the Let's Encrypt DNS-01 alternative (not used by default) |
| `caddy/Caddyfile` | TLS (Origin cert) + reverse proxy + Access→header mapping |
| `caddy/certs/` | Drop your Cloudflare Origin cert (`origin.pem`) + key (`origin-key.pem`) here |
| `.env.example` | Domains + Hermes Basic Auth creds (no API token needed with Origin cert) |

> **Running Hermes Agent too?** See [Adding Hermes Agent on a second domain](#adding-hermes-agent-on-a-second-domain) at the bottom. If so, generate your Origin cert as a **wildcard** `*.example.com` in step 2 so it covers both hostnames.
| `openclaw/config/openclaw.snippet.json` | Config template — `cp` it to `openclaw.json` (never read directly by the gateway) |
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
$EDITOR .env                       # set DOMAIN
```

---

## 1. Cloudflare DNS

In the Cloudflare dashboard for your zone → **DNS → Records**:

- Add an **A** record: `openclaw` → your server's public IPv4.
- **Proxy status: Proxied (orange cloud).**

Then **SSL/TLS → Overview → set encryption mode to `Full (strict)`.**
(Caddy will hold a Cloudflare Origin cert, which `Full (strict)` validates.)
Also enable **SSL/TLS → Edge Certificates → Always Use HTTPS**.

## 2. Cloudflare Origin Certificate (for the Cloudflare→Caddy leg)

**SSL/TLS → Origin Server → Create Certificate:**

1. Leave "Generate private key and CSR with Cloudflare" selected.
2. Hostnames: `openclaw.example.com` (or `*.example.com`).
3. Validity: up to 15 years → **Create**.
4. You'll be shown two PEM blocks (the key is shown **only once**):
   - **Origin Certificate** → save to `caddy/certs/origin.pem`
   - **Private Key** → save to `caddy/certs/origin-key.pem`

```bash
mkdir -p caddy/certs
$EDITOR caddy/certs/origin.pem       # paste the Origin Certificate
$EDITOR caddy/certs/origin-key.pem   # paste the Private Key
chmod 600 caddy/certs/origin-key.pem
```

No API token is required for this method.

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

## 5. Create the gateway config

With `OPENCLAW_SKIP_ONBOARDING=1` the gateway does **not** generate a default
config — you supply it. (`gateway.mode` defaults to `remote`, which requires auth;
without a config it exits 78 "Missing config".) Create `openclaw.json` from the
provided snippet:

```bash
sudo cp openclaw/config/openclaw.snippet.json openclaw/config/openclaw.json
sudo nano openclaw/config/openclaw.json      # edit the values below
sudo chown 1000:1000 openclaw/config/openclaw.json
```

The file **must** be named exactly `openclaw.json` — the gateway ignores any other
name (e.g. `openclaw.gateway.json`) and silently falls back to defaults (`bind=auto`,
no auth config), which surfaces later as confusing "no trustedProxy config" errors.
Edit these values:

- `controlUi.allowedOrigins` → `["https://<your OpenClaw domain>"]` (exact, with `https://`; the key is under `gateway.controlUi`, **not** `gateway.allowedOrigins`)
- `trustedProxies` → keep `["172.28.0.2/32"]` (Caddy's fixed IP from compose)

The `trustedProxy` block is intentionally minimal (`userHeader` only) — it validates
cleanly, and Cloudflare Access already restricts *who* can reach the gateway. Optional
extras like `allowUsers` / `deviceAutoApprove` have build-specific schemas; add them
only after confirming shapes with `docker compose run --rm --no-deps openclaw-gateway
node openclaw.mjs doctor`.

`gateway.auth.mode: "trusted-proxy"` supplies the auth, so no gateway token is
needed — and it must **not** be set (the two are mutually exclusive).

## 6. Start & verify the gateway

```bash
docker compose up -d
docker compose logs -f openclaw-gateway
```

Expect `loading configuration… → resolving authentication…` then serving on `:18789`.

- **`Missing config … exit 78`** → remote mode otherwise wants the interactive
  `openclaw setup`; the compose `command:` includes `--allow-unconfigured` to bypass
  that and use your `openclaw.json` instead. Make sure that flag is present, and that
  `openclaw.json` exists at `openclaw/config/openclaw.json`, is valid JSON, and is
  readable by uid 1000.
- **`[FATAL tini (7)] exec <x> failed`** → you passed a bare subcommand. The CLI is
  `node openclaw.mjs <subcommand>` (entrypoint is tini), e.g.
  `docker compose run --rm --no-deps openclaw-gateway node openclaw.mjs doctor`.
- **`EACCES … mkdir '/home/node/.openclaw/state'`** → dir ownership; rerun
  `sudo chown -R 1000:1000 openclaw/config openclaw/secret`.
- **Token error** → ensure `OPENCLAW_GATEWAY_TOKEN` is not set and
  `gateway.auth.token` is not in `openclaw.json` (mutually exclusive with trusted-proxy).

## 7. Lock the origin to Cloudflare (REQUIRED)

Because the gateway trusts a header, an exposed origin = full auth bypass.
Docker bypasses `ufw`, so the script filters the `DOCKER-USER` chain. Install it
as a systemd unit so it re-applies at boot **and** whenever the Docker daemon
restarts (Docker rebuilds its chains each time it starts):

```bash
# 1. Install the script and the unit
sudo install -m 0755 scripts/lock-origin-to-cloudflare.sh /usr/local/sbin/lock-origin-to-cloudflare.sh
sudo install -m 0644 scripts/cloudflare-lock.service /etc/systemd/system/cloudflare-lock.service

# 2. Enable + run now (and on every boot, ordered after docker.service)
sudo systemctl daemon-reload
sudo systemctl enable --now cloudflare-lock.service

# 3. Verify
systemctl status cloudflare-lock.service --no-pager
sudo iptables -S DOCKER-USER          # should list Cloudflare ranges then a DROP on :443
```

> **Don't** use `iptables-persistent` / `netfilter-persistent save` on a Docker
> host — restoring a saved snapshot conflicts with Docker's dynamically-created
> chains and can break container networking. The systemd unit above rebuilds the
> rules fresh against the live chain instead, which is conflict-free. To refresh
> Cloudflare's IP list later: `sudo systemctl restart cloudflare-lock.service`.

### Host / SSH firewall (Contabo network firewall)

SSH and general host-port filtering are handled at the **Contabo firewall**
(upstream of the server), not `ufw`. That's the better layer: a provider network
firewall sits *in front of* the host, so — unlike `ufw` — it is **not** bypassed by
Docker's iptables rules.

- **`ufw` is not needed** for this stack and is best left disabled. (The only host
  port was SSH, which Contabo gates; Caddy's 80/443 are Docker-published and bypass
  `ufw` anyway.) Note: if you *did* enable `ufw`, you'd still need an explicit
  `allow 22` rule on the host — `ufw` runs on the host *after* Contabo, so a
  default-deny would drop SSH even though Contabo permitted it. Skipping `ufw`
  avoids that lockout risk.
- **In the Contabo firewall, make sure inbound `tcp/443` is allowed** so Cloudflare
  can reach the origin (allow from Cloudflare's ranges, or from anywhere and let
  `cloudflare-lock.service` do the filtering). Port 80 to the origin is **not**
  needed — you're using a Cloudflare Origin cert (no ACME), and Cloudflare does
  http→https at the edge.
- **SSH:** allow `tcp/22` from your admin IP only, in the Contabo firewall.
- Optional extra layer: you *can* also restrict `443` to Cloudflare ranges at the
  Contabo firewall, but those ranges change and Contabo rules are manual — so keep
  `cloudflare-lock.service` (auto-updating) as the primary lock and treat Contabo
  as a coarse backstop.

## 8. Verify

```bash
# From a machine that is NOT Cloudflare — should hang/refuse (origin locked):
curl -m 5 -k https://<SERVER_PUBLIC_IP>/ -H "Host: openclaw.example.com" ; echo

# In a browser: https://openclaw.example.com
#   → Cloudflare Access login → after auth, the OpenClaw Control UI loads,
#     already signed in as your email (no gateway token prompt).
```

Add your LLM provider API keys from inside the Control UI once you're in.

## 9. Auto-start on boot (systemd)

Two mechanisms, two jobs:

- **`restart: unless-stopped`** (already set on every service) recovers containers
  when the Docker daemon restarts or a container crashes. Make sure Docker itself
  starts at boot: `sudo systemctl enable docker`.
- **`openclaw-stack.service`** guarantees the stack is brought up at boot and gives
  you one-command control of the whole project.

```bash
sudo mv ~/openclaw-caddy /opt/openclaw-caddy    # stable path (edit WorkingDirectory if different)
sudo install -m 0644 /opt/openclaw-caddy/scripts/openclaw-stack.service /etc/systemd/system/openclaw-stack.service
sudo systemctl daemon-reload
sudo systemctl enable --now openclaw-stack.service
sudo systemctl status openclaw-stack.service --no-pager
```

The `cloudflare-lock.service` (§7) and `openclaw-stack.service` are independent —
the firewall rules filter by port and don't depend on the containers being up, so
ordering between them doesn't matter.

---

## Adding Hermes Agent on a second domain

Hermes Agent (`nousresearch/hermes-agent`) is a **separate** agent framework, not
part of OpenClaw. This stack already includes a `hermes` service; you just enable
the domain and auth. The whole edge layer (Cloudflare proxy, Origin cert, Caddy,
origin firewall) is shared — no changes to `lock-origin-to-cloudflare.sh` needed
since both domains ride the same Caddy `:443`.

**Key difference from OpenClaw:** Hermes has **no trusted-proxy header auth**. Its
dashboard requires Basic Auth / Nous OAuth / OIDC and fails closed on a non-loopback
bind without one. So we protect it with **two layers**:

1. **Cloudflare Access** at the edge (the real SSO gate) — same as OpenClaw.
2. **Hermes Basic Auth** (set via `HERMES_USER` / `HERMES_PASSWORD` in `.env`) — satisfies
   Hermes' fail-closed rule and adds defense-in-depth if the edge is ever bypassed.

Steps:

1. **Cert:** in step 2, create the Cloudflare Origin cert for `*.example.com` (wildcard)
   so the one `origin.pem` covers both `openclaw.` and `hermes.`. (If you already made a
   single-host cert, regenerate it as a wildcard.)
2. **DNS:** add an **A** record `hermes` → your server IP, **Proxied (orange)**.
3. **Access:** create a *second* Zero Trust → Access → Self-hosted application for
   `hermes.example.com`, with its own Allow policy (your email). (Same as §3.)
4. **`.env`:** set `HERMES_DOMAIN`, `HERMES_USER`, `HERMES_PASSWORD`.
5. **Verify the dashboard bind knob.** The compose sets `HERMES_DASHBOARD=1` +
   `HERMES_DASHBOARD_HOST=0.0.0.0` so Caddy can reach it. Confirm the exact flag/env
   with `docker run --rm nousresearch/hermes-agent:latest gateway run --help`. If it
   differs, override the service `command:` instead, e.g.
   `command: dashboard --host 0.0.0.0 --port 9119 --no-open`.
6. **Start:** `docker compose up -d hermes && docker compose logs -f hermes`
   (watch for the dashboard listening on `0.0.0.0:9119`, no fail-closed error).
7. Browse to `https://hermes.example.com` → Cloudflare Access login → then the Hermes
   Basic Auth prompt → dashboard. Add your LLM provider key in Hermes' config afterward.

> **UX note:** you log in twice (Access, then Basic Auth). To get single sign-on and
> drop the second prompt, use Hermes' **OIDC** provider with Cloudflare Access as the
> IdP (`HERMES_DASHBOARD_OIDC_ISSUER` / `_OIDC_CLIENT_ID` / `_OIDC_SCOPES`, created as an
> Access "SaaS → OIDC" application). More setup, but true SSO.

Sources: [Hermes web dashboard docs](https://hermes-agent.nousresearch.com/docs/user-guide/features/web-dashboard) ·
[Hermes configuration](https://github.com/NousResearch/hermes-agent/blob/main/website/docs/user-guide/configuration.md)

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
- **`bind: "lan"`** makes the gateway listen on its private/LAN container interface
  (`172.28.0.3`) so Caddy can reach it. Valid values are `loopback`, `lan`, `tailnet`,
  `auto`, `custom` — **not** `all`. The port is never published to the host and is
  firewalled, so `lan` is safe here.
- **Origin cert requires the proxy ON** — a Cloudflare Origin cert is trusted
  only by Cloudflare, so it works precisely because your record is proxied
  (orange). This is the same proxy setting Access needs, so they align.
  Cloudflare SSL mode **must** be `Full (strict)` (not Flexible — Flexible would
  talk plain HTTP to your origin and break the `tls` directive).
- **Adding users later:** add their email to the Cloudflare Access policy *and*
  to `allowUsers` in `openclaw.json` (or leave `allowUsers` empty to accept any
  Access-authenticated user).
