# OPTIONAL / ALTERNATIVE TLS METHOD.
# You do NOT need this with the Cloudflare Origin Certificate approach (the
# default in docker-compose.yml, which uses the stock caddy:2 image).
#
# Use this only if you prefer Let's Encrypt certs via the Cloudflare DNS-01
# challenge instead. To switch:
#   1. In docker-compose.yml, replace `image: caddy:2` on the caddy service with:
#        build:
#          context: ./caddy
#        image: caddy-cloudflare:local
#      and add `CLOUDFLARE_API_TOKEN: ${CLOUDFLARE_API_TOKEN}` under environment.
#   2. In caddy/Caddyfile, replace the `tls <cert> <key>` line with:
#        tls {
#          dns cloudflare {env.CLOUDFLARE_API_TOKEN}
#          resolvers 1.1.1.1 1.0.0.1
#        }
#   3. Set CLOUDFLARE_API_TOKEN in .env (Zone:DNS:Edit + Zone:Read).
FROM caddy:2-builder AS builder
RUN xcaddy build --with github.com/caddy-dns/cloudflare

FROM caddy:2
COPY --from=builder /usr/bin/caddy /usr/bin/caddy
