#!/usr/bin/env bash
# Render caddy/Caddyfile.tmpl the way caddy/entrypoint.sh does (gomplate, with
# DOCKER_GATEWAY_IP set), into a directory laid out like the caddy container's
# /etc/caddy: the rendered Caddyfile next to the snippet directories caddy.yaml
# mounts, so the template's relative `import`s resolve as they do in production.
#
#   .aidev/caddy-render.sh OUT_DIR [postgres-public]
#
# The environment is the caller's (CADDY_SITES, CADDY_TLS_SELF_SIGNED, ...: see
# caddy.yaml); unset variables take the template's own defaults, and
# DOCKER_GATEWAY_IP defaults to docker's usual 172.17.0.1. `postgres-public` also
# mounts caddy/layer4-postgres-snippets, as postgres-public/compose.postgres-public.yml
# does. Caddy itself substitutes {$VAR} placeholders when it adapts the file, so
# run it with the same environment.
set -euo pipefail
cd "$(dirname "$0")/.." || exit 1

out="${1:?usage: $0 OUT_DIR [postgres-public]}"
variant="${2:-}"
rm -rf "$out"; mkdir -p "$out"
cp -r caddy/snippets caddy/admin-snippets caddy/admin_html "$out/"
mkdir -p "$out/layer4-postgres-snippets"
if [ "$variant" = "postgres-public" ]; then
    cp caddy/layer4-postgres-snippets/*.snippet "$out/layer4-postgres-snippets/"
fi
DOCKER_GATEWAY_IP="${DOCKER_GATEWAY_IP:-172.17.0.1}" \
    gomplate -f caddy/Caddyfile.tmpl -o "$out/Caddyfile"
