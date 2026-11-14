# PgBouncer is built from source with libevent's DNS resolver (evdns) instead of
# Alpine's package, which links c-ares.  c-ares >= 1.31 enables a query cache by
# default that honours the record TTL, PgBouncer does not disable it, and
# Docker's embedded DNS answers container names with a TTL of 600 s.  So after
# `haf` restarts on a new address PgBouncer kept connecting to the old one for
# up to ten minutes, whatever dns_max_ttl said.  evdns keeps no cache of its
# own, so dns_max_ttl bounds how long a stale address is used.
ARG PGBOUNCER_VERSION=1.25.1
ARG PGBOUNCER_SHA256=6e566ae92fe3ef7f6a1b9e26d6049f7d7ca39c40e29e7b38f6d5500ae15d8465

FROM registry.gitlab.syncad.com/hive/haf_api_node/alpine:3.23.5 AS builder
ARG PGBOUNCER_VERSION
ARG PGBOUNCER_SHA256
RUN apk add --no-cache build-base pkgconf libevent-dev openssl-dev
WORKDIR /src
RUN wget -q -O pgbouncer.tar.gz "https://www.pgbouncer.org/downloads/files/${PGBOUNCER_VERSION}/pgbouncer-${PGBOUNCER_VERSION}.tar.gz" && \
    echo "${PGBOUNCER_SHA256}  pgbouncer.tar.gz" | sha256sum -c - && \
    tar -xzf pgbouncer.tar.gz --strip-components=1 && \
    # musl has no int64 typedef (Alpine carries the same fix as fix-int64-musl.patch)
    sed -i 's/(int64) v >= 0/(int64_t) v >= 0/' include/common/simd.h && \
    ./configure --prefix=/usr --disable-debug --without-cares && \
    make -j"$(nproc)" pgbouncer && \
    ./pgbouncer --version | grep -q '^adns: evdns2$'

FROM registry.gitlab.syncad.com/hive/haf_api_node/alpine:3.23.5

# Install packages in a single layer for better caching
# libevent, libssl3: pgbouncer's runtime libraries
# postgresql-client: provides pg_isready for healthchecks
RUN apk add --no-cache \
    libevent \
    libssl3 \
    postgresql-client && \
    # Create pgbouncer user and directories
    adduser -D -s /bin/sh pgbouncer && \
    mkdir -p /etc/pgbouncer /var/log/pgbouncer /var/run/pgbouncer && \
    chown -R pgbouncer:pgbouncer /etc/pgbouncer /var/log/pgbouncer /var/run/pgbouncer

COPY --from=builder /src/pgbouncer /usr/bin/pgbouncer

# Copy entrypoint script (do this after package installation for better caching)
COPY --chown=pgbouncer:pgbouncer docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

USER pgbouncer
WORKDIR /etc/pgbouncer

ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
