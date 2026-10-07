# The image AIDEV runs this project's checks in (`environment.image` in
# .aidev/project.yaml). Checks run with `--network none` and the caller's uid, so
# every tool is in the image, taken from the images the project's own CI uses:
#
#   alpine:3.22.1 (lint-shellcheck's image) + shellcheck from its apk repository,
#   python3 + PyYAML (check-log-rotation), the dclint binary from the dclint image
#   lint-docker-compose runs, and caddy + gomplate from the project's own caddy
#   image (docker-build's `caddy` target: caddy 2.11 with the rate_limit, layer4
#   and transform-encoder plugins the Caddyfile needs). py3-zstandard lets the
#   Caddy smoke test decode zstd responses.
#
# Build and pin it with .aidev/runtime/build.sh; see .aidev/README.md.
FROM registry.gitlab.syncad.com/hive/haf_api_node/caddy@sha256:014c5a0440ca23689ca24e0aed1e7ed28396e46e066f78970148232bbe3cc614 AS caddy
FROM registry.gitlab.syncad.com/hive/haf_api_node/dclint@sha256:270b9f84fdcd5abe6d80f08dbe06ac2971004a78156ee34e984a99fa9b44a2eb AS dclint

FROM registry.gitlab.syncad.com/hive/haf_api_node/alpine@sha256:7b9b6a044d921dfcaea2a843ff19d725948590352198f93cb878fd2c19d7ba3c

RUN apk add --no-cache bash shellcheck python3 py3-yaml py3-zstandard

COPY --from=dclint /bin/dclint /usr/local/bin/dclint
COPY --from=caddy /usr/bin/caddy /usr/local/bin/caddy
COPY --from=caddy /usr/bin/gomplate /usr/local/bin/gomplate

ENV HOME=/tmp \
    XDG_DATA_HOME=/tmp/xdg-data \
    XDG_CONFIG_HOME=/tmp/xdg-config \
    NODE_NO_WARNINGS=1
