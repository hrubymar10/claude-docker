# claude-docker

Docker sandbox for running Claude Code in an isolated Linux container that mirrors the macOS host environment.

## Quick Start

```bash
bin/claude-docker-ctrl start    # build image, start container
bin/claude-docker-ctrl stop     # stop container
bin/claude-docker-ctrl status   # show container status
bin/claude-docker-ctrl shell    # fish shell into the container
bin/claude-docker-ctrl exec     # interactive Claude session in container
bin/claude-docker-ctrl rebuild  # rebuild image from scratch + restart
```

## Project Structure

- `Dockerfile` — Alpine 3.23 image
- `docker-compose.yml` — base container config (auth, socket proxy, filter proxy, Go cache)
- `scripts/` — shell scripts copied into the container at build time:
  - `entrypoint.sh` — runtime setup: socket proxy wait, git credentials, GPG import, user drop
  - `git-wrapper.sh` — blocks `git push` to protected branches. Replaces `/usr/bin/git` to prevent bypass.
  - `docker-wrapper.sh` — allowlists safe docker subcommands, blocks `run`/`build`/`cp`
  - `claude-session.sh` — process-group wrapper that ensures claude + children (gopls) are killed on disconnect
  - `go-install.sh` — Dockerfile helper to download Go by version
- `docker-filter-proxy/` — Go reverse proxy that blocks privileged containers, host namespacing, dangerous capabilities
- `bin/claude-docker` — interactive Claude session in container (`-it`)
- `bin/claude-docker-vscode-wrapper` — VSCode `claudeProcessWrapper` script (`-i` only, no TTY)
- `bin/claude-docker-jetbrains-wrapper` — JetBrains (GoLand/IntelliJ) Claude command wrapper (auto-detects TTY)
- `bin/claude-docker-ctrl` — container lifecycle management
- `config/` — user configuration (gitignored copies + examples):
  - `docker-compose.local.example.yml` — template for project volume mounts
  - `claude-notifier.example` — template for notification script
  - `.env.example` — all configurable env vars
  - `claude-settings.example.json` — example Claude Code hooks
  - `CLAUDE.md.example` — example CLAUDE.md with notifier usage
- `beeper/` — simple Go HTTP server that plays a beep sound on the host (optional)
- `gpg-keys/` — drop GPG private keys here for commit signing (gitignored)

## Volume Mounts

Base `docker-compose.yml` mounts only essentials (`$CLAUDE_CONFIG_DIR`, Go cache, GPG keys). Project directories go in `config/docker-compose.local.yml`:

```bash
cp config/docker-compose.local.example.yml config/docker-compose.local.yml
# Edit config/docker-compose.local.yml — add your project directories
```

The `claude-docker-ctrl` script automatically merges both files. If `config/docker-compose.local.yml` is missing, it warns and continues with base mounts only.

## VSCode Integration

Set in VSCode `settings.json`:
```json
{
    "claudeCode.claudeProcessWrapper": "/usr/local/bin/claude-docker-vscode-wrapper",
    "claudeCode.useTerminal": false
}
```

Symlink the wrapper: `ln -sf $(pwd)/bin/claude-docker-vscode-wrapper /usr/local/bin/claude-docker-vscode-wrapper`

**Critical:** `useTerminal: false` is required — when `true`, the wrapper is ignored and VSCode calls `claude` directly.

**Critical:** The wrapper uses `-i` only, NEVER `-it`. The extension communicates via stdin/stdout stream-json protocol. A TTY (`-t`) injects escape codes that break the protocol and cause the extension to hang.

## JetBrains (GoLand/IntelliJ) Integration

In GoLand → **Settings → Tools → Claude Code** → set **Claude command** to the full path:
```
/path/to/claude-docker/bin/claude-docker-jetbrains-wrapper
```

Optionally symlink it: `ln -sf $(pwd)/bin/claude-docker-jetbrains-wrapper /usr/local/bin/claude-docker-jetbrains-wrapper`

The wrapper auto-detects TTY: uses `-it` in the embedded terminal, `-i` only for non-interactive/stream-json mode. All arguments are passed through to `claude` inside the container.

**Note:** The same MCP IDE tools limitation applies — `mcp__ide__*` tools don't work across the Docker boundary.

## Authentication

Claude Max subscription (not API key). Auth tokens live in `~/.claude/` on the host, which is bind-mounted into the container at the same path. No `ANTHROPIC_API_KEY` needed.

**Requires `CLAUDE_CONFIG_DIR`** — must be exported in your shell profile (e.g. `export CLAUDE_CONFIG_DIR="$HOME/.claude"`). This moves `.claude.json` inside the directory mount, avoiding Docker single-file bind mount corruption ([moby/moby#6011](https://github.com/moby/moby/issues/6011)). See README for migration steps.

### Git Authentication

Two modes are supported (can coexist):

- **HTTPS (GITHUB_TOKEN)** — auto-detected from `gh auth token`. Configures a git credential helper for github.com and rewrites SSH URLs to HTTPS. Also enables ghcr.io Docker registry auth.
- **SSH agent forwarding** — if `SSH_AUTH_SOCK` is set on the host, a socat relay forwards the SSH agent into the container. `~/.ssh/known_hosts` is mounted automatically. No keys are copied — the agent handles auth. Works with any git host (GitHub, GitLab, Bitbucket, etc.).

Both can be active simultaneously (e.g., GITHUB_TOKEN for GitHub HTTPS + SSH agent for GitLab).

## GPG Commit Signing

To enable GPG-signed commits inside the container:

1. Export your private key (without passphrase) into `gpg-keys/`:
   ```bash
   gpg --export-secret-keys --armor <KEY_ID> > gpg-keys/signing.asc
   ```
2. The entrypoint imports all `.asc`/`.gpg` files from `gpg-keys/` at startup
3. Configure signing per-repo (e.g. `git config commit.gpgsign true`)

The `gpg-keys/` directory is gitignored — only `.gitkeep` is committed.

**Note:** Keys must have no passphrase since the container has no TTY for pinentry. If your key has a passphrase, strip it on a temporary keyring before exporting.

## Security: Docker Socket Proxy

Instead of mounting the host Docker socket directly (which allows full host access via raw API calls), a [wollomatic/socket-proxy](https://github.com/wollomatic/socket-proxy) filters Docker API requests:

- The proxy runs as a sibling container (`claude-socket-proxy`) with the host socket mounted read-only
- Claude's container connects via `DOCKER_HOST=tcp://socket-proxy:2375` — no socket mounted
- Only whitelisted API endpoints are forwarded (regex-based URL matching per HTTP method)
- Bind mounts are restricted to allowed directories via `-allowbindmountfrom` (prevents container escape)
- The allowlist is auto-derived from actual volume mounts in both compose files
- A `docker-filter-proxy` (Go reverse proxy) sits between Claude and the socket proxy, inspecting container-create request bodies to block privileged containers, host namespacing (PID/network/user/IPC), dangerous capabilities (SYS_ADMIN, SYS_PTRACE, etc.), device mappings, and network mutations
- The `docker-wrapper.sh` CLI filter remains as defense-in-depth
- To adjust allowed endpoints, edit the `socket-proxy` command in `docker-compose.yml`

### Git Push Protection

The real `/usr/bin/git` is renamed to `/usr/libexec/git-real/git` at build time. The wrapper replaces it at `/usr/bin/git`, so there is no bypass path (e.g., calling `/usr/bin/git push` still hits the wrapper). Push is allowed to all branches except those listed in `GIT_PROTECTED_BRANCHES` (default: `main master`).

See `SECURITY_ISSUES.md` for known escape vectors.

## Design Decisions

- **Path mirroring** — project dirs mounted at the same path as macOS host (`/Users/<user>/...`) so Claude's auto-memory paths, git configs, and file references all align
- **UID mirroring** — container user has same UID as host (501) so bind-mounted files have correct ownership
- **Go symlink** — `/opt/go/go.darwin-arm64` → `/usr/local/go` covers any hardcoded macOS Go path references
- **`sleep infinity` CMD** — container stays alive, Claude is invoked on-demand via `docker exec`
- **Go module cache** — `$GOPATH/pkg` is mounted (platform-independent source). Build cache is NOT shared (platform-specific compiled objects)
- **Local compose override** — user-specific mounts in `config/docker-compose.local.yml` keep the base config shareable
- **LSP servers pre-installed** — gopls, typescript-language-server, and pyright are included for Claude Code's LSP tool (code navigation in ~50ms vs 30-60s with grep)

## Known Limitations

- **MCP IDE tools don't work** — `mcp__ide__*` tools (getDiagnostics, executeCode) use local transport between VSCode and the Claude process. This bridge doesn't exist across the Docker boundary.
- **MCP HTTPS servers work** — HTTPS-based MCP servers (Atlassian, Notion, etc.) work inside the container. Authenticate MCP plugins from the **host** Claude first (the auth tokens in `~/.claude/` are bind-mounted into the container).
- **Container must be running** — if the container isn't started when VSCode opens, the extension will hang. Always start the container first.
- **Case sensitivity** — macOS is case-insensitive, Linux is case-sensitive. Not an issue for standard Go projects but be aware.
- **`GOPRIVATE` modules** — host credential helpers (macOS Keychain) don't work in Linux. Pass `GITHUB_TOKEN` env var instead; `entrypoint.sh` configures git credential helper from it.
