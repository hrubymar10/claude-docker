#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

PASS=0; FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

echo ""
echo "═══ Mount boundary check ═══"
check_mount() {
  local workdir="$1" src="$2" expect="$3"
  if [[ "$workdir" == "$src" || "$workdir" == "$src/"* ]]; then result="match"; else result="nomatch"; fi
  if [[ "$result" == "$expect" ]]; then ok "'$workdir' vs '$src'"; else fail "'$workdir' vs '$src' → $result (expected $expect)"; fi
}
check_mount "$HOME/projects"                 "$HOME/projects"            match
check_mount "$HOME/projects/sub"             "$HOME/projects"            match
check_mount "${HOME}x"                       "$HOME"                     nomatch
check_mount "$HOME-evil"                     "$HOME"                     nomatch
check_mount "/etc/passwd"                    "$HOME"                     nomatch

echo ""
echo "═══ Credential helper: #!/bin/bash + special chars ═══"
TMP=$(mktemp)
# Generate a credential helper the same way entrypoint.sh does
GIT_AUTH_USER="user'quotes" GIT_AUTH_TOKEN='pass$word!&' bash << 'BASH'
  printf '#!/bin/bash\nprintf "username=%%s\\npassword=%%s\\n" %s %s\n' \
    "$(printf '%q' "$GIT_AUTH_USER")" "$(printf '%q' "$GIT_AUTH_TOKEN")" > /tmp/test-cred-helper
BASH
chmod 700 /tmp/test-cred-helper
output=$(bash /tmp/test-cred-helper)
if [[ "$output" == $'username=user\'quotes\npassword=pass$word!&' ]]; then
  ok "cred helper: special chars (quotes, dollar, bang)"
else
  fail "cred helper special chars: got '$output'"
fi

GIT_AUTH_USER="bob" GIT_AUTH_TOKEN="simple-token" bash << 'BASH'
  printf '#!/bin/bash\nprintf "username=%%s\\npassword=%%s\\n" %s %s\n' \
    "$(printf '%q' "$GIT_AUTH_USER")" "$(printf '%q' "$GIT_AUTH_TOKEN")" > /tmp/test-cred-helper
BASH
chmod 700 /tmp/test-cred-helper
output=$(bash /tmp/test-cred-helper)
if [[ "$output" == $'username=bob\npassword=simple-token' ]]; then
  ok "cred helper: plain credentials"
else
  fail "cred helper plain: got '$output'"
fi
rm -f /tmp/test-cred-helper

echo ""
echo "═══ claude-session teardown wrapper ═══"
if grep -q '^trap cleanup HUP TERM INT EXIT$' scripts/claude-session.sh \
  && grep -q '^exec 3<&0$' scripts/claude-session.sh \
  && grep -q '^claude "\$@" <&3 &$' scripts/claude-session.sh \
  && grep -q '^wait "\$CLAUDE_PID" 2>/dev/null$' scripts/claude-session.sh; then
  ok "claude-session keeps a supervising shell around claude"
else
  fail "claude-session missing supervising-shell teardown logic"
fi

echo ""
echo "═══ detached session watchdog ═══"
if grep -q '^_spawn_detached() {$' bin/lib/session-cleanup.sh \
  && grep -q 'command -v setsid' bin/lib/session-cleanup.sh \
  && grep -q 'os\.setsid()' bin/lib/session-cleanup.sh \
  && grep -q 'POSIX qw(setsid)' bin/lib/session-cleanup.sh \
  && grep -q '_spawn_detached ' bin/lib/session-cleanup.sh \
  && grep -q 'sleep 0.5' bin/lib/session-cleanup.sh \
  && grep -q 'attempt < 20' bin/lib/session-cleanup.sh \
  && grep -q 'sleep 0.25' bin/lib/session-cleanup.sh \
  && grep -q '^start_session_watchdog "\$CONTAINER" "\$SESSION_ID" "\$\$"$' bin/claude-docker-vscode-wrapper; then
  ok "watchdog is detached (portable fallback ladder) and covers non-TTY wrappers"
else
  fail "watchdog missing portable detach ladder, fast poll, or non-TTY coverage"
fi

echo ""
echo "═══════════════════════════════"
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] && echo "ALL TESTS PASSED" || { echo "SOME TESTS FAILED"; exit 1; }
