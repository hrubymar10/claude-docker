#!/bin/bash
set -euo pipefail
cd /Users/martinhruby/xcode/claude-docker

PASS=0; FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

echo ""
echo "═══ Input validation (CLAUDE_DOCKER_USER) ═══"
validate() {
  local user="$1" expect_accept="$2"
  result=$(CLAUDE_DOCKER_USER="$user" bash -c 'source bin/lib/sync-claude-json.sh 2>&1; echo OK')
  if [[ "$expect_accept" == "true" ]]; then
    if echo "$result" | grep -q "OK"; then ok "accepted '$user'"; else fail "should accept '$user' (got: $result)"; fi
  else
    if echo "$result" | grep -q "invalid characters"; then ok "rejected '$user'"; else fail "should reject '$user' (got: $result)"; fi
  fi
}
validate "martinhruby"  true
validate "user.name"    true
validate "user-name"    true
validate "user_123"     true
validate "../../etc"    false
validate "foo/bar"      false
validate "user name"    false

echo ""
echo "═══ Mount boundary check ═══"
check_mount() {
  local workdir="$1" src="$2" expect="$3"
  if [[ "$workdir" == "$src" || "$workdir" == "$src/"* ]]; then result="match"; else result="nomatch"; fi
  if [[ "$result" == "$expect" ]]; then ok "'$workdir' vs '$src'"; else fail "'$workdir' vs '$src' → $result (expected $expect)"; fi
}
check_mount "/Users/martinhruby/xcode"       "/Users/martinhruby/xcode"  match
check_mount "/Users/martinhruby/xcode/sub"   "/Users/martinhruby/xcode"  match
check_mount "/Users/martinhrubyx"            "/Users/martinhruby"        nomatch
check_mount "/Users/martinhruby-evil"        "/Users/martinhruby"        nomatch
check_mount "/etc/passwd"                    "/Users/martinhruby"        nomatch

echo ""
echo "═══ Sync function: lockf/flock (macOS compatibility) ═══"
OUTPUT=$(CONTAINER="claude-docker" bash -c 'source bin/lib/sync-claude-json.sh && sync_claude_json "$CONTAINER" 2>&1')
if echo "$OUTPUT" | grep -q "flock: command not found"; then
  fail "flock not found — lockf not being used"
elif echo "$OUTPUT" | grep -q "Warning"; then
  fail "unexpected warning: $OUTPUT"
else
  ok "sync completes cleanly (lockf on macOS)"
fi

tmp_count=$(find /Users/martinhruby -maxdepth 1 -name '.claude.json.tmp.*' 2>/dev/null | wc -l | tr -d ' ')
if [[ "$tmp_count" -eq 0 ]]; then ok "no temp files left behind"; else fail "$tmp_count temp file(s) left behind"; fi

echo ""
echo "═══ Sync function: warns on bad container ═══"
OUTPUT=$(CONTAINER="nonexistent-xyz-container" bash -c 'source bin/lib/sync-claude-json.sh && sync_claude_json "$CONTAINER" 2>&1')
if echo "$OUTPUT" | grep -q "Warning.*docker cp failed"; then ok "warns on docker cp failure"; else fail "no warning on bad container (got: $OUTPUT)"; fi

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
echo "═══ Seeding + sync-back round-trip ═══"
# Requires container running with new docker-compose.yml mounts:
#   ~/.claude.json -> /run/.claude.json.host (ro)  [not rw bind at real path]
SEED_MOUNT=$(docker inspect claude-docker \
  --format '{{range .Mounts}}{{if eq .Destination "/run/.claude.json.host"}}{{.Mode}}{{end}}{{end}}' 2>/dev/null || true)
if [[ "$SEED_MOUNT" == "ro" ]]; then
  ok "container has new read-only seed mount"

  # Write a sentinel value to container's writable copy
  SENTINEL="test_$(date +%s)"
  docker exec -u martinhruby claude-docker \
    bash -c "python3 -c \"import json,sys; d=json.load(open('/Users/martinhruby/.claude.json')); d['_test_sentinel']='$SENTINEL'; json.dump(d,open('/Users/martinhruby/.claude.json','w'))\"" \
    2>/dev/null
  # Sync back to host
  CONTAINER="claude-docker" bash -c 'source bin/lib/sync-claude-json.sh && sync_claude_json "$CONTAINER"'
  # Verify host has the sentinel
  if grep -q "$SENTINEL" ~/.claude.json 2>/dev/null; then
    ok "sync-back wrote container state to host"
  else
    fail "sync-back did not update host file"
  fi

  # Clean up sentinel from host (and container will pick it up on next start)
  python3 -c "
import json
with open('$HOME/.claude.json') as f: d=json.load(f)
d.pop('_test_sentinel', None)
with open('$HOME/.claude.json','w') as f: json.dump(d,f,indent=2)
" 2>/dev/null && ok "sentinel cleaned up from host" || fail "sentinel cleanup failed"
else
  echo "  SKIP: container not running with new mounts (got: '${SEED_MOUNT:-none}') — run 'make restart'"
fi

echo ""
echo "═══ Lockfile ═══"
if [[ -f /tmp/.claude-docker-json.lock ]]; then ok "lockfile exists at correct path"; else fail "lockfile missing at /tmp/.claude-docker-json.lock"; fi
if [[ ! -f /tmp/.claude-json.lock ]]; then ok "old misnamed lockfile absent"; else fail "old /tmp/.claude-json.lock still present"; fi

echo ""
echo "═══════════════════════════════"
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] && echo "ALL TESTS PASSED" || { echo "SOME TESTS FAILED"; exit 1; }
