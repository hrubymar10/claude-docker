#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"

PASS=0; FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

TMP_ROOT=$(mktemp -d)
trap 'rm -rf "$TMP_ROOT"' EXIT
FAKE_BIN="$TMP_ROOT/bin"
mkdir -p "$FAKE_BIN" "$TMP_ROOT/work/project"
LOG="$TMP_ROOT/docker.log"
: > "$LOG"

cat > "$FAKE_BIN/docker" <<'EOF'
#!/bin/bash
LOG_FILE="${FAKE_DOCKER_LOG:?}"
printf '%q ' "$@" >> "$LOG_FILE"
printf '\n' >> "$LOG_FILE"

case "${1:-}" in
  info) exit 0 ;;
  inspect)
    fmt=""
    for ((i=1; i<$#; i++)); do
      [[ "${!i}" == "--format" ]] && { j=$((i+1)); fmt="${!j}"; }
    done
    case "$fmt" in
      *'.Mounts'*)   echo "${FAKE_DOCKER_MOUNT:?} " ;;
      *'State.Status'*) echo running ;;
    esac
    exit 0
    ;;
  exec)
    echo stream-json-response
    exit 0
    ;;
  *) echo "unexpected: $*" >&2; exit 1 ;;
esac
EOF
chmod +x "$FAKE_BIN/docker"

echo
echo "═══ vscode wrapper: host-path arg is discarded ═══"
(
  export PATH="$FAKE_BIN:$PATH"
  export FAKE_DOCKER_LOG="$LOG"
  export FAKE_DOCKER_MOUNT="$TMP_ROOT/work"
  export CLAUDE_DOCKER_USER=tester
  cd "$TMP_ROOT/work/project"
  "$ROOT/bin/claude-docker-vscode-wrapper" /usr/local/bin/claude --output-format stream-json > "$TMP_ROOT/out.txt"
)

if grep -Eq 'exec -i .*CLAUDE_SESSION_ID=.* -u tester.*claude-session --output-format stream-json' "$LOG"; then
  ok "vscode wrapper execs claude-session with remaining args"
else
  fail "vscode wrapper did not produce expected docker exec call"
fi

if ! grep -Eq 'exec -it ' "$LOG"; then
  ok "vscode wrapper uses -i only (no -t)"
else
  fail "vscode wrapper allocated a TTY (should not)"
fi

if ! grep -q '/usr/local/bin/claude' "$LOG" || grep -Eq 'claude-session.*stream-json' "$LOG"; then
  ok "host claude path is discarded"
else
  fail "host claude path leaked into docker exec"
fi

if grep -q '^stream-json-response$' "$TMP_ROOT/out.txt"; then
  ok "vscode wrapper returns docker exec stdout"
else
  fail "vscode wrapper stdout mismatch"
fi

echo
echo "═══════════════════════════════"
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] && echo "ALL TESTS PASSED" || { echo "SOME TESTS FAILED"; exit 1; }
