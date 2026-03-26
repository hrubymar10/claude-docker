#!/bin/sh
# Wrapper that ensures claude + children (gopls, etc.) are killed when the
# session ends.
#
# Defense in depth — two cleanup mechanisms:
#
# 1. Container-side: trap on signals kills the process group. Works when
#    signals are delivered explicitly (e.g. host-side wrapper sends SIGHUP).
#
# 2. Host-side: the caller (c function / bin/claude-docker) passes
#    CLAUDE_SESSION_ID env var. This script writes its PID to a known file.
#    When docker exec exits on the host, the caller reads the PID file and
#    sends SIGHUP to the process group, triggering cleanup #1.

if [ -n "$CLAUDE_SESSION_ID" ]; then
    echo $$ > "/tmp/claude-session-${CLAUDE_SESSION_ID}.pid"
fi

# Non-TTY (VSCode/pipe): backgrounding claude loses stdin, so exec directly.
# Cleanup isn't needed — non-TTY docker exec dies with the parent process,
# and tini (init: true) reaps any orphaned children.
if ! [ -t 0 ]; then
    exec claude "$@"
fi

# TTY (interactive terminal): background claude so we can trap signals and
# kill the entire process group on disconnect (prevents orphaned gopls etc.)
cleanup() {
    trap '' HUP TERM INT EXIT
    kill -TERM 0 2>/dev/null
    sleep 2
    kill -KILL 0 2>/dev/null
    [ -n "$CLAUDE_SESSION_ID" ] && rm -f "/tmp/claude-session-${CLAUDE_SESSION_ID}.pid"
}

trap cleanup HUP TERM INT EXIT

claude "$@" &
CLAUDE_PID=$!
wait $CLAUDE_PID 2>/dev/null
EXIT_CODE=$?

trap - HUP TERM INT EXIT
exit $EXIT_CODE
