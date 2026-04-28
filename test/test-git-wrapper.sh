#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

# Host-side unit tests for scripts/git-wrapper.sh — sandboxed with a fake
# git-real and fake sudo on PATH so we exercise the wrapper outside Docker.

PASS=0; FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); echo "    output: $2"; }

WRAPPER_SRC="scripts/git-wrapper.sh"

setup_sandbox() {
  local fake_uid="${1:-1000}"
  local sandbox
  sandbox=$(mktemp -d)

  mkdir -p "$sandbox/libexec/git-real" "$sandbox/bin"

  cat > "$sandbox/libexec/git-real/git" <<'FAKE_GIT'
#!/bin/bash
echo "INVOKED:git-real:$*"
echo "REAL_HOME=$HOME"
echo "REAL_UID=$(id -u 2>/dev/null || echo unknown)"
exit 0
FAKE_GIT
  chmod +x "$sandbox/libexec/git-real/git"

  cat > "$sandbox/bin/sudo" <<'FAKE_SUDO'
#!/bin/bash
echo "INVOKED:sudo:$*"
while [ $# -gt 0 ]; do
  case "$1" in
    --) shift; break ;;
    -n|-E) shift ;;
    --preserve-env=*) shift ;;
    --preserve-env) shift; shift ;;
    -u) shift; shift ;;
    -*) shift ;;
    *) break ;;
  esac
done
exec "$@"
FAKE_SUDO
  chmod +x "$sandbox/bin/sudo"

  cat > "$sandbox/bin/id" <<FAKE_ID
#!/bin/bash
case "\$1" in
  -u) echo $fake_uid ;;
  *) /usr/bin/id "\$@" ;;
esac
FAKE_ID
  chmod +x "$sandbox/bin/id"

  sed "s|^GIT_REAL=.*|GIT_REAL=$sandbox/libexec/git-real/git|" \
      "$WRAPPER_SRC" > "$sandbox/bin/git"
  chmod +x "$sandbox/bin/git"

  echo "$sandbox"
}

run_wrapper() {
  local sandbox="$1"; shift
  PATH="$sandbox/bin:/usr/bin:/bin" "$sandbox/bin/git" "$@" 2>&1 || true
}

echo ""
echo "═══ Wrapper escalates via sudo when running as non-root ═══"
sandbox=$(setup_sandbox 1000)
output=$(run_wrapper "$sandbox" status)
if grep -q "INVOKED:sudo:" <<<"$output"; then
  ok "wrapper invoked sudo"
else
  fail "wrapper did not invoke sudo" "$output"
fi
rm -rf "$sandbox"

echo ""
echo "═══ Wrapper invokes git-real directly when running as root ═══"
sandbox=$(setup_sandbox 0)
output=$(run_wrapper "$sandbox" status)
if grep -q "INVOKED:git-real:status" <<<"$output" && ! grep -q "INVOKED:sudo:" <<<"$output"; then
  ok "wrapper skipped sudo as root"
else
  fail "wrapper did not run git-real directly as root" "$output"
fi
rm -rf "$sandbox"

echo ""
echo "═══ Wrapper preserves HOME through sudo ═══"
sandbox=$(setup_sandbox 1000)
output=$(run_wrapper "$sandbox" status)
if grep -q -- "--preserve-env=HOME" <<<"$output" || grep -q "preserve-env.*HOME" <<<"$output"; then
  ok "wrapper preserves HOME via sudo"
else
  fail "wrapper does not request HOME preservation" "$output"
fi
rm -rf "$sandbox"

echo ""
echo "═══ Wrapper blocks push to protected branch (main) ═══"
sandbox=$(setup_sandbox 1000)
set +e
output=$(PATH="$sandbox/bin:/usr/bin:/bin" "$sandbox/bin/git" push origin main 2>&1)
exit_code=$?
set -e
if [ $exit_code -ne 0 ] && grep -qi "blocked" <<<"$output"; then
  ok "push origin main blocked"
else
  fail "push origin main was not blocked (exit=$exit_code)" "$output"
fi
rm -rf "$sandbox"

echo ""
echo "═══ Wrapper blocks push to protected branch via HEAD:master ═══"
sandbox=$(setup_sandbox 1000)
set +e
output=$(PATH="$sandbox/bin:/usr/bin:/bin" "$sandbox/bin/git" push -f origin HEAD:master 2>&1)
exit_code=$?
set -e
if [ $exit_code -ne 0 ] && grep -qi "blocked" <<<"$output"; then
  ok "push HEAD:master blocked"
else
  fail "push HEAD:master was not blocked (exit=$exit_code)" "$output"
fi
rm -rf "$sandbox"

echo ""
echo "═══ Wrapper allows push to non-protected branch ═══"
sandbox=$(setup_sandbox 1000)
output=$(run_wrapper "$sandbox" push origin my-feature)
if grep -q "INVOKED:git-real:push origin my-feature" <<<"$output"; then
  ok "push to feature branch allowed"
else
  fail "push to feature branch did not reach git-real" "$output"
fi
rm -rf "$sandbox"

echo ""
echo "═══ Wrapper passes through non-push commands ═══"
sandbox=$(setup_sandbox 1000)
output=$(run_wrapper "$sandbox" log --oneline)
if grep -q "INVOKED:git-real:log --oneline" <<<"$output"; then
  ok "non-push command reaches git-real"
else
  fail "non-push command did not reach git-real" "$output"
fi
rm -rf "$sandbox"

echo ""
echo "═══ Custom GIT_PROTECTED_BRANCHES env honored ═══"
sandbox=$(setup_sandbox 1000)
set +e
output=$(PATH="$sandbox/bin:/usr/bin:/bin" GIT_PROTECTED_BRANCHES="prod" "$sandbox/bin/git" push origin prod 2>&1)
exit_code=$?
set -e
if [ $exit_code -ne 0 ] && grep -qi "blocked" <<<"$output"; then
  ok "custom protected branch (prod) honored"
else
  fail "custom protected branch was not honored (exit=$exit_code)" "$output"
fi
# And: pushing to "main" with custom list should now be allowed
output=$(PATH="$sandbox/bin:/usr/bin:/bin" GIT_PROTECTED_BRANCHES="prod" "$sandbox/bin/git" push origin main 2>&1)
if grep -q "INVOKED:git-real:push origin main" <<<"$output"; then
  ok "main no longer protected when overridden"
else
  fail "override removed main protection" "$output"
fi
rm -rf "$sandbox"

echo ""
echo "═══ Dockerfile chmods git-real to mode 0700 ═══"
if grep -E "chmod[[:space:]]+0?700[[:space:]]+/usr/libexec/git-real/git" Dockerfile >/dev/null; then
  ok "Dockerfile sets git-real to mode 0700"
else
  fail "Dockerfile does NOT chmod git-real to 0700" "$(grep -n 'git-real' Dockerfile || echo 'no git-real lines')"
fi

echo ""
echo "═══ entrypoint.sh no longer uses gosu+git-real (defeats chmod) ═══"
if grep -E 'gosu[[:space:]]+"\$HOST_USER"[[:space:]]+/usr/libexec/git-real/git' scripts/entrypoint.sh >/dev/null; then
  fail "entrypoint.sh still calls git-real via gosu (would fail with mode 0700)" \
       "$(grep -n 'git-real' scripts/entrypoint.sh)"
else
  ok "entrypoint.sh does not call git-real via gosu"
fi

echo ""
echo "═══════════════════════════════"
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] && echo "ALL TESTS PASSED" || { echo "SOME TESTS FAILED"; exit 1; }
