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
COPY --chmod=755 ci/scripts/prepare-stack-data-directory.sh prepare-stack-data-directory.sh

COPY balance_tracker/balance_tracker_nginx.conf balance_tracker/balance_tracker_nginx.conf
COPY balance_tracker/rewrite_rules.conf balance_tracker/rewrite_rules.conf
COPY caddy/Caddyfile caddy/Caddyfile
COPY caddy/snippets caddy/snippets
COPY caddy/admin_html caddy/admin_html
COPY caddy/self-signed.snippet caddy/self-signed.snippet
COPY haf_block_explorer/haf_block_explorer_nginx.conf haf_block_explorer/haf_block_explorer_nginx.conf
COPY haf_block_explorer/rewrite_rules.conf haf_block_explorer/rewrite_rules.conf
COPY hafah_rest/hafah_rest_nginx.conf hafah_rest/hafah_rest_nginx.conf
COPY hafah_rest/rewrite_rules.conf hafah_rest/rewrite_rules.conf
COPY haproxy/haproxy.cfg haproxy/haproxy.cfg
COPY haproxy/haproxy-alternate.cfg haproxy/haproxy-alternate.cfg
COPY hivemind_rtracker/hivemind_rtracker_nginx.conf hivemind_rtracker/hivemind_rtracker_nginx.conf
COPY hivemind_rtracker/rewrite_rules.conf hivemind_rtracker/rewrite_rules.conf
COPY jussi/config.json jussi/config.json
COPY logrotate/logrotate.d/postgresql-common logrotate/logrotate.d/postgresql-common
COPY monitoring/ .
COPY pgadmin/pgpass pgadmin/pgpass
COPY pgadmin/servers.json pgadmin/servers.json
COPY reputation_tracker/reputation_tracker_nginx.conf reputation_tracker/reputation_tracker_nginx.conf
COPY reputation_tracker/rewrite_rules.conf reputation_tracker/rewrite_rules.conf
COPY varnish/default.vcl varnish/default.vcl

EXPOSE 2375 2376 80 443

ENTRYPOINT ["/haf-api-node/entrypoint.sh"]
CMD []