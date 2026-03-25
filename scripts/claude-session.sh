#!/bin/sh
# Wrapper that ensures claude + children (gopls, etc.) are killed when the
# terminal/exec session disconnects.
#
# Problem: `docker exec -it` allocates a PTY, but when the host terminal
# closes, claude and its children hold the PTY slave open, preventing SIGHUP
# delivery. The processes become orphans that accumulate RAM and CPU.
#
# Solution: Run claude in background, trap signals, kill the entire process
# group on any exit. `kill 0` sends SIGTERM to every process in our group.

cleanup() {
    trap '' HUP TERM INT EXIT
    kill -TERM 0 2>/dev/null
    sleep 0.5
    kill -KILL 0 2>/dev/null
}

trap cleanup HUP TERM INT EXIT

claude "$@" &
CLAUDE_PID=$!
wait $CLAUDE_PID 2>/dev/null
EXIT_CODE=$?

trap - HUP TERM INT EXIT
exit $EXIT_CODE
