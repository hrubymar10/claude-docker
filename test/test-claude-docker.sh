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
echo "═══════════════════════════════"
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] && echo "ALL TESTS PASSED" || { echo "SOME TESTS FAILED"; exit 1; }
