#!/bin/bash

set -e

if [[ "${USE_ALTERNATE_HAPROXY_CONFIG:-}" == "true" ]]; then
  echo "Enabling alternate HAproxy configuration..."
  sed -i.bak -e 's#source: ./haproxy/haproxy.cfg#source: ./haproxy/haproxy-alternate.cfg#' /haf-api-node/haproxy.yaml
else
  echo "Enabling default HAproxy configuration..."
  [[ -f /haf-api-node/haproxy.yaml.bak ]] && mv -v /haf-api-node/haproxy.yaml.bak /haf-api-node/haproxy.yaml
fi

if [[ -n "${FAKETIME:-}" ]]; then
  echo "Enabling faketime for HAF..."
  mv /haf-api-node/faketime.yaml /haf-api-node/compose.override.yml
else
  echo "Disabling faketime for HAF..."
  [[ -f /haf-api-node/compose.override.yml ]] && mv -v /haf-api-node/compose.override.yml /haf-api-node/faketime.yaml
fi

# Without explicit exit command, the code returned by the script is the return code 
# of the last command executed, which might be non-zero even
# if the command executed successfully
exit 0