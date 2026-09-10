#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"

PASS=0; FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

TMP_ROOT=$(mktemp -d)
TMPDIR_TEST="$TMP_ROOT/tmp"
mkdir -p "$TMPDIR_TEST"
trap 'restore_local_state; rm -rf "$TMP_ROOT"' EXIT

FAKE_BIN="$TMP_ROOT/bin"
mkdir -p "$FAKE_BIN"
LOG="$TMP_ROOT/docker.log"
: > "$LOG"

restore_local_state() {
  if [[ -n "${BACKUP_LOCAL_COMPOSE:-}" && -f "$BACKUP_LOCAL_COMPOSE" ]]; then
    mv "$BACKUP_LOCAL_COMPOSE" "$ROOT/config/docker-compose.local.yml"
  else
    rm -f "$ROOT/config/docker-compose.local.yml"
  fi

  if [[ -n "${BACKUP_NOTIFIER:-}" && -f "$BACKUP_NOTIFIER" ]]; then
    mv "$BACKUP_NOTIFIER" "$ROOT/config/claude-notifier"
  else
    rm -f "$ROOT/config/claude-notifier"
  fi

  if [[ -n "${BACKUP_ENV:-}" && -f "$BACKUP_ENV" ]]; then
    mv "$BACKUP_ENV" "$ROOT/config/.env"
  fi
}

cat > "$FAKE_BIN/docker" <<'EOF'
#!/bin/bash
set -euo pipefail
LOG_FILE="${FAKE_DOCKER_LOG:?}"
printf 'COMPOSE_PROJECT_NAME=%s ' "${COMPOSE_PROJECT_NAME:-}" >> "$LOG_FILE"
printf '%q ' "$@" >> "$LOG_FILE"
printf '\n' >> "$LOG_FILE"

case "${1:-}" in
  info)
    exit 0
    ;;
  version)
    if [[ "${2:-}" == "--format" ]]; then
      echo 1.44
    fi
    exit 0
    ;;
  compose)
    exit 0
    ;;
  *)
    echo "unexpected docker call: $*" >&2
    exit 1
    ;;
esac
EOF
chmod +x "$FAKE_BIN/docker"

if [[ -f "$ROOT/config/docker-compose.local.yml" ]]; then
  BACKUP_LOCAL_COMPOSE="$TMP_ROOT/docker-compose.local.yml.bak"
  cp "$ROOT/config/docker-compose.local.yml" "$BACKUP_LOCAL_COMPOSE"
fi

if [[ -f "$ROOT/config/claude-notifier" ]]; then
  BACKUP_NOTIFIER="$TMP_ROOT/claude-notifier.bak"
  cp "$ROOT/config/claude-notifier" "$BACKUP_NOTIFIER"
fi
rm -f "$ROOT/config/claude-notifier"

# The ctrl loads config/.env; keep the developer's real values out of the run.
if [[ -f "$ROOT/config/.env" ]]; then
  BACKUP_ENV="$TMP_ROOT/.env.bak"
  mv "$ROOT/config/.env" "$BACKUP_ENV"
fi

HOME_DIR="$TMP_ROOT/home/tester"
mkdir -p "$HOME_DIR/.ssh" "$HOME_DIR/.agents" "$HOME_DIR/projects/secrets" "$HOME_DIR/.claude"
printf '@AGENTS.md\n' > "$HOME_DIR/CLAUDE.md"
printf 'global agents\n' > "$HOME_DIR/AGENTS.md"
printf 'known-host\n' > "$HOME_DIR/.ssh/known_hosts"
printf 'secret=1\n' > "$HOME_DIR/projects/.env"
touch "$HOME_DIR/.claude/.claude.json"

cat > "$ROOT/config/docker-compose.local.yml" <<'EOF'
services:
  claude:
    volumes:
      - ${HOST_HOME}/projects:${HOST_HOME}/projects
x-excludes:
  - ${HOST_HOME}/projects/.env
  - ${HOST_HOME}/projects/secrets
EOF

echo
echo "═══ preflight override generation ═══"
(
  export PATH="$FAKE_BIN:$PATH"
  export FAKE_DOCKER_LOG="$LOG"
  export TMPDIR="$TMPDIR_TEST"
  export HOME="$HOME_DIR"
  export HOST_HOME="$HOME_DIR"
  export HOST_USER=tester
  export HOST_UID=1000
  export CLAUDE_CONFIG_DIR="$HOME_DIR/.claude"
  export ALLOWED_BIND_MOUNTS=/tmp/already-set
  export GITHUB_TOKEN=dummy
  export GIT_USER_NAME='Test User'
  export GIT_USER_EMAIL='test@example.com'
  export GOPRIVATE=
  export GONOSUMDB=
  "$ROOT/bin/claude-docker-ctrl" start > "$TMP_ROOT/start.out" 2> "$TMP_ROOT/start.err"
)

if [[ -x "$ROOT/config/claude-notifier" ]]; then
  ok "claude-notifier auto-created from example"
else
  fail "claude-notifier was not auto-created"
fi

if ls "$TMPDIR_TEST"/claude-docker-context.* >/dev/null 2>&1 \
  && grep -Rqs '/CLAUDE.md:.*CLAUDE.md:ro' "$TMPDIR_TEST"/claude-docker-context.*; then
  ok "global CLAUDE.md override created"
else
  fail "missing CLAUDE.md override file"
fi

if grep -Rqs '/AGENTS.md:.*AGENTS.md:ro' "$TMPDIR_TEST"/claude-docker-context.*; then
  ok "global AGENTS.md override created"
else
  fail "missing AGENTS.md override file"
fi

if ls "$TMPDIR_TEST"/claude-docker-ssh.* >/dev/null 2>&1 \
  && grep -Rqs '.ssh/known_hosts:.*known_hosts:ro' "$TMPDIR_TEST"/claude-docker-ssh.*; then
  ok "known_hosts override created"
else
  fail "missing known_hosts override"
fi

if ls "$TMPDIR_TEST"/claude-docker-agents.* >/dev/null 2>&1 \
  && grep -Rqs '/.agents:.*\.agents' "$TMPDIR_TEST"/claude-docker-agents.*; then
  ok "~/.agents override created"
else
  fail "missing ~/.agents override"
fi

if ls "$TMPDIR_TEST"/claude-docker-excludes.* >/dev/null 2>&1 \
  && grep -Rqs "/dev/null:$HOME_DIR/projects/.env:ro" "$TMPDIR_TEST"/claude-docker-excludes.* \
  && grep -Rqs "$HOME_DIR/projects/secrets:ro,size=0" "$TMPDIR_TEST"/claude-docker-excludes.*; then
  ok "x-excludes override created for file and directory"
else
  fail "missing x-excludes override"
fi

if ls "$TMPDIR_TEST"/claude-docker-pi-worker.* >/dev/null 2>&1; then
  fail "pi worker override created although PI_WORKER_VERSION is unset"
else
  ok "no pi worker override without PI_WORKER_VERSION"
fi

if grep -q ' build ' "$LOG" && grep -q ' up -d ' "$LOG"; then
  ok "start runs docker compose build and up"
else
  fail "start did not issue expected docker compose commands"
fi

if grep -qE ' compose .* config -q($| )' "$LOG"; then
  ok "compose files validated"
else
  fail "compose validation config -q call missing"
fi

# Validation uses `config -q`; preset ALLOWED_BIND_MOUNTS should only skip the
# later bare `config` call that derives bind mounts.
if awk '/ compose / && / config/ && !/(^| )-q( |$)/ { found=1 } END { exit found ? 0 : 1 }' "$LOG"; then
  fail "unexpected bind-mount derivation config call"
else
  ok "preset ALLOWED_BIND_MOUNTS skips bind-mount derivation"
fi

if grep -q "Container 'claude-docker' is running." "$TMP_ROOT/start.out"; then
  ok "start prints success banner"
else
  fail "start output missing success banner"
fi

echo
echo "═══ pi worker override ═══"
: > "$LOG"
mkdir -p "$HOME_DIR/.pi/agent"
printf '{"providers":{}}\n' > "$HOME_DIR/.pi/agent/models.json"
(
  export PATH="$FAKE_BIN:$PATH"
  export FAKE_DOCKER_LOG="$LOG"
  export TMPDIR="$TMPDIR_TEST"
  export HOME="$HOME_DIR"
  export HOST_HOME="$HOME_DIR"
  export HOST_USER=tester
  export HOST_UID=1000
  export CLAUDE_CONFIG_DIR="$HOME_DIR/.claude"
  export ALLOWED_BIND_MOUNTS=/tmp/already-set
  export PI_WORKER_VERSION=0.85.1
  export GITHUB_TOKEN=dummy
  export GIT_USER_NAME='Test User'
  export GIT_USER_EMAIL='test@example.com'
  export GOPRIVATE=
  export GONOSUMDB=
  "$ROOT/bin/claude-docker-ctrl" start > "$TMP_ROOT/pi-start.out" 2> "$TMP_ROOT/pi-start.err"
)

if [[ -d "$HOME_DIR/.pi-worker" ]]; then
  ok "pi worker state dir created on the host"
else
  fail "pi worker state dir was not created"
fi

if ls "$TMPDIR_TEST"/claude-docker-pi-worker.* >/dev/null 2>&1 \
  && grep -Rqs "^      - $HOME_DIR/.pi-worker:$HOME_DIR/.pi-worker\$" "$TMPDIR_TEST"/claude-docker-pi-worker.* \
  && grep -Rqs "$HOME_DIR/.pi/agent/models.json:$HOME_DIR/.pi-worker/models.json:ro" "$TMPDIR_TEST"/claude-docker-pi-worker.* \
  && grep -Rqs "PI_CODING_AGENT_DIR: $HOME_DIR/.pi-worker" "$TMPDIR_TEST"/claude-docker-pi-worker.*; then
  ok "pi worker override mounts state dir, read-only models.json and sets PI_CODING_AGENT_DIR"
else
  fail "pi worker override missing or incomplete"
fi

if grep -qE ' compose .*claude-docker-pi-worker\.[^ ]+ .*build' "$LOG"; then
  ok "pi worker override passed to docker compose build"
else
  fail "pi worker override not in compose file list"
fi

echo
echo "═══ pi worker fails fast ═══"
: > "$LOG"
rm -f "$HOME_DIR/.pi/agent/models.json"
if (
  export PATH="$FAKE_BIN:$PATH"
  export FAKE_DOCKER_LOG="$LOG"
  export TMPDIR="$TMPDIR_TEST"
  export HOME="$HOME_DIR"
  export HOST_HOME="$HOME_DIR"
  export HOST_USER=tester
  export HOST_UID=1000
  export CLAUDE_CONFIG_DIR="$HOME_DIR/.claude"
  export ALLOWED_BIND_MOUNTS=/tmp/already-set
  export PI_WORKER_VERSION=0.85.1
  export GITHUB_TOKEN=dummy
  export GIT_USER_NAME='Test User'
  export GIT_USER_EMAIL='test@example.com'
  export GOPRIVATE=
  export GONOSUMDB=
  "$ROOT/bin/claude-docker-ctrl" start > "$TMP_ROOT/pi-missing.out" 2> "$TMP_ROOT/pi-missing.err"
); then
  fail "missing models.json should stop start"
else
  ok "missing models.json exits non-zero"
fi

if grep -q "pi provider config does not exist: $HOME_DIR/.pi/agent/models.json" "$TMP_ROOT/pi-missing.err"; then
  ok "missing models.json names the expected path"
else
  fail "missing models.json error message not printed"
fi

if grep -q ' compose ' "$LOG"; then
  fail "missing models.json should stop before docker compose"
else
  ok "missing models.json stops before docker compose"
fi

if (
  export PATH="$FAKE_BIN:$PATH"
  export FAKE_DOCKER_LOG="$LOG"
  export TMPDIR="$TMPDIR_TEST"
  export HOME="$HOME_DIR"
  export HOST_HOME="$HOME_DIR"
  export HOST_USER=tester
  export HOST_UID=1000
  export CLAUDE_CONFIG_DIR="$HOME_DIR/.claude"
  export ALLOWED_BIND_MOUNTS=/tmp/already-set
  export PI_WORKER_VERSION=latest
  export GITHUB_TOKEN=dummy
  export GIT_USER_NAME='Test User'
  export GIT_USER_EMAIL='test@example.com'
  export GOPRIVATE=
  export GONOSUMDB=
  "$ROOT/bin/claude-docker-ctrl" start > "$TMP_ROOT/pi-latest.out" 2> "$TMP_ROOT/pi-latest.err"
); then
  fail "PI_WORKER_VERSION=latest should be rejected"
else
  ok "non-exact PI_WORKER_VERSION is rejected"
fi

echo
echo "═══ AWS proxy migration prompt halt ═══"
: > "$LOG"
if (
  export PATH="$FAKE_BIN:$PATH"
  export FAKE_DOCKER_LOG="$LOG"
  export TMPDIR="$TMPDIR_TEST"
  export HOME="$HOME_DIR"
  export HOST_HOME="$HOME_DIR"
  export HOST_USER=tester
  export HOST_UID=1000
  export CLAUDE_CONFIG_DIR="$HOME_DIR/.claude"
  export CLAUDE_DOCKER_AWS_PROXY_MIGRATION_CHOICE=s
  export AWS_AI_PROXY_ENABLED=false
  export AWS_CRED_PROXY_PROFILES=legacy
  export GITHUB_TOKEN=dummy
  export GIT_USER_NAME='Test User'
  export GIT_USER_EMAIL='test@example.com'
  export GOPRIVATE=
  export GONOSUMDB=
  "$ROOT/bin/claude-docker-ctrl" start > "$TMP_ROOT/migration-start.out" 2> "$TMP_ROOT/migration-start.err"
); then
  fail "migration steps choice should stop start with non-zero status"
else
  ok "migration steps choice exits non-zero"
fi

if grep -q "Stopping: install and start aws-ai-proxy" "$TMP_ROOT/migration-start.err"; then
  ok "migration steps choice prints stop message"
else
  fail "migration steps choice missing stop message"
fi

if grep -q "Switch to aws-ai-proxy:" "$TMP_ROOT/migration-start.err"; then
  ok "migration steps choice prints install steps"
else
  fail "migration steps choice missing install steps"
fi

if grep -q ' compose ' "$LOG"; then
  fail "migration steps choice should not run docker compose"
else
  ok "migration steps choice stops before docker compose"
fi

echo
echo "═══════════════════════════════"
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] && echo "ALL TESTS PASSED" || { echo "SOME TESTS FAILED"; exit 1; }
