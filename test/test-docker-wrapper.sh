#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"

PASS=0
FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

TMP_ROOT=$(mktemp -d)
trap 'rm -rf "$TMP_ROOT"' EXIT
FAKE_DOCKER="$TMP_ROOT/docker-real"
WRAPPER="$TMP_ROOT/docker"
LOG="$TMP_ROOT/docker.log"

cat > "$FAKE_DOCKER" <<'EOF'
#!/bin/bash
set -euo pipefail
printf 'DOCKER_BUILDKIT=%s|' "${DOCKER_BUILDKIT:-unset}" >> "${FAKE_DOCKER_LOG:?}"
printf '%q ' "$@" >> "$FAKE_DOCKER_LOG"
printf '\n' >> "$FAKE_DOCKER_LOG"
EOF
chmod +x "$FAKE_DOCKER"
sed "s|/usr/libexec/docker-real/docker|$FAKE_DOCKER|g" \
  "$ROOT/scripts/docker-wrapper.sh" > "$WRAPPER"
chmod +x "$WRAPPER"
export FAKE_DOCKER_LOG="$LOG"

echo
echo "═══ docker build wrapper ═══"

DOCKER_BUILDKIT=1 "$WRAPPER" build --tag project:test . 2> "$TMP_ROOT/build.err"
if grep -Fqx 'DOCKER_BUILDKIT=1|build --tag project:test . ' "$LOG" \
  && [[ ! -s "$TMP_ROOT/build.err" ]]; then
  ok "build is forwarded without changing BuildKit mode"
else
  fail "build was changed or unexpectedly warned"
fi

"$WRAPPER" buildx build --tag project:test . 2> "$TMP_ROOT/buildx.err"
if tail -n 1 "$LOG" | grep -Fqx 'DOCKER_BUILDKIT=unset|buildx build --tag project:test . ' \
  && [[ ! -s "$TMP_ROOT/buildx.err" ]]; then
  ok "buildx is forwarded without warning for project images"
else
  fail "buildx was blocked or unexpectedly warned"
fi

warning_cases=(
  'build --tag claude-docker:test .'
  'build -t codex-docker:test .'
  'buildx build --tag=pi-docker:test .'
  'buildx build -tvibe-docker:test .'
)
for command_line in "${warning_cases[@]}"; do
  read -r -a args <<< "$command_line"
  "$WRAPPER" "${args[@]}" 2> "$TMP_ROOT/warning.err"
  image_name=$(printf '%s\n' "$command_line" | grep -oE '(claude|codex|pi|vibe)-docker')
  if grep -Fq "overwrites a sandbox's own image" "$TMP_ROOT/warning.err" \
    && grep -Fq "$image_name" "$TMP_ROOT/warning.err"; then
    ok "warns and proceeds for $image_name"
  else
    fail "missing sandbox-image warning for $command_line"
  fi
done

"$WRAPPER" build -t claude-docker-helper:test . 2> "$TMP_ROOT/lookalike.err"
"$WRAPPER" build -t localhost:5000/claude-docker:test . 2> "$TMP_ROOT/registry.err"
if [[ ! -s "$TMP_ROOT/lookalike.err" && ! -s "$TMP_ROOT/registry.err" ]]; then
  ok "lookalike and registry-qualified repositories do not warn"
else
  fail "warning matched a non-sandbox repository"
fi

"$WRAPPER" ps
if tail -n 1 "$LOG" | grep -Fqx 'DOCKER_BUILDKIT=unset|ps '; then
  ok "existing allowlisted commands remain unchanged"
else
  fail "existing allowlisted command was not forwarded"
fi

echo
echo "═══════════════════════════════"
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] && echo "ALL TESTS PASSED" || { echo "SOME TESTS FAILED"; exit 1; }
