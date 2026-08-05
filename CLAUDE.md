# claude-docker

Docker sandbox for running Claude Code in an isolated Linux container that mirrors the host environment.

## Quick Start

```bash
bin/claude-docker-ctrl start    # build image, start container
bin/claude-docker-ctrl stop     # stop container
bin/claude-docker-ctrl status   # show container status
bin/claude-docker-ctrl shell    # shell into the container (auto-detects from host $SHELL)
bin/claude-docker-ctrl exec     # interactive Claude session in container
bin/claude-docker-ctrl rebuild  # rebuild image from scratch + restart
```

## Project Structure

- `Dockerfile` — Alpine 3.24 image
- `docker-compose.yml` — base container config (auth, socket proxy, filter proxy, Go cache)
- `scripts/` — shell scripts copied into the container at build time:
  - `entrypoint.sh` — runtime setup: socket proxy wait, git credentials, GPG import, user drop
  - `git-wrapper.sh` — blocks `git push` to protected branches and any `git push` that includes tags (`--tags`, `--follow-tags`, `--mirror`, `refs/tags/*` refspecs, `<remote> tag <name>` shorthand). Replaces `/usr/bin/git`. Defense-in-depth only: `git-real` is still readable+executable by the unprivileged user, so a determined caller can invoke `/usr/libexec/git-real/git` directly. Real branch/tag protection must come from the upstream (server-side hook).
  - `docker-wrapper.sh` — allowlists safe docker subcommands, including `build` and `buildx`, and warns (without blocking) when a build tag would overwrite one of the sibling sandbox images. Replaces `/usr/bin/docker`; direct calls to the real binary still pass through the filtering proxy.
  - `claude-session.sh` — process-group wrapper that ensures claude + children (gopls) are killed on disconnect
  - `go-install.sh` — Dockerfile helper to download Go by version
- `docker-filter-proxy/` — Go reverse proxy that blocks privileged containers, host namespacing, dangerous capabilities
- `bin/claude-docker` — interactive Claude session in container (`-it`)
- `bin/claude-docker-vscode-wrapper` — VSCode `claudeProcessWrapper` script (`-i` only, no TTY)
- `bin/claude-docker-jetbrains-wrapper` — JetBrains (GoLand/IntelliJ) Claude command wrapper (auto-detects TTY)
- `bin/claude-docker-ctrl` — container lifecycle management
- `bin/lib/session-cleanup.sh` — host-side session lifecycle shared by the `bin/` wrappers (and the user's shell function): a detached watchdog HUPs the in-container session when the launching shell dies (double-forks before `setsid` so interactive-zsh job control can't kill it with the terminal; tracks parent identity as PID + start time to survive PID reuse), `reap_stale_sessions` sweeps orphaned sessions whose host client is gone, and when the last session ends the transient `claude daemon` is stopped so armed background tasks can't keep re-invoking Claude unattended
- `config/` — user configuration (gitignored copies + examples):
  - `docker-compose.local.example.yml` — template for project volume mounts
  - `claude-notifier.example` — template for notification script
  - `.env.example` — all configurable env vars
  - `claude-settings.example.json` — example Claude Code hooks
  - `CLAUDE.md.example` — example CLAUDE.md with notifier usage
- `../aws-ai-proxy/` - optional independently running AWS credential proxy consumed when `AWS_AI_PROXY_ENABLED` is true (https://github.com/hrubymar10/aws-ai-proxy)
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

`claudeProcessWrapper` requires an absolute path. Point it directly at the wrapper inside the repo:

```json
{
    "claudeCode.claudeProcessWrapper": "/path/to/claude-docker/bin/claude-docker-vscode-wrapper",
    "claudeCode.useTerminal": false,
    "claudeCode.allowDangerouslySkipPermissions": true
}
```

**Critical:** `useTerminal: false` is required — when `true`, the wrapper is ignored and VSCode calls `claude` directly.

**Recommended:** `allowDangerouslySkipPermissions: true` — the container itself is the sandbox (filtered Docker socket, restricted bind mounts, git-push wrapper, etc.), so the per-action permission prompts mostly add friction without adding protection. Leave it off if you mount sensitive directories you don't fully trust Claude with.

**Critical:** The wrapper uses `-i` only, NEVER `-it`. The extension communicates via stdin/stdout stream-json protocol. A TTY (`-t`) injects escape codes that break the protocol and cause the extension to hang.

## JetBrains (GoLand/IntelliJ) Integration

In GoLand → **Settings → Tools → Claude Code** → set **Claude command** to the full path:
```
/path/to/claude-docker/bin/claude-docker-jetbrains-wrapper
```

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

### GitLab CLI (glab)

The `glab` CLI is pre-installed and mirrors the `gh` setup, with one fundamental difference: the GitLab **API** (everything `glab` does — MRs, pipelines, issues) can only authenticate with a **token**, never an SSH key. SSH keys cover git transport only, which already works via SSH agent forwarding.

- **Token** — `GITLAB_TOKEN` is auto-detected from the host via `glab config get token --host gitlab.com`, or set explicitly in `config/.env`. Populate it on the host once with `glab auth login --hostname gitlab.com --web` (OAuth, no manual PAT), or use a Personal Access Token with the `api` scope.
- **Host** — `GITLAB_HOST` defaults to `gitlab.com`; set it only for self-managed GitLab.
- **Git transport stays on SSH** — unlike the GitHub path, no `insteadOf` rewrite is applied, so existing `git@gitlab.com:` remotes keep pushing/pulling over the forwarded SSH agent. A credential helper is configured for `https://$GITLAB_HOST` so HTTPS remotes also work when the token is present.

### AWS Credentials (Read-Only)

A separately running [`aws-ai-proxy`](https://github.com/hrubymar10/aws-ai-proxy) service serves read-only AWS SSO credentials to the container. Only profiles enabled by that service are exposed.

**Setup:**

1. Configure ViewOnlyAccess SSO profiles in `~/.aws/config` on the host
2. Configure and start `aws-ai-proxy` on the host, then enable consumption in your shell profile or `config/.env`:
   ```bash
   export AWS_AI_PROXY_ENABLED=1
   export AWS_AI_PROXY_URL="http://host.docker.internal:9998"
   ```
3. Log in to SSO on the host: `aws sso login --profile my-readonly`
4. Start/restart the container: `claude-docker-ctrl start`

On start, the control script fetches enabled profiles from `$AWS_AI_PROXY_URL/profiles`. The entrypoint generates `~/.aws/config` inside the container with `credential_process` entries that fetch credentials from that URL.

Upgrade note: legacy `AWS_CRED_PROXY_PROFILES` / `AWS_CRED_PROXY_PORT` values are ignored. `claude-docker-ctrl start` and `rebuild` detect active legacy values in the process environment or `config/.env` when `AWS_AI_PROXY_ENABLED` is not truthy, prompt in a terminal to comment them out, show migration steps and stop, or ignore once, and warn without blocking in non-interactive runs.

**Usage inside the container:**
```bash
aws s3 ls --profile my-readonly          # uses the first profile
aws s3 ls --profile my-test-readonly     # uses the second profile
```

When the SSO session expires (~12h), re-run `aws sso login` on the host — the proxy picks up the new session automatically.

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

## Beeper

Optional host-side HTTP server (`beeper/main.go`) that plays a sound when called. Started by `claude-docker-ctrl beeper-start`. Two env vars control access:

- `BEEPER_BIND` — `host:port` to listen on. Default `127.0.0.1:9999`. Host must be an IP literal (no hostnames). Set to `0.0.0.0:9999` to expose on all interfaces.
- `BEEPER_ALLOW` — comma-separated list of source IPs / CIDRs that may call the beeper. Default `127.0.0.0/8`. Bare IPs are normalised to `/32` (v4) / `/128` (v6). Requests from anywhere else get a `403`.

For container access via `host.docker.internal`, the defaults are sufficient on Docker Desktop (it forwards to host loopback). For VPN clients or other remote access, widen `BEEPER_BIND` and add the source range to `BEEPER_ALLOW`:

```bash
export BEEPER_BIND=0.0.0.0:9999
export BEEPER_ALLOW=127.0.0.0/8,172.28.47.0/24
```

`X-Forwarded-For` is intentionally not honoured — this is a direct-connection service.

## Security: Docker Socket Proxy

Instead of mounting the host Docker socket directly (which allows full host access via raw API calls), a [wollomatic/socket-proxy](https://github.com/wollomatic/socket-proxy) filters Docker API requests:

- The proxy runs as a sibling container (`claude-socket-proxy`) with the host socket mounted read-only
- Claude's container connects via `DOCKER_HOST=tcp://socket-proxy:2375` — no socket mounted
- Only whitelisted API endpoints are forwarded (regex-based URL matching per HTTP method)
- Bind mounts are restricted to allowed directories via `-allowbindmountfrom` (prevents container escape)
- The allowlist is auto-derived from actual volume mounts in both compose files
- A `docker-filter-proxy` (Go reverse proxy) sits between Claude and the socket proxy. It rejects non-canonical API paths, inspects container-create request bodies to block privileged containers, host namespacing (PID/network/user/IPC), dangerous capabilities (SYS_ADMIN, SYS_PTRACE, etc.), device mappings, and network mutations.
- The `docker-wrapper.sh` CLI filter remains as defense-in-depth
- To adjust allowed endpoints, edit the `socket-proxy` command in `docker-compose.yml`

### Git Push Protection

The real `/usr/bin/git` is renamed to `/usr/libexec/git-real/git` at build time and replaced at `/usr/bin/git` by `scripts/git-wrapper.sh`. The wrapper rejects `git push` when the destination is one of the branches listed in `GIT_PROTECTED_BRANCHES` (default: `main master`), parsing refspecs and flag forms (`-f`, `+`, `HEAD:master`, `--repo`, etc.) so the obvious bypasses don't slip through. It also rejects any `git push` that would publish tags — `--tags`, `--follow-tags`, `--mirror`, a `refs/tags/*` refspec destination, and the `git push <remote> tag <name>` shorthand — so Claude can't `git tag` + `git push --tags` an accidental release.

This is **defense-in-depth, not a security boundary.** `git-real` keeps its default `0755 root:root` permissions, so the unprivileged user can still call `/usr/libexec/git-real/git push -f origin main` directly to skip the wrapper. We've consciously kept it that way: locking it down to `0700` only buys partial defense (the container has `NOPASSWD: ALL` sudo, so a determined caller can still escalate), at the cost of friction on every git invocation. The wrapper exists to catch *bad-prompt* mistakes — accidental pushes to `master` — not to defeat a deliberately adversarial Claude. See the README "Scope" section for the threat model.

If you need real branch protection, enforce it server-side (a pre-receive hook on the upstream that rejects pushes to protected refs from this token).

The same wrapper pattern applies to docker, with one important difference: `docker-real` is at `/usr/libexec/docker-real/docker` and the wrapper at `/usr/bin/docker` covers absolute-path invocations. The docker wrapper closes its bypass path because no equivalent friction-tax-on-every-call concern applies.

See `SECURITY_ISSUES.md` for known escape vectors and the residual gaps documented above.

## Design Decisions

- **Path mirroring** — project dirs mounted at the same path as host (`$HOST_HOME/...`) so Claude's auto-memory paths, git configs, and file references all align. Works on both macOS (`/Users/<user>`) and Linux (`/home/<user>`)
- **UID mirroring** — container user has same UID as host (auto-detected via `id -u`) so bind-mounted files have correct ownership
- **Go symlink** — `/opt/go/go.{darwin-arm64,linux-amd64,linux-arm64}` → `/usr/local/go` covers hardcoded Go path references from any host platform
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
