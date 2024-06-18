# syntax=docker/dockerfile:1.5
FROM docker:26.1.4-cli

ENV HIVE_API_NODE_VERSION=1.27.5 
ENV HIVE_API_NODE_REGISTRY=registry.gitlab.syncad.com/hive \
    HAF_VERSION=${HIVE_API_NODE_VERSION}rc9 \
    HIVEMIND_INSTANCE_VERSION=${HIVE_API_NODE_VERSION}rc9 \
    HAFAH_VERSION=${HIVE_API_NODE_VERSION}rc9 \
    PUBLIC_HOSTNAME="haf_api_node"

RUN <<-EOF
    set -e

    mkdir /haf-api-node
EOF

WORKDIR /haf-api-node

COPY . .

RUN cp .env.example .env

ENTRYPOINT [ "docker-entrypoint.sh", "docker", "compose" ]
CMD [ "up" ]