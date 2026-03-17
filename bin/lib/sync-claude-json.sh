# Shared helper: sync container's .claude.json back to host.
# Sourced by bin/claude-docker and bin/claude-docker-vscode-wrapper.
#
# Semantics: last-writer-wins. When multiple sessions run concurrently,
# each syncs its own final state back to the host on exit. The lock
# serialises the write-back so the file is never partially written, but
# the last session to finish will overwrite earlier ones. This is an
# acceptable trade-off for a developer tool — corruption is prevented,
# though concurrent sessions may lose each other's state.

# Must match the mount target in docker-compose.yml and the path used
# by scripts/entrypoint.sh (CLAUDE_JSON_HOST="/run/.claude.json.host").
_SYNC_USER="${CLAUDE_DOCKER_USER:-$(whoami)}"
if [[ ! "$_SYNC_USER" =~ ^[a-zA-Z0-9_.-]+$ ]]; then
  echo "Error: CLAUDE_DOCKER_USER contains invalid characters: $_SYNC_USER" >&2
  return 1 2>/dev/null || exit 1
fi
CLAUDE_JSON="/Users/${_SYNC_USER}/.claude.json"
CLAUDE_JSON_LOCK="/tmp/.claude-docker-json.lock"

# Portable exclusive file lock on FD 200.
# flock(1) is Linux-only; lockf(1) is the macOS equivalent.
_acquire_lock() {
  local timeout="$1"
  if command -v flock >/dev/null 2>&1; then
    flock -w "$timeout" 200
  elif command -v lockf >/dev/null 2>&1; then
    lockf -t "$timeout" 200
  else
    echo "Warning: no file locking available (flock/lockf not found); proceeding without lock" >&2
    return 0
  fi
}

sync_claude_json() {
  local container="$1"
  (
    if ! _acquire_lock 5; then
      echo "Warning: could not acquire .claude.json sync lock after 5s, skipping sync" >&2
      exit 0
    fi
    local tmp
    tmp=$(mktemp "${CLAUDE_JSON}.tmp.XXXXXX")
    if docker cp "${container}:${CLAUDE_JSON}" "$tmp" 2>/dev/null; then
      mv -f "$tmp" "$CLAUDE_JSON" || { rm -f "$tmp"; echo "Warning: failed to sync .claude.json back to host (mv failed)" >&2; }
    else
      rm -f "$tmp"
      echo "Warning: failed to sync .claude.json back to host (docker cp failed)" >&2
    fi
  ) 200>"$CLAUDE_JSON_LOCK"
}
