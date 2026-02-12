#!/bin/sh
set -e

# Detect Docker gateway IP (how host connections appear to the container)
DOCKER_GATEWAY_IP=$(ip route | grep default | awk '{print $3}')
export DOCKER_GATEWAY_IP
echo "Detected Docker gateway IP: ${DOCKER_GATEWAY_IP}"

# Process the Caddyfile template
if [ -f /etc/caddy/Caddyfile.tmpl ]; then
    echo "Processing Caddyfile template..."
    gomplate -f /etc/caddy/Caddyfile.tmpl -o /etc/caddy/Caddyfile
    echo "Caddyfile generated"
fi

exec "$@"
