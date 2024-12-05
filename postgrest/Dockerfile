ARG POSTGREST_VERSION=v12.2.3
FROM postgrest/postgrest:${POSTGREST_VERSION} AS postgrest-base
FROM alpine:latest AS base
COPY --from=postgrest-base /bin/postgrest /bin
USER 1000
CMD [ "/bin/postgrest" ]
