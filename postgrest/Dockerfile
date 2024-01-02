ARG POSTGREST_VERSION=v12.0.2
FROM postgrest/postgrest:${POSTGREST_VERSION} AS postgrest-base
FROM alpine:latest AS base
COPY --from=postgrest-base /bin/postgrest /bin
USER 1000
CMD [ "/bin/postgrest" ]
