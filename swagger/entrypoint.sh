#!/bin/sh
set -e

# allow docker-gen to see Docker API
export DOCKER_HOST=unix:///var/run/docker.sock

# kick off docker-gen: template → swagger‐initializer.js; keep watching
docker-gen \
  -watch \
  /etc/docker-gen/templates/swagger.tmpl \
  /usr/share/nginx/html/swagger-initializer.js &

# finally, start swagger-ui's nginx
exec nginx -g 'daemon off;'
