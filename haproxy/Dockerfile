FROM haproxy:2.9.7-alpine
# This is just the stock haproxy docker image with the socat utility added, which allows
# you to interact with the admin socket
USER root
RUN apk add --no-cache socat && mkdir -p /run/haproxy && chown haproxy:haproxy /run/haproxy
USER haproxy
