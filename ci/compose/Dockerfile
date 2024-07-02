# syntax=docker/dockerfile:1.5
FROM registry.gitlab.syncad.com/hive/haf_api_node/docker:26.1.4-cli

ENV HIVE_API_NODE_VERSION=1.27.5 
ENV HIVE_API_NODE_REGISTRY=registry.gitlab.syncad.com/hive \
    HAF_VERSION=${HIVE_API_NODE_VERSION}rc9 \
    HIVEMIND_INSTANCE_VERSION=${HIVE_API_NODE_VERSION}rc9 \
    HAFAH_VERSION=${HIVE_API_NODE_VERSION}rc9 \
    PUBLIC_HOSTNAME="haf_api_node"

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
EOF

COPY --chmod=755 <<EOF entrypoint.sh
#!/bin/bash

set -e

if [[ "\${USE_ALTERNATE_HAPROXY_CONFIG:-}" == "true" ]]; then
  echo "Using alternate HAproxy configuration"
  sed -i.bak -e 's#source: ./haproxy/haproxy.cfg#source: ./haproxy/haproxy-alternate.cfg#' haproxy.yaml
else
  echo "Using default HAproxy configuration"
  [[ -f haproxy.yaml.bak ]] && mv haproxy.yaml.bak haproxy.yaml
fi

if [[ -n "\${FAKETIME:-}" ]]; then
  echo "Enabling faketime for HAF"
  mv faketime.yaml compose.override.yml
else
  echo "Disabling faketime for HAF"
  [[ -f compose.override.yml ]] && mv compose.override.yml faketime.yaml
fi

echo "Waiting for Docker to start..."
until docker-entrypoint.sh docker version &>/dev/null
do 
  echo "Waiting for Docker to start..."
  sleep 10
done

# Necessary for GitLab CI service healthcheck
httpd

docker-entrypoint.sh docker compose "\$@"
EOF

EXPOSE 80

ENTRYPOINT [ "/sbin/tini", "-g", "--", "/haf-api-node/entrypoint.sh" ]
CMD [ "up" ]