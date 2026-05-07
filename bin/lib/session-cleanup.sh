# Session cleanup for claude-docker wrappers.
# Source this, then call: start_session_watchdog <container> <session_id>
# and after docker exec: run_session_cleanup <container> <session_id>
#
# The watchdog monitors the parent PID. When it dies (terminal closed, host
# wrapper killed), the watchdog keeps retrying cleanup briefly so it can catch
# the session pidfile even when docker exec is still starting up.

_session_pidfile() {
  printf '/tmp/claude-session-%s.pid' "$1"
}

_session_debug_log() {
  local message="$1"
  local log_file="${CLAUDE_DOCKER_SESSION_DEBUG_LOG:-/tmp/claude-docker-session-debug.log}"
  printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$message" >> "$log_file"
}

# Spawn a backgrounded process in a new session, detached from the parent's
# controlling tty so it survives terminal close. macOS does not ship setsid(1),
# so fall back through python3 → perl → nohup. Stdio goes to /dev/null.
#
# Usage: _spawn_detached <bash_script> [args...]
# Inside <bash_script>, positional args start at $1 (with $0 being "sh").
_spawn_detached() {
  local script="$1"; shift
  if command -v setsid >/dev/null 2>&1; then
    setsid bash -c "$script" sh "$@" >/dev/null 2>&1 </dev/null &
  elif command -v python3 >/dev/null 2>&1; then
    python3 -c '
import os, sys
try:
    os.setsid()
except OSError:
    pass
os.execvp("bash", ["bash", "-c", sys.argv[1], "sh"] + sys.argv[2:])
' "$script" "$@" >/dev/null 2>&1 </dev/null &
  elif command -v perl >/dev/null 2>&1; then
    perl -e '
use POSIX qw(setsid);
eval { setsid(); };
exec("bash", "-c", $ARGV[0], "sh", @ARGV[1..$#ARGV]);
' "$script" "$@" >/dev/null 2>&1 </dev/null &
  else
    nohup bash -c "$script" sh "$@" >/dev/null 2>&1 </dev/null &
  fi
}

start_session_watchdog() {
  local container="$1" session_id="$2" parent_pid="$3" pidfile log_file
  pidfile=$(_session_pidfile "$session_id")
  log_file="${CLAUDE_DOCKER_SESSION_DEBUG_LOG:-/tmp/claude-docker-session-debug.log}"
  _session_debug_log "start_watchdog session=$session_id parent_pid=$parent_pid container=$container pidfile=$pidfile"
  _spawn_detached '
    parent_pid="$1"
    container="$2"
    pidfile="$3"
    log_file="$4"
    log() {
      printf "%s %s\n" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" >> "$log_file"
    }
    log "watchdog_spawned session_pidfile=$pidfile parent_pid=$parent_pid container=$container"
    while kill -0 "$parent_pid" 2>/dev/null; do sleep 0.5; done
    log "watchdog_parent_dead parent_pid=$parent_pid"
    for ((attempt = 0; attempt < 20; attempt++)); do
      result=$(docker exec "$container" sh -c '"'"'
        f="$1"
        [ -f "$f" ] || { echo "pidfile_missing"; exit 1; }
        pid=$(cat "$f")
        echo "pidfile_found pid=$pid"
        kill -HUP "$pid" 2>/dev/null
        rm -f "$f"
      '"'"' sh "$pidfile" 2>/dev/null)
      status=$?
      log "watchdog_attempt attempt=$attempt status=$status result=${result:-none}"
      if [ "$status" -eq 0 ]; then
        log "watchdog_cleanup_succeeded attempt=$attempt"
        exit 0
      fi
      sleep 0.25
    done
    log "watchdog_cleanup_gave_up pidfile=$pidfile"
  ' "$parent_pid" "$container" "$pidfile" "$log_file"
}

run_session_cleanup() {
  _session_debug_log "run_session_cleanup session_id=$2"
  _do_session_cleanup "$@" || true
}

_do_session_cleanup() {
  local container="$1" session_id="$2" pidfile result status
  pidfile=$(_session_pidfile "$session_id")
  result=$(docker exec "$container" sh -c '
    f="$1"
    [ -f "$f" ] || { echo "pidfile_missing"; exit 1; }
    pid=$(cat "$f")
    echo "pidfile_found pid=$pid"
    kill -HUP "$pid" 2>/dev/null
    rm -f "$f"
  ' sh "$pidfile" 2>/dev/null)
  status=$?
  _session_debug_log "_do_session_cleanup session_id=$session_id status=$status result=${result:-none}"
  return "$status"
}
