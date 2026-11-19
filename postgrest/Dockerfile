# Note: upstream binaries are built with -with-rtsopts="-N -I0 -qg"; -qg
# DISABLES parallel GC, so major collections are single-threaded and pause
# the whole server for the duration (seconds on a multi-GB heap under load).
# The binary is built with -rtsopts, so runtime GC behavior can be tuned per
# service via the GHCRTS env var (e.g. GHCRTS=--nonmoving-gc) — see
# .env.example "HIVEMIND_POSTGREST_GHCRTS".
ARG POSTGREST_VERSION=v14.15
FROM postgrest/postgrest:${POSTGREST_VERSION} AS postgrest-base
FROM registry.gitlab.syncad.com/hive/haf_api_node/alpine:3.22.1 AS base
# psql for entrypoint.sh, which holds the app's HAF lock while the API serves (HAF_APP_LOCK)
RUN apk add --no-cache postgresql17-client
COPY --from=postgrest-base /bin/postgrest /bin
COPY --chmod=0755 entrypoint.sh /usr/local/bin/postgrest-entrypoint.sh
USER 1000
ENTRYPOINT [ "/usr/local/bin/postgrest-entrypoint.sh" ]
CMD [ "/bin/postgrest" ]
