# syntax=docker/dockerfile:1.5
FROM docker:26.1.4-dind

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

COPY --chmod=755 <<EOF entrypoint.sh
#!/bin/sh

set -e 

mkdir -p "\${TOP_LEVEL_DATASET_MOUNTPOINT}/blockchain"
mkdir -p "\${TOP_LEVEL_DATASET_MOUNTPOINT}/shared_memory/haf_wal"
mkdir -p "\${TOP_LEVEL_DATASET_MOUNTPOINT}/logs/caddy"
mkdir -p "\${TOP_LEVEL_DATASET_MOUNTPOINT}/logs/pgbadger"
mkdir -p "\${TOP_LEVEL_DATASET_MOUNTPOINT}/logs/postgresql"

chown -R 1000:100 "\${TOP_LEVEL_DATASET_MOUNTPOINT}"

dockerd-entrypoint.sh "\$@"
EOF

COPY caddy/Caddyfile caddy/Caddyfile
COPY caddy/snippets caddy/snippets
COPY caddy/admin_html caddy/admin_html
COPY caddy/self-signed.snippet caddy/self-signed.snippet
COPY haproxy/haproxy.cfg haproxy/haproxy.cfg
COPY jussi/config.json jussi/config.json
COPY pgadmin/pgpass pgadmin/pgpass
COPY pgadmin/servers.json pgadmin/servers.json
COPY varnish/default.vcl varnish/default.vcl

EXPOSE 2375 2376 80 443

ENTRYPOINT ["/haf-api-node/entrypoint.sh"]
CMD []