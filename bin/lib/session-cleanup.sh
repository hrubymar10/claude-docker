# Session cleanup for claude-docker wrappers.
# Source this, then call: start_session_watchdog <container> <session_id> <parent_pid> [user]
# and after docker exec: run_session_cleanup <container> <session_id> [user]
# Call reap_stale_sessions <container> [user] before starting a new session to
# sweep sessions whose host client died without cleanup (host crash/reboot, or
# a pre-fix watchdog that was killed together with the terminal).
#
# The watchdog monitors the parent PID. When it dies (terminal closed, host
# wrapper killed), the watchdog keeps retrying cleanup briefly so it can catch
# the session pidfile even when docker exec is still starting up. After any
# cleanup, if the container has no remaining sessions, the transient
# `claude daemon` is stopped so armed background tasks (pipeline monitors,
# detached agents) cannot keep re-invoking Claude with nobody attached.

_session_pidfile() {
  printf '/tmp/claude-session-%s.pid' "$1"
}

# Host-side pidfile of the watchdog itself, so a normal session exit can stop
# the watchdog instead of leaving it polling a dead (or recycled) parent PID.
_watchdog_pidfile() {
  printf '/tmp/claude-docker-watchdog-%s.pid' "$1"
}

_session_debug_log() {
  local message="$1"
  local log_file="${CLAUDE_DOCKER_SESSION_DEBUG_LOG:-/tmp/claude-docker-session-debug.log}"
  printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$message" >> "$log_file"
}

_container_user() {
  printf '%s' "${1:-${CLAUDE_DOCKER_USER:-$(whoami)}}"
}

# Runs inside the container. Stops the transient claude daemon when nothing is
# left that could legitimately own background work: no session pidfiles and no
# claude process attached to a terminal. Prints "daemon_stopped" when it acted.
_IDLE_STOP_SNIPPET='
ls /tmp/claude-session-*.pid >/dev/null 2>&1 && exit 0
ps -eo tty,args 2>/dev/null | grep "pts/" | grep -q claude && exit 0
claude daemon stop --any >/dev/null 2>&1
echo daemon_stopped
'

# Spawn a backgrounded process fully detached from the calling shell: own
# session, no controlling tty, stdio on /dev/null. macOS does not ship
# setsid(1), so fall back through python3 → perl → nohup.
#
# The python/perl branches double-fork before setsid: when the caller is an
# interactive shell with job control (the `c` zsh function), a background job
# is created as its own process-group leader, and setsid() always fails with
# EPERM for a group leader. Swallowing that failure leaves the child inside
# the terminal's session, where zsh HUP-kills it together with the closing
# window — exactly when the watchdog is needed. util-linux setsid(1) forks on
# its own in that case; the nohup fallback cannot detach and is best-effort.
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
if os.fork() > 0:
    os._exit(0)
os.setsid()
os.execvp("bash", ["bash", "-c", sys.argv[1], "sh"] + sys.argv[2:])
' "$script" "$@" >/dev/null 2>&1 </dev/null &
  elif command -v perl >/dev/null 2>&1; then
    perl -e '
use POSIX qw(setsid);
exit 0 if fork();
setsid();
exec("bash", "-c", $ARGV[0], "sh", @ARGV[1..$#ARGV]);
' "$script" "$@" >/dev/null 2>&1 </dev/null &
  else
    nohup bash -c "$script" sh "$@" >/dev/null 2>&1 </dev/null &
  fi
}

start_session_watchdog() {
  local container="$1" session_id="$2" parent_pid="$3" user pidfile watchdog_pidfile log_file parent_start
  user=$(_container_user "${4:-}")
  pidfile=$(_session_pidfile "$session_id")
  watchdog_pidfile=$(_watchdog_pidfile "$session_id")
  log_file="${CLAUDE_DOCKER_SESSION_DEBUG_LOG:-/tmp/claude-docker-session-debug.log}"
  # Parent identity is PID + start time: a bare `kill -0 $pid` waits forever
  # when the PID is recycled by an unrelated process after the shell exits.
  parent_start=$(ps -o lstart= -p "$parent_pid" 2>/dev/null)
  _session_debug_log "start_watchdog session=$session_id parent_pid=$parent_pid container=$container pidfile=$pidfile"
  _spawn_detached '
    parent_pid="$1"
    container="$2"
    pidfile="$3"
    log_file="$4"
    parent_start="$5"
    watchdog_pidfile="$6"
    user="$7"
    idle_stop_snippet="$8"
    echo $$ > "$watchdog_pidfile"
    trap "rm -f \$watchdog_pidfile" EXIT
    trap "exit 0" HUP INT TERM
    log() {
      printf "%s %s\n" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" >> "$log_file"
    }
    log "watchdog_spawned session_pidfile=$pidfile parent_pid=$parent_pid container=$container"
    while [ -n "$parent_start" ] && [ "$(ps -o lstart= -p "$parent_pid" 2>/dev/null)" = "$parent_start" ]; do
      sleep 0.5
    done
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
        stopped=$(docker exec -u "$user" "$container" sh -c "$idle_stop_snippet" 2>/dev/null)
        [ -n "$stopped" ] && log "watchdog_daemon_stopped_idle"
        exit 0
      fi
      sleep 0.25
    done
    log "watchdog_cleanup_gave_up pidfile=$pidfile"
  ' "$parent_pid" "$container" "$pidfile" "$log_file" "$parent_start" "$watchdog_pidfile" "$user" "$_IDLE_STOP_SNIPPET"
}

run_session_cleanup() {
  local container="$1" session_id="$2" user
  user=$(_container_user "${3:-}")
  _session_debug_log "run_session_cleanup session_id=$session_id"
  _do_session_cleanup "$container" "$session_id" || true
  _kill_watchdog "$session_id"
  _stop_daemon_if_idle "$container" "$user"
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

# The watchdog is only needed while its session lives; kill it on normal exit
# so it does not linger polling a dead (or recycled) parent PID.
_kill_watchdog() {
  local watchdog_pidfile pid
  watchdog_pidfile=$(_watchdog_pidfile "$1")
  [ -f "$watchdog_pidfile" ] || return 0
  pid=$(cat "$watchdog_pidfile" 2>/dev/null)
  [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
  rm -f "$watchdog_pidfile"
  return 0
}

_stop_daemon_if_idle() {
  local container="$1" user="$2" stopped
  stopped=$(docker exec -u "$user" "$container" sh -c "$_IDLE_STOP_SNIPPET" 2>/dev/null) || true
  [ -n "$stopped" ] && _session_debug_log "daemon_stopped_idle container=$container"
  return 0
}

# Sweep sessions whose host side is gone. Every session writes
# /tmp/claude-session-<id>.pid inside the container, and every live host
# client is a `docker exec` process carrying CLAUDE_SESSION_ID=<id> on its
# command line — a pidfile without a matching host process is an orphan whose
# watchdog never fired.
reap_stale_sessions() {
  local container="$1" user pidfiles pidfile session_id
  # Host-only: inside the container pgrep cannot see the host clients (the
  # session id is env there, not argv), so every session would look stale.
  if [ -f /.dockerenv ]; then
    _session_debug_log "reap_skipped_inside_container"
    return 0
  fi
  user=$(_container_user "${2:-}")
  pidfiles=$(docker exec "$container" sh -c 'ls /tmp/claude-session-*.pid 2>/dev/null') || true
  # Not a for-loop: this file is sourced by both bash and zsh, and zsh does
  # not word-split unquoted expansions.
  printf '%s\n' "$pidfiles" | while IFS= read -r pidfile; do
    [ -n "$pidfile" ] || continue
    session_id="${pidfile#/tmp/claude-session-}"
    session_id="${session_id%.pid}"
    pgrep -f "CLAUDE_SESSION_ID=$session_id" >/dev/null 2>&1 && continue
    _session_debug_log "reap_stale_session session_id=$session_id"
    docker exec "$container" sh -c '
      f="$1"
      [ -f "$f" ] || exit 0
      pid=$(cat "$f")
      kill -HUP "$pid" 2>/dev/null
      rm -f "$f"
    ' sh "$pidfile" >/dev/null 2>&1 || true
    _kill_watchdog "$session_id"
  done
  _stop_daemon_if_idle "$container" "$user"
}
