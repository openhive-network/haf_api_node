#!/bin/sh
set -e

# Detect Docker gateway IPs (how host connections appear to the container)
DOCKER_GATEWAY_IP=$(ip route | grep default | awk '{print $3}')
export DOCKER_GATEWAY_IP
echo "Detected Docker gateway IP (IPv4): ${DOCKER_GATEWAY_IP}"

# Detect IPv6 gateway if available
DOCKER_GATEWAY_IP6=$(ip -6 route 2>/dev/null | grep default | awk '{print $3}' | head -1)
if [ -n "$DOCKER_GATEWAY_IP6" ]; then
    export DOCKER_GATEWAY_IP6
    echo "Detected Docker gateway IP (IPv6): ${DOCKER_GATEWAY_IP6}"
fi

# Process the Caddyfile template
if [ -f /etc/caddy/Caddyfile.tmpl ]; then
    echo "Processing Caddyfile template..."
    gomplate -f /etc/caddy/Caddyfile.tmpl -o /etc/caddy/Caddyfile
    echo "Caddyfile generated"
fi

exec "$@"
