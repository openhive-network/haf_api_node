#!/bin/bash

set -e

if [[ -n "${FAKETIME:-}" ]]; then
  echo "Enabling faketime for HAF..."
  [[ ! -e /haf-api-node/compose.override.yml ]] && mv /haf-api-node/faketime.yaml /haf-api-node/compose.override.yml
else
  echo "Disabling faketime for HAF..."
  [[ -f /haf-api-node/compose.override.yml ]] && mv -v /haf-api-node/compose.override.yml /haf-api-node/faketime.yaml
fi

# Without explicit exit command, the code returned by the script is the return code 
# of the last command executed, which might be non-zero even
# if the command executed successfully
exit 0