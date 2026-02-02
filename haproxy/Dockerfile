FROM haproxy:2.9.7-alpine
# This is just the stock haproxy docker image with the socat utility added, which allows
# you to interact with the admin socket
USER root
RUN apk add --no-cache socat su-exec && mkdir -p /run/haproxy && chown haproxy:haproxy /run/haproxy
COPY docker-entrypoint.sh /usr/local/bin/entrypoint.sh
# Note: We start as root so entrypoint can start syslogd, then drop to haproxy user

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
