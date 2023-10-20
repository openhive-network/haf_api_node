ARG CADDY_VERSION=2.7.5
FROM caddy:${CADDY_VERSION}-builder-alpine AS builder

RUN xcaddy build \
  --with github.com/mholt/caddy-ratelimit \
  --with github.com/caddy-dns/cloudflare

FROM caddy:${CADDY_VERSION}-alpine

COPY --from=builder /usr/bin/caddy /usr/bin/caddy
