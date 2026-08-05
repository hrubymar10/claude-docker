#!/bin/bash
set -euo pipefail

ALLOWED="ps logs inspect stats top compose start stop restart kill pause unpause exec images network volume port attach version info login logout pull build buildx"

cmd="${1:-}"

if [[ "$cmd" == "--version" || "$cmd" == "--help" ]]; then
  exec /usr/libexec/docker-real/docker "$@"
fi

warn_sandbox_image_tag() {
  local ref=$1 repository last_component
  repository=${ref%%@*}
  last_component=${repository##*/}
  if [[ "$last_component" == *:* ]]; then
    repository=${repository%:*}
  fi
  case "$repository" in
    claude-docker|codex-docker|pi-docker|vibe-docker)
      echo "WARNING: building tag '$ref' overwrites a sandbox's own image; the next session may run what you build" >&2
      ;;
  esac
}

warn_sandbox_image_tags() {
  local arg expect_tag=false
  for arg in "$@"; do
    if [[ "$expect_tag" == true ]]; then
      warn_sandbox_image_tag "$arg"
      expect_tag=false
      continue
    fi
    case "$arg" in
      -t|--tag) expect_tag=true ;;
      --tag=*) warn_sandbox_image_tag "${arg#--tag=}" ;;
      -t?*) warn_sandbox_image_tag "${arg#-t}" ;;
    esac
  done
}

if [[ "$cmd" == "build" || "$cmd" == "buildx" ]]; then
  warn_sandbox_image_tags "$@"
fi

for allowed in $ALLOWED; do
  if [[ "$cmd" == "$allowed" ]]; then
    exec /usr/libexec/docker-real/docker "$@"
  fi
done

echo "docker $cmd is blocked inside this container (allowed: $ALLOWED)" >&2
exit 1
