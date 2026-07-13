# 3.2 is an LTS branch (supported to ~Q2 2030); 2.9 was a non-LTS branch that
# is already EOL. Note: 3.2 still supports the legacy mailers/email-alert
# config (with a deprecation warning) — 3.3 removes it in favor of the Lua
# mailers, so revisit the email-alert overlay before any 3.3+ upgrade.
FROM haproxy:3.2.21-alpine
# This is just the stock haproxy docker image with the socat utility added, which allows
# you to interact with the admin socket
USER root
RUN apk add --no-cache socat su-exec && mkdir -p /run/haproxy && chown haproxy:haproxy /run/haproxy
COPY docker-entrypoint.sh /usr/local/bin/entrypoint.sh
# Note: We start as root so entrypoint can start syslogd, then drop to haproxy user

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
