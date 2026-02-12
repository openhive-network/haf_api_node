ARG CADDY_VERSION=2.10.2
FROM caddy:${CADDY_VERSION}-builder-alpine AS builder

RUN xcaddy build \
  --with github.com/mholt/caddy-ratelimit \
  --with github.com/caddy-dns/cloudflare@v0.2.1 \
  --with github.com/caddyserver/transform-encoder@47f376e021efdfdf2d47ca716c8f031b4fdfad92 \
  --with github.com/mholt/caddy-l4

FROM caddy:${CADDY_VERSION}-alpine

COPY --from=builder /usr/bin/caddy /usr/bin/caddy

RUN apk add --no-cache gomplate

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["caddy", "run", "--config", "/etc/caddy/Caddyfile", "--adapter", "caddyfile"]
