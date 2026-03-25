# Session cleanup for claude-docker wrappers.
# Source this, then call: start_session_watchdog <container> <session_id>
# and after docker exec: run_session_cleanup <container> <session_id>
#
# The watchdog monitors the parent PID — when it dies (terminal closed),
# sends SIGHUP to the container-side claude-session process group.

start_session_watchdog() {
  local container="$1" session_id="$2" parent_pid="$3"
  (
    while kill -0 "$parent_pid" 2>/dev/null; do sleep 2; done
    _do_session_cleanup "$container" "$session_id"
  ) &
  disown
}

run_session_cleanup() {
  _do_session_cleanup "$@"
}

_do_session_cleanup() {
  local container="$1" session_id="$2"
  docker exec "$container" sh -c '
    f="/tmp/claude-session-'"$session_id"'.pid"
    [ -f "$f" ] || exit 0
    pid=$(cat "$f")
    kill -HUP "$pid" 2>/dev/null
    rm -f "$f"
  ' 2>/dev/null
}
