# Custom Caddy build that includes the Cloudflare DNS provider,
# required for the DNS-01 ACME challenge (works behind an orange-cloud record).
FROM caddy:2-builder AS builder
RUN xcaddy build --with github.com/caddy-dns/cloudflare

FROM caddy:2
COPY --from=builder /usr/bin/caddy /usr/bin/caddy
