FROM alpine:latest AS spoa-builder
RUN apk add --no-cache build-base git autoconf automake curl-dev libev-dev pkgconfig
RUN mkdir /build
WORKDIR /build
RUN git clone https://github.com/haproxytech/spoa-mirror.git
WORKDIR /build/spoa-mirror
RUN ./scripts/bootstrap
RUN ./configure
RUN make all
RUN strip src/spoa-mirror

FROM haproxy:3.0.6-alpine AS runtime
# This is just the stock haproxy docker image with the socat utility added, which allows
# you to interact with the admin socket
USER root
RUN apk add --no-cache socat libcurl libev && mkdir -p /run/haproxy && chown haproxy:haproxy /run/haproxy
COPY --from=spoa-builder /build/spoa-mirror/src/spoa-mirror /usr/bin/spoa-mirror
USER haproxy
