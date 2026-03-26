# claude-docker

Run [Claude Code](https://docs.anthropic.com/en/docs/claude-code) in an isolated Docker container instead of directly on your host. The container mirrors your host environment (same paths, UID, shell) so Claude's file references, git configs, and auto-memory all work seamlessly. Works on both macOS and Linux.

## Features

- **Isolated execution** — Claude runs in an Alpine container, can't touch your host directly
- **Docker socket proxy** — filtered API access via [wollomatic/socket-proxy](https://github.com/wollomatic/socket-proxy), prevents container escape
- **Path mirroring** — `~/project` inside the container = same path on the host (works with both `/Users/` and `/home/`)
- **VSCode integration** — works with the Claude Code extension via process wrapper
- **GPG commit signing** — import keys into the container for signed commits
- **Pluggable notifications** — customizable `claude-notifier` script for sound/alert integration

## Prerequisites

- macOS (Apple Silicon or Intel) or Linux (amd64/arm64)
- [Docker Desktop](https://www.docker.com/products/docker-desktop/), [OrbStack](https://orbstack.dev/) (macOS), or Docker Engine (Linux)
- [Claude Max subscription](https://claude.ai/) (authenticated via `claude` CLI on host)
- Go (for building the beep server; optional)

## Setup

### 1. Clone and enter the repo

```bash
git clone https://github.com/youruser/claude-docker.git
cd claude-docker
```

### 2. Add `bin/` to your PATH

```bash
# Add to your shell profile (~/.zshrc, ~/.bashrc, etc.)
export PATH="/path/to/claude-docker/bin:$PATH"
```

This makes `claude-docker-ctrl`, `claude-docker`, and the VSCode wrapper available globally.

### 3. Set `CLAUDE_CONFIG_DIR`

Claude Code stores its config in `~/.claude.json`. Docker file-level bind mounts break on atomic writes ([moby/moby#6011](https://github.com/moby/moby/issues/6011)), causing config corruption on Docker Desktop. Setting `CLAUDE_CONFIG_DIR` moves the config file inside `~/.claude/`, which is mounted as a directory — immune to this issue.

**First, quit all running Claude Code instances** (VSCode, terminal, JetBrains).

Then migrate the config file and set the env var:

```bash
# Move config into the directory (skip this if ~/.claude.json doesn't exist yet)
mv ~/.claude.json ~/.claude/.claude.json

# Add to your shell profile (~/.zshrc, ~/.bashrc, etc.)
export CLAUDE_CONFIG_DIR="$HOME/.claude"
```

Restart your shell (or `source` the profile) before proceeding. `claude-docker-ctrl` will refuse to start without this variable set.

### 4. Authenticate Claude on the host

If you haven't already, install and authenticate the Claude CLI on your host:

```bash
curl -fsSL https://claude.ai/install.sh | bash
claude
# Follow the authentication flow
```

This creates `~/.claude/` which is mounted into the container.

### 5. Configure your project mounts

```bash
cp config/docker-compose.local.example.yml config/docker-compose.local.yml
```

Edit `config/docker-compose.local.yml` to mount your project directories:

```yaml
services:
  claude:
    volumes:
      - ${HOST_HOME}/projects:${HOST_HOME}/projects
      - ${HOST_HOME}/work:${HOST_HOME}/work
```

`HOST_HOME` is auto-detected from your `$HOME` — no need to set it manually. Paths are mirrored (same path inside and outside the container).

### 6. Start the container

```bash
bin/claude-docker-ctrl start
```

This auto-detects your username, UID, Go version, git identity, and GitHub token. No manual `.env` file needed (see `config/.env.example` if you want to override anything).

### 7. Use Claude

**Terminal:**

```bash
cd ~/projects/my-app
bin/claude-docker-ctrl exec
```

**VSCode:**

```bash
ln -sf $(pwd)/bin/claude-docker-vscode-wrapper /usr/local/bin/claude-docker-vscode-wrapper
```

Add to VSCode `settings.json`:

```json
{
    "claudeCode.claudeProcessWrapper": "/usr/local/bin/claude-docker-vscode-wrapper",
    "claudeCode.useTerminal": false
}
```

> **Important:** `useTerminal` must be `false`. When `true`, the wrapper is bypassed and Claude runs on the host.

## Commands

```bash
bin/claude-docker-ctrl start    # build image, start container
bin/claude-docker-ctrl stop     # stop container
bin/claude-docker-ctrl status   # show container status
bin/claude-docker-ctrl shell    # fish shell into the container
bin/claude-docker-ctrl exec     # interactive Claude session in container
bin/claude-docker-ctrl rebuild  # rebuild image from scratch + restart
```

## GPG Commit Signing (Optional)

1. Export your private key without passphrase into the `gpg-keys/` directory:

   ```bash
   # Use a temp keyring to strip the passphrase without affecting your real keyring
   export GNUPGHOME=$(mktemp -d)
   gpg --batch --import <(gpg --export-secret-keys --armor YOUR_KEY_ID)
   gpg --pinentry-mode loopback --edit-key YOUR_KEY_ID passwd save
   gpg --export-secret-keys --armor YOUR_KEY_ID > /path/to/claude-docker/gpg-keys/signing.asc
   rm -rf "$GNUPGHOME"
   unset GNUPGHOME
   ```

2. The entrypoint auto-imports all `.asc`/`.gpg` files at startup
3. Configure signing per repo: `git config commit.gpgsign true && git config user.signingkey YOUR_KEY_ID`

The `gpg-keys/` directory is gitignored — keys never get committed.

## How It Works

```
┌─ Host (macOS / Linux) ──────────────────────────────────┐
│                                                          │
│  VSCode ──► claude-docker-vscode-wrapper                 │
│                    │                                     │
│                    ▼                                     │
│  ┌─ Docker ────────────────────────────────────────┐     │
│  │                                                  │     │
│  │  claude-docker          claude-socket-proxy      │     │
│  │  ┌──────────────┐      ┌──────────────────┐     │     │
│  │  │ Claude Code   │ TCP  │ wollomatic/      │     │     │
│  │  │ fish, Go,     │─────►│ socket-proxy     │     │     │
│  │  │ Node.js, git  │      │ (API filtering)  │     │     │
│  │  └──────────────┘      └────────┬─────────┘     │     │
│  │       │                          │               │     │
│  │       │ bind mounts              │ host socket   │     │
│  └───────┼──────────────────────────┼───────────────┘     │
│          │                          │                     │
│     ~/projects               /var/run/docker.sock        │
│     ~/.claude/                                            │
└──────────────────────────────────────────────────────────┘
```

## Security

The container cannot access the host Docker socket directly. All Docker API calls go through a filtering proxy that:

- Only allows whitelisted API endpoints (regex-matched per HTTP method)
- Restricts bind mounts to directories actually mounted in the container
- Auto-derives the allowlist from your compose volume configuration

Additionally, the `git` binary is replaced with a wrapper that blocks pushes to protected branches (`main`, `master` by default), and a `docker` wrapper blocks dangerous subcommands (`run`, `build`, `cp`).

See [SECURITY_ISSUES.md](SECURITY_ISSUES.md) for known limitations.

## LSP Support

The container ships with language servers pre-installed for fast code navigation (~50ms vs 30-60s with grep):

| Language | Server | Plugin name |
|----------|--------|-------------|
| Go | `gopls` | `gopls-lsp@claude-plugins-official` |
| TypeScript/JavaScript | `typescript-language-server` | `typescript-lsp@claude-plugins-official` |
| Python | `pyright` | `pyright-lsp@claude-plugins-official` |

Enable plugins in your `~/.claude/settings.json`:

```json
{
  "enabledPlugins": {
    "gopls-lsp@claude-plugins-official": true,
    "typescript-lsp@claude-plugins-official": true,
    "pyright-lsp@claude-plugins-official": true
  }
}
```

If running Claude Code on the host (without Docker), install the servers locally too:

```bash
# macOS (Homebrew)
brew install go pyright typescript-language-server
# gopls
go install golang.org/x/tools/gopls@latest
```

## Customization

| What | Where |
|------|-------|
| Project mounts | `config/docker-compose.local.yml` |
| Environment overrides | `config/.env` (see `config/.env.example`) |
| Protected branches | `GIT_PROTECTED_BRANCHES` env var (default: `main master`) |
| Allowed docker commands | `scripts/docker-wrapper.sh` |
| Socket proxy API rules | `docker-compose.yml` socket-proxy command |
| GPG keys | `gpg-keys/*.asc` or `*.gpg` |

## License

MIT
