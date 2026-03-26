#!/bin/bash
set -euo pipefail

ALLOWED="ps logs inspect stats top compose start stop restart kill pause unpause exec images network volume port attach version info login logout pull buildx"

cmd="${1:-}"

if [[ "$cmd" == "--version" || "$cmd" == "--help" ]]; then
  exec /usr/bin/docker "$@"
fi

for allowed in $ALLOWED; do
  if [[ "$cmd" == "$allowed" ]]; then
    exec /usr/bin/docker "$@"
  fi
done

echo "docker $cmd is blocked inside this container (allowed: $ALLOWED)" >&2
exit 1
