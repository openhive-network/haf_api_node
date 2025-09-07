FROM registry.gitlab.syncad.com/hive/haf_api_node/alpine:3.22.1

# Install packages in a single layer for better caching
# pgbouncer: connection pooler
# postgresql-client: provides pg_isready for healthchecks
RUN apk add --no-cache \
    pgbouncer \
    postgresql-client && \
    # Create pgbouncer user and directories
    adduser -D -s /bin/sh pgbouncer && \
    mkdir -p /etc/pgbouncer /var/log/pgbouncer /var/run/pgbouncer && \
    chown -R pgbouncer:pgbouncer /etc/pgbouncer /var/log/pgbouncer /var/run/pgbouncer

# Copy entrypoint script (do this after package installation for better caching)
COPY --chown=pgbouncer:pgbouncer docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

USER pgbouncer
WORKDIR /etc/pgbouncer

ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]