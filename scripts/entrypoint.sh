#!/bin/bash
set -euo pipefail

HOST_USER="${HOST_USER:-user}"
HOST_HOME="${HOST_HOME:-/home/$HOST_USER}"

# ── Seed .claude.json from read-only host mount ─────────────────
# The host file is bind-mounted read-only at /run/.claude.json.host.
# We copy it to the real path so Claude Code gets a normal writable file.
# This avoids the Docker file-bind-mount race condition when multiple
# `docker exec` sessions write concurrently (inode divergence on rename,
# or partial writes on in-place updates).
CLAUDE_JSON_LOCK="/tmp/.claude-docker-json.lock"
if [[ -n "${CLAUDE_CONFIG_DIR:-}" ]]; then
  # Custom config dir is mounted read-write with .claude.json already in it.
  # No seed copy needed — the file is the same as the host mount.
  CLAUDE_JSON="$CLAUDE_CONFIG_DIR/.claude.json"
else
  # Default: seed writable copy from read-only host mount.
  CLAUDE_JSON="$HOST_HOME/.claude.json"
  CLAUDE_JSON_HOST="/run/.claude.json.host"
  if [[ -f "$CLAUDE_JSON_HOST" ]]; then
    cp "$CLAUDE_JSON_HOST" "$CLAUDE_JSON"
    chown "$HOST_USER:$HOST_USER" "$CLAUDE_JSON"
  fi
fi
touch "$CLAUDE_JSON_LOCK"
chown "$HOST_USER:$HOST_USER" "$CLAUDE_JSON_LOCK"
chmod 644 "$CLAUDE_JSON_LOCK"

# ── Wait for Docker socket proxy ─────────────────────────────────
if [[ -n "${DOCKER_HOST:-}" ]]; then
  echo "Waiting for Docker socket proxy..."
  for i in $(seq 1 30); do
    if /usr/bin/docker info >/dev/null 2>&1; then
      break
    fi
    sleep 1
  done
fi

# ── Git credential helper (GITHUB_TOKEN) ─────────────────────────
if [[ -n "${GITHUB_TOKEN:-}" ]]; then
  CRED_HELPER="$HOST_HOME/.git-credential-github"
  printf '#!/bin/sh\nprintf "username=oauth2\\npassword=%%s\\n" "$GITHUB_TOKEN"\n' > "$CRED_HELPER"
  chmod 700 "$CRED_HELPER"
  chown "$HOST_USER:$HOST_USER" "$CRED_HELPER"
  gosu "$HOST_USER" /usr/libexec/git-real/git config --global \
    credential."https://github.com".helper "$CRED_HELPER"
  gosu "$HOST_USER" /usr/libexec/git-real/git config --global \
    url."https://github.com/".insteadOf "git@github.com:"
fi

# ── General git credentials (non-GitHub) ──────────────────────────
if [[ -n "${GIT_AUTH_USER:-}" && -n "${GIT_AUTH_TOKEN:-}" ]]; then
  CRED_HELPER="$HOST_HOME/.git-credential-generic"
  # Write credentials directly (not env var refs) since GIT_AUTH_USER/TOKEN
  # are only available during entrypoint, not in docker exec sessions.
  # Use #!/bin/bash: printf '%q' produces bash-specific quoting (e.g. user\'name)
  # which is valid in bash but not in POSIX sh (ash/dash would misparse it).
  printf '#!/bin/bash\nprintf "username=%%s\\npassword=%%s\\n" %s %s\n' \
    "$(printf '%q' "$GIT_AUTH_USER")" "$(printf '%q' "$GIT_AUTH_TOKEN")" > "$CRED_HELPER"
  chmod 700 "$CRED_HELPER"
  chown "$HOST_USER:$HOST_USER" "$CRED_HELPER"
  gosu "$HOST_USER" /usr/libexec/git-real/git config --global credential.helper "$CRED_HELPER"
fi

# ── Git identity ─────────────────────────────────────────────────
if [[ -n "${GIT_USER_NAME:-}" ]]; then
  gosu "$HOST_USER" /usr/libexec/git-real/git config --global user.name "$GIT_USER_NAME"
fi
if [[ -n "${GIT_USER_EMAIL:-}" ]]; then
  gosu "$HOST_USER" /usr/libexec/git-real/git config --global user.email "$GIT_USER_EMAIL"
fi

# ── Docker registry auth (ghcr.io) ──────────────────────────────
if [[ -n "${GITHUB_TOKEN:-}" ]]; then
  DOCKER_CONFIG="$HOST_HOME/.docker"
  mkdir -p "$DOCKER_CONFIG"
  AUTH=$(echo -n "oauth2:$GITHUB_TOKEN" | base64)
  cat > "$DOCKER_CONFIG/config.json" <<EOF
{"auths":{"ghcr.io":{"auth":"$AUTH"}}}
EOF
  chown -R "$HOST_USER:$HOST_USER" "$DOCKER_CONFIG"
fi

# ── SSH agent forwarding ──────────────────────────────────────────
if [[ -n "${SSH_RELAY_HOST:-}" && -n "${SSH_RELAY_PORT:-}" ]]; then
  SSH_SOCK="/tmp/ssh-agent.sock"
  rm -f "$SSH_SOCK"
  gosu "$HOST_USER" socat UNIX-LISTEN:"$SSH_SOCK",fork \
    TCP:"$SSH_RELAY_HOST":"$SSH_RELAY_PORT" &
  export SSH_AUTH_SOCK="$SSH_SOCK"
  echo "SSH agent forwarding enabled ($SSH_RELAY_HOST:$SSH_RELAY_PORT)"
fi

# ── GPG keys ─────────────────────────────────────────────────────
# Import any key files from /run/gpg-keys/ into the user's keyring.
GPG_KEY_DIR="/run/gpg-keys"
if compgen -G "$GPG_KEY_DIR"/*.asc >/dev/null 2>&1 || \
   compgen -G "$GPG_KEY_DIR"/*.gpg >/dev/null 2>&1; then
  GNUPG_DIR="$HOST_HOME/.gnupg"
  gosu "$HOST_USER" mkdir -p "$GNUPG_DIR"
  echo "allow-loopback-pinentry" > "$GNUPG_DIR/gpg-agent.conf"
  echo "pinentry-mode loopback"  > "$GNUPG_DIR/gpg.conf"
  chown "$HOST_USER:$HOST_USER" "$GNUPG_DIR/gpg-agent.conf" "$GNUPG_DIR/gpg.conf"

  echo "Importing GPG keys..."
  for keyfile in "$GPG_KEY_DIR"/*.asc "$GPG_KEY_DIR"/*.gpg; do
    [[ -f "$keyfile" ]] || continue
    gosu "$HOST_USER" gpg --batch --import "$keyfile" 2>&1 | grep -E "^gpg:" || true
  done
fi

# ── Drop to host user and exec CMD ──────────────────────────────
exec gosu "$HOST_USER" "$@"
