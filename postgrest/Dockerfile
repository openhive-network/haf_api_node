ARG POSTGREST_VERSION=v12.2.3
FROM postgrest/postgrest:${POSTGREST_VERSION} AS postgrest-base
FROM registry.gitlab.syncad.com/hive/haf_api_node/alpine:3.22.1 AS base
COPY --from=postgrest-base /bin/postgrest /bin
USER 1000
CMD [ "/bin/postgrest" ]
