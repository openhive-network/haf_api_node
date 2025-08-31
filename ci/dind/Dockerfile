# syntax=docker/dockerfile:1.7-labs
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
COPY --chmod=755 create_directories.sh create_directories.sh
COPY --chmod=755 repair_permissions.sh repair_permissions.sh

COPY --exclude=ci/* \
     --exclude=*.md \
     --exclude=*/*.md \
     --exclude=*.sh \
     --exclude=*/*.sh \
     --exclude=*/*/*.sh \
     --exclude=compose.yml \
     --exclude=*/compose.yml \
     --exclude=*/compose.*.yml \
     --exclude=*.yaml \
     --exclude=*/*.yaml \
     --exclude=zfs.conf \
     --exclude=.env.example \
     --exclude=*/*.js . .

COPY --parents drone/config.yaml .

EXPOSE 2375 2376 80 443

ENTRYPOINT ["/haf-api-node/entrypoint.sh"]
CMD []