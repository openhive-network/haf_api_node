#!/bin/bash

#!/bin/bash

set -e

if [[ "${USE_ALTERNATE_HAPROXY_CONFIG:-}" == "true" ]]; then
  echo "Using alternate HAproxy configuration"
  sed -i.bak -e 's#source: ./haproxy/haproxy.cfg#source: ./haproxy/haproxy-alternate.cfg#' haproxy.yaml
else
  echo "Using default HAproxy configuration"
  [[ -f haproxy.yaml.bak ]] && mv haproxy.yaml.bak haproxy.yaml
fi

if [[ -n "${FAKETIME:-}" ]]; then
  echo "Enabling faketime for HAF"
  mv faketime.yaml compose.override.yml
else
  echo "Disabling faketime for HAF"
  [[ -f compose.override.yml ]] && mv compose.override.yml faketime.yaml
fi

echo "Waiting for Docker to start..."
until docker-entrypoint.sh docker version &>/dev/null
do 
  echo "Waiting for Docker to start..."
  sleep 10
done

# Necessary for GitLab CI service healthcheck
httpd

docker-entrypoint.sh docker compose "$@"