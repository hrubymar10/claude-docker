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
  && grep -q '^start_session_watchdog "\$CONTAINER" "\$SESSION_ID" "\$\$" "\$DOCKER_USER"$' bin/claude-docker-vscode-wrapper; then
  ok "watchdog is detached (portable fallback ladder) and covers non-TTY wrappers"
else
  fail "watchdog missing portable detach ladder, fast poll, or non-TTY coverage"
fi

# The python/perl detach branches must double-fork: a background job of an
# interactive shell is a process-group leader, where a bare setsid() fails
# with EPERM and the watchdog would die together with the closing terminal.
if grep -q 'os\.fork()' bin/lib/session-cleanup.sh \
  && grep -q 'exit 0 if fork();' bin/lib/session-cleanup.sh; then
  ok "detach branches double-fork before setsid"
else
  fail "python/perl detach branches missing double-fork before setsid"
fi

# Parent liveness must compare PID + start time, or a recycled PID keeps the
# watchdog waiting forever.
if grep -q 'ps -o lstart= -p' bin/lib/session-cleanup.sh; then
  ok "watchdog checks parent identity (PID + start time), not just kill -0"
else
  fail "watchdog liveness check vulnerable to PID reuse"
fi

echo ""
echo "═══ stale session reaping + daemon idle-stop ═══"
if grep -q '^reap_stale_sessions() {$' bin/lib/session-cleanup.sh \
  && grep -q 'CLAUDE_SESSION_ID=\$session_id' bin/lib/session-cleanup.sh \
  && grep -q 'claude daemon stop --any' bin/lib/session-cleanup.sh \
  && grep -q '^_kill_watchdog() {$' bin/lib/session-cleanup.sh; then
  ok "orphan sweep, watchdog self-cleanup, and daemon idle-stop present"
else
  fail "missing orphan sweep / watchdog self-cleanup / daemon idle-stop"
fi

for wrapper in bin/claude-docker bin/claude-docker-vscode-wrapper bin/claude-docker-jetbrains-wrapper; do
  if grep -q '^reap_stale_sessions "\$CONTAINER" "\$DOCKER_USER"$' "$wrapper" \
    && grep -q '^run_session_cleanup "\$CONTAINER" "\$SESSION_ID" "\$DOCKER_USER"$' "$wrapper"; then
    ok "$wrapper reaps stale sessions and passes container user"
  else
    fail "$wrapper missing reap_stale_sessions or user propagation"
  fi
done

echo ""
echo "═══ Docker wrapper bypass check (Vuln 2) ═══"
# Closes the bypass where /usr/bin/docker remained the real binary while the
# wrapper sat at /usr/local/bin/docker. Mirrors the existing git-wrapper pattern.

if grep -qE 'mv /usr/bin/docker[[:space:]]+/usr/libexec/docker-real/docker' Dockerfile; then
  ok "Dockerfile relocates real /usr/bin/docker to /usr/libexec/docker-real/docker"
else
  fail "Dockerfile does not relocate /usr/bin/docker — wrapper bypass via direct /usr/bin/docker call"
fi

if grep -qE 'COPY scripts/docker-wrapper\.sh[[:space:]]+/usr/bin/docker' Dockerfile; then
  ok "Dockerfile installs docker wrapper at /usr/bin/docker"
else
  fail "Dockerfile does not install wrapper at /usr/bin/docker — PATH-shadow only"
fi

if grep -qE 'exec[[:space:]]+/usr/libexec/docker-real/docker' scripts/docker-wrapper.sh; then
  ok "wrapper invokes real docker at /usr/libexec/docker-real/docker"
else
  fail "wrapper does not invoke /usr/libexec/docker-real/docker"
fi

if grep -qE 'exec[[:space:]]+/usr/bin/docker' scripts/docker-wrapper.sh; then
  fail "wrapper still invokes /usr/bin/docker — would recurse into itself"
else
  ok "wrapper no longer invokes /usr/bin/docker"
fi

echo ""
echo "═══ Docker wrapper behavioral check ═══"
# Run the wrapper with the real-docker path rewritten to a mock so we can
# observe what gets exec'd without needing a built container.
WRAP_TMP=$(mktemp -d)
trap 'rm -rf "$WRAP_TMP"' EXIT
cat > "$WRAP_TMP/mock-docker" <<'MOCK'
#!/bin/bash
if [[ "${1:-}" == "build" ]]; then
  echo "REAL_DOCKER:DOCKER_BUILDKIT=${DOCKER_BUILDKIT:-unset}:$*"
  exit 0
fi
echo "REAL_DOCKER:$*"
MOCK
chmod +x "$WRAP_TMP/mock-docker"
sed "s|/usr/libexec/docker-real/docker|$WRAP_TMP/mock-docker|g" scripts/docker-wrapper.sh > "$WRAP_TMP/wrapper.sh"
chmod +x "$WRAP_TMP/wrapper.sh"

output=$(bash "$WRAP_TMP/wrapper.sh" ps 2>&1 || true)
if [[ "$output" == "REAL_DOCKER:ps" ]]; then
  ok "wrapper passes 'ps' through to real docker"
else
  fail "wrapper 'ps' got: $output"
fi

output=$(bash "$WRAP_TMP/wrapper.sh" run alpine 2>&1 || true)
if [[ "$output" == *"blocked"* ]]; then
  ok "wrapper blocks 'run'"
else
  fail "wrapper 'run' got: $output"
fi

output=$(DOCKER_BUILDKIT=1 bash "$WRAP_TMP/wrapper.sh" build . 2>&1 || true)
if [[ "$output" == "REAL_DOCKER:DOCKER_BUILDKIT=1:build ." ]]; then
  ok "wrapper allows 'build' without changing the builder"
else
  fail "wrapper 'build' got: $output"
fi

output=$(bash "$WRAP_TMP/wrapper.sh" buildx build . 2>&1 || true)
if [[ "$output" == "REAL_DOCKER:buildx build ." ]]; then
  ok "wrapper allows 'buildx'"
else
  fail "wrapper 'buildx' got: $output"
fi

output=$(bash "$WRAP_TMP/wrapper.sh" cp foo bar 2>&1 || true)
if [[ "$output" == *"blocked"* ]]; then
  ok "wrapper blocks 'cp'"
else
  fail "wrapper 'cp' got: $output"
fi

output=$(bash "$WRAP_TMP/wrapper.sh" --version 2>&1 || true)
if [[ "$output" == "REAL_DOCKER:--version" ]]; then
  ok "wrapper passes '--version' to real docker"
else
  fail "wrapper '--version' got: $output"
fi

echo ""
echo "═══════════════════════════════"
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] && echo "ALL TESTS PASSED" || { echo "SOME TESTS FAILED"; exit 1; }
