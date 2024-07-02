# syntax=docker/dockerfile:1.5
FROM registry.gitlab.syncad.com/hive/haf_api_node/docker:26.1.4-dind

ENV TOP_LEVEL_DATASET_MOUNTPOINT=/haf-pool/haf-datadir

RUN <<-EOF
    set -e

    mkdir -p /haf-api-node/caddy/snippets
    mkdir -p /haf-api-node/caddy/admin_html
    mkdir -p /haf-api-node/jussi
    mkdir -p /haf-api-node/pgadmin
    mkdir -p /haf-api-node/varnish
EOF

WORKDIR /haf-api-node

COPY --chmod=755 ci/dind/entrypoint.sh entrypoint.sh

COPY caddy/Caddyfile caddy/Caddyfile
COPY caddy/snippets caddy/snippets
COPY caddy/admin_html caddy/admin_html
COPY caddy/self-signed.snippet caddy/self-signed.snippet
COPY haproxy/haproxy.cfg haproxy/haproxy.cfg
COPY haproxy/haproxy-alternate.cfg haproxy/haproxy-alternate.cfg
COPY jussi/config.json jussi/config.json
COPY pgadmin/pgpass pgadmin/pgpass
COPY pgadmin/servers.json pgadmin/servers.json
COPY varnish/default.vcl varnish/default.vcl

EXPOSE 2375 2376 80 443

ENTRYPOINT ["/haf-api-node/entrypoint.sh"]
CMD []