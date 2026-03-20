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

### 3. Authenticate Claude on the host

If you haven't already, install and authenticate the Claude CLI on your host:

```bash
curl -fsSL https://claude.ai/install.sh | bash
claude
# Follow the authentication flow
```

This creates `~/.claude/` and `~/.claude.json` which are mounted into the container.

### 4. Configure your project mounts

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

### 5. Start the container

```bash
bin/claude-docker-ctrl start           # generates a random instance name
bin/claude-docker-ctrl start myproject  # or pick your own name
```

This auto-detects your username, UID, Go version, git identity, and GitHub token. No manual `.env` file needed (see `config/.env.example` if you want to override anything).

### 6. Use Claude

**Terminal:**

```bash
cd ~/projects/my-app
bin/claude-docker-ctrl exec myproject
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
bin/claude-docker-ctrl start [name]    # build image, start instance (random name if omitted)
bin/claude-docker-ctrl stop <name>     # stop instance
bin/claude-docker-ctrl status [name]   # show instance status (all if omitted)
bin/claude-docker-ctrl shell <name>    # fish shell into instance
bin/claude-docker-ctrl exec <name>     # interactive Claude session in instance
bin/claude-docker-ctrl rebuild <name>  # rebuild image from scratch + restart instance
```

Multiple instances can run simultaneously. Each instance creates three containers: `claude-<name>`, `claude-<name>-socket-proxy`, and `claude-<name>-filter-proxy`.

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
│  │  claude-<name>        claude-<name>-socket-proxy │     │
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

## Multi-Instance Support

You can run multiple isolated instances simultaneously, each with its own name:

```bash
bin/claude-docker-ctrl start frontend   # start "frontend" instance
bin/claude-docker-ctrl start backend    # start "backend" instance
bin/claude-docker-ctrl exec frontend    # Claude session in "frontend"
bin/claude-docker-ctrl exec backend     # Claude session in "backend"
bin/claude-docker-ctrl status           # show all running instances
```

### Wrapper Scripts

The wrapper scripts (`bin/claude-docker`, `bin/claude-docker-vscode-wrapper`, `bin/claude-docker-jetbrains-wrapper`) target a specific container. Set `CLAUDE_DOCKER_CONTAINER` to the instance name:

```bash
export CLAUDE_DOCKER_CONTAINER=frontend
```

## CLAUDE_CONFIG_DIR (Profiles)

Use `CLAUDE_CONFIG_DIR` to run instances with separate Claude profiles (auth, settings, memory):

```bash
CLAUDE_CONFIG_DIR=~/.config/claude-work bin/claude-docker-ctrl start work
```

The profile name is derived from the directory name after `claude-` in the config path. A matching per-profile compose override is loaded automatically if it exists. For the example above, `config/docker-compose.local.work.yml` would be merged in addition to the base `config/docker-compose.local.yml`.

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
