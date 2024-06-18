# syntax=docker/dockerfile:1.5
FROM registry.gitlab.syncad.com/hive/haf_api_node/docker:26.1.4-cli

ENV HIVE_API_NODE_VERSION=1.27.5 
ENV HIVE_API_NODE_REGISTRY=registry.gitlab.syncad.com/hive \
    HAF_VERSION=${HIVE_API_NODE_VERSION}rc9 \
    HIVEMIND_INSTANCE_VERSION=${HIVE_API_NODE_VERSION}rc9 \
    HAFAH_VERSION=${HIVE_API_NODE_VERSION}rc9 \
    PUBLIC_HOSTNAME="haf_api_node" \
    TOP_LEVEL_DATASET_MOUNTPOINT=/haf-pool/haf-datadir \
    COMPOSE_PROFILES="core,admin,hafah,hivemind,servers"

RUN <<EOF
set -e

apk add --no-cache tini busybox-extras curl bash jq
EOF

WORKDIR /haf-api-node

COPY ci/scripts /haf-api-node/ci/scripts
COPY *.yaml /haf-api-node/
COPY compose.yml compose.yml
COPY .env.example .env

COPY --chmod=644 <<EOF index.html
<!doctype html>
<html><body><h1>A webpage served by netcat</h1></body></html>
EOF

COPY --chmod=644 <<EOF faketime.yaml
services:
  haf:
    environment:
      FAKETIME:
      LD_PRELOAD: "/home/hived_admin/hive_base_config/faketime/src/libfaketime.so.1"
      OVERRIDE_LD_PRELOAD: "/home/hived_admin/hive_base_config/faketime/src/libfaketime.so.1"
      FAKETIME_DONT_FAKE_MONOTONIC: 1
      FAKETIME_DONT_RESET: 1
      TZ: "UTC"
EOF

COPY --chmod=755 ci/compose/entrypoint.sh entrypoint.sh

EXPOSE 80

ENTRYPOINT [ "/sbin/tini", "-g", "--", "/haf-api-node/entrypoint.sh" ]
CMD [ "up", "--quiet-pull" ]