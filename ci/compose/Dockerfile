# syntax=docker/dockerfile:1.5
FROM registry.gitlab.syncad.com/hive/haf_api_node/docker:26.1.4-cli

ENV TOP_LEVEL_DATASET_MOUNTPOINT=/haf-pool/haf-datadir \
    COMPOSE_PROFILES="core,admin,hafah,hivemind,servers"

RUN <<EOF
set -e

apk add --no-cache tini busybox-extras curl bash jq
EOF

WORKDIR /haf-api-node

COPY ci/scripts /haf-api-node/ci/scripts
COPY ci/config.ini /haf-api-node/ci/config.ini
COPY *.yaml /haf-api-node/
COPY compose.yml compose.yml
COPY .env.example .env

# Disable Hivemind's healthcheck since it randomly breaks the stack and is not necessary
# for CI
RUN <<EOF
sed -i.bak -e 's/test.*block-processing-healthcheck.*/test: ["CMD-SHELL","true"]/' hivemind.yaml
EOF

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