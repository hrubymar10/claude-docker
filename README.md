# claude-docker

Run [Claude Code](https://docs.anthropic.com/en/docs/claude-code) in an isolated Docker container instead of directly on your host. The container mirrors your host environment (same paths, UID, shell) so Claude's file references, git configs, and auto-memory all work seamlessly. Works on both macOS and Linux.

## Scope: what this is, what it isn't

This is an **opinionated** project tuned for the way I and my colleagues work day to day. The goal is to keep the daily Claude-Code flow feeling exactly like running `claude` on the host — same paths, same git, same `docker compose` against your project's stack — while putting a soft blanket between Claude and the parts of your machine you'd rather it not touch by accident.

**This is a safety net for *bad prompts*, not *bad actors*.**

The threat model this project addresses is **AI mistakes** — the kind of footguns an LLM can stumble into when interpreting an ambiguous instruction, getting confused about state, or going overboard trying to be helpful. Concretely:

- You're checked out on `master` without realizing it and prompt *"do the changes and push them"*. Claude tries `git push`, the wrapper refuses pushes to protected branches, and you (the human) decide whether to push from the host. No accidental force-push to `master` because Claude didn't pause to ask.
- You write *"make REALLY sure that directory is gone"* and Claude, in its enthusiasm, reaches for `sudo rm -rf /`. The container is the blast radius — only your mounted project dirs are reachable, the host is untouched. Worst case you lose what you mounted, not your home directory.
- A misread file path or runaway loop tries to write somewhere it shouldn't. The bind-mount allowlist confines damage to directories you explicitly opted in.

The threat model this project does **not** address is a deliberately adversarial Claude — an LLM actively crafting multi-step attacks to break out of the sandbox, exfiltrate credentials via sibling containers, or otherwise behave like a hostile insider. If that's your threat model, this isn't the right tool: don't give Claude the Docker socket at all, don't bind-mount `~/.claude`, and consider air-gapped execution.

The friction trade-off goes one way on purpose: **the sandbox must not get in our way**. Standard `docker compose up`, `docker compose exec`, debugger attach, language servers, and the rest of the daily-driver workflow all work without per-project allowlists or extra config. If a hardening proposal would block a legitimate developer flow, it's out of scope for this project — even if it would close a theoretical attack path.

In short: paranoia calibrated to "AI mental breakdown", not to "nation-state in your chat window".

## Siblings

`claude-docker` is one of several sibling projects that apply the same sandboxing model to different AI coding agents. They share the security philosophy (filtered Docker socket, path mirroring, git-push wrapper, scope above) and most of the implementation, but each is adapted to its agent's config and auth model.

| Project | Wraps |
| --- | --- |
| [`claude-docker`](https://github.com/hrubymar10/claude-docker) (this project) | [Claude Code](https://docs.anthropic.com/en/docs/claude-code) |
| [`codex-docker`](https://github.com/hrubymar10/codex-docker) | [OpenAI Codex CLI](https://github.com/openai/codex) |
| [`pi-docker`](https://github.com/hrubymar10/pi-docker) | [pi](https://pi.dev) |

Pick by which agent you actually use day to day. Running more than one in parallel is fine — the containers are independent.

## Features

- **Isolated execution** — Claude runs in an Alpine container, can't touch your host directly
- **Docker socket proxy** — filtered API access via [wollomatic/socket-proxy](https://github.com/wollomatic/socket-proxy), prevents container escape
- **Path mirroring** — `~/project` inside the container = same path on the host (works with both `/Users/` and `/home/`)
- **VSCode integration** — works with the Claude Code extension via process wrapper
- **Session teardown for terminal and IDE callers** — host watchdog plus in-container wrapper clean up orphaned Claude processes even when the parent wrapper dies early
- **GPG commit signing** — import keys into the container for signed commits
- **AWS credentials proxy** — read-only AWS SSO credentials via host-side proxy (no secrets in the container)
- **Pluggable notifications** — customizable `claude-notifier` script for sound/alert integration

## Prerequisites

- macOS (Apple Silicon or Intel) or Linux (amd64/arm64)
- [Docker Desktop](https://www.docker.com/products/docker-desktop/), [OrbStack](https://orbstack.dev/) (macOS), or Docker Engine (Linux)
- [Claude Max subscription](https://claude.ai/) (authenticated via `claude` CLI on host)
- Go (for building the AWS credential proxy and beep server; optional)

## Setup

### 1. Clone and enter the repo

```bash
git clone https://github.com/hrubymar10/claude-docker.git
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

Add to VSCode `settings.json` — `claudeProcessWrapper` requires an absolute path, so point it at the wrapper inside the repo:

```json
{
    "claudeCode.claudeProcessWrapper": "/path/to/claude-docker/bin/claude-docker-vscode-wrapper",
    "claudeCode.useTerminal": false,
    "claudeCode.allowDangerouslySkipPermissions": true
}
```

> **Important:** `useTerminal` must be `false`. When `true`, the wrapper is bypassed and Claude runs on the host.
>
> **Why `allowDangerouslySkipPermissions: true`?** Claude is already running inside the sandbox: the filesystem is limited to your mounted project dirs, the Docker socket is filtered, and `git push` to protected branches is blocked at the wrapper. The container is the safety net, so the per-action permission prompts mostly add friction without adding protection. Leave it off if you mount sensitive directories you don't fully trust Claude with.

## Commands

```bash
bin/claude-docker-ctrl start    # build image, start container
bin/claude-docker-ctrl stop     # stop container
bin/claude-docker-ctrl status   # show container status
bin/claude-docker-ctrl shell    # shell into the container (auto-detects from host $SHELL)
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

## AWS Credentials (Optional)

Claude inside the container can use read-only AWS credentials via a host-side proxy. No AWS credentials are stored in the container — every request is forwarded to the host, which uses its active SSO session.

### How it works

A small Go HTTP server (`aws-cred-proxy/`) runs on the host and serves credentials for explicitly allowlisted profiles only. Inside the container, `~/.aws/config` is auto-generated with `credential_process` entries that `curl` the proxy via `host.docker.internal`.

### Setup

1. Configure [AWS SSO](https://docs.aws.amazon.com/cli/latest/userguide/cli-configure-sso.html) profiles in `~/.aws/config` on the host (e.g. with `ViewOnlyAccess` permission set)

2. Export the allowlist in your shell profile:

   ```bash
   export AWS_CRED_PROXY_PROFILES="my-readonly:us-east-1,my-test-readonly:eu-west-1"
   ```

   Format: `profile_name:region` pairs, comma-separated. Only listed profiles are served — all other requests return 403.

3. Log in to SSO on the host:

   ```bash
   aws sso login --profile my-readonly
   ```

4. Start (or restart) the container:

   ```bash
   bin/claude-docker-ctrl start
   ```

   The proxy builds and starts automatically. You can check its status with `bin/claude-docker-ctrl status`.

### Usage inside the container

```bash
aws s3 ls --profile my-readonly
aws s3 ls --profile my-test-readonly
```

When the SSO session expires (~12h), re-run `aws sso login` on the host — the proxy picks up the new session automatically, no container restart needed.

### Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `AWS_CRED_PROXY_PROFILES` | _(unset)_ | Comma-separated `name:region` pairs. Proxy only starts when set. |
| `AWS_CRED_PROXY_PORT` | `9998` | Port for the credential proxy on the host. |

## SSH Agent Forwarding (Optional)

Claude inside the container can use your host SSH agent for git pushes, `ssh` connections, etc. — no private keys are copied into the container.

### How it works

If `SSH_AUTH_SOCK` is set on the host (i.e. an `ssh-agent` is running), `claude-docker-ctrl start` automatically launches a `socat` TCP relay on `127.0.0.1:19922` that bridges the host's Unix-domain agent socket. Inside the container, `SSH_AUTH_SOCK` is configured to point at the relay over `host.docker.internal`, and `~/.ssh/known_hosts` is bind-mounted in. Use `ssh-add -l` inside the container to confirm the agent is reachable.

### Setup

1. Make sure `socat` is installed on the host. On macOS: `brew install socat`. On Linux: install via your package manager.
2. Make sure your SSH agent is running on the host (this is the default on most systems — `echo "$SSH_AUTH_SOCK"` should print a path).
3. Add your key once: `ssh-add ~/.ssh/id_ed25519` (or whichever key).
4. Start (or restart) the container: `bin/claude-docker-ctrl start`.

### Usage inside the container

```bash
ssh-add -l                   # list keys forwarded from the host agent
git push origin feature-x    # uses the forwarded agent
```

The relay starts on `claude-docker-ctrl start` and stops on `claude-docker-ctrl stop`. Status is shown in `claude-docker-ctrl status`. If `socat` isn't available on the host, the relay is skipped with a warning and the rest of the container still starts normally.

### Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `SSH_AUTH_SOCK` | _(host)_ | Read from your shell environment. If unset, no relay is started. |

## GitLab CLI (glab) (Optional)

The `glab` CLI is pre-installed, mirroring the bundled `gh` (GitHub CLI). The key thing to understand: the GitLab **API** — which is everything `glab` does (merge requests, pipelines, issues) — can only authenticate with a **token**, never an SSH key. SSH keys cover git transport only.

So there are two independent layers:

- **Git push/pull/clone** to GitLab — already works with **no token** via [SSH agent forwarding](#ssh-agent-forwarding-optional). Nothing to configure beyond the agent.
- **The `glab` CLI** — needs a token. There's no SSH-key path to the GitLab API (same as `gh`).

### Setup

1. Authenticate `glab` once **on the host** (OAuth web flow — no manual PAT needed):

   ```bash
   glab auth login --hostname gitlab.com --web
   ```

   Alternatively, set `GITLAB_TOKEN` in `config/.env` to a Personal Access Token with the `api` scope.

2. Start (or rebuild) the container: `bin/claude-docker-ctrl start`. `claude-docker-ctrl` reads the host token via `glab config get token` and passes it into the container as `GITLAB_TOKEN`, where `glab` picks it up automatically.

Git transport is left on SSH — no `git@gitlab.com:` → HTTPS rewrite is applied, so existing remotes keep using the forwarded agent. A credential helper is still configured for `https://$GITLAB_HOST`, so HTTPS remotes work too when a token is present.

### Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `GITLAB_TOKEN` | `$(glab config get token --host gitlab.com)` | Token for the `glab` CLI. Auto-detected from the host glab, or set explicitly. |
| `GITLAB_HOST` | `gitlab.com` | Set only for self-managed GitLab. |

## Beeper (Optional)

A tiny host-side HTTP server that plays a sound when Claude pings it. Useful as a notification channel — e.g., have your `claude-notifier` hook fire `curl http://host.docker.internal:9999/beep` whenever Claude finishes a long-running task or hits a permission prompt.

### Setup

1. Start the beeper:

   ```bash
   bin/claude-docker-ctrl beeper-start
   ```

   The Go binary is built on first run.

2. Stop it when you're done:

   ```bash
   bin/claude-docker-ctrl beeper-stop
   ```

3. Wire your `claude-notifier` script (see `config/claude-notifier.example`) to call the beeper. The container reaches the host at `host.docker.internal:9999`.

### Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `BEEPER_BIND` | `127.0.0.1:9999` | `host:port` to listen on. Host must be an IP literal (no hostnames). Set to `0.0.0.0:9999` to expose on all interfaces. |
| `BEEPER_ALLOW` | `127.0.0.0/8` | Comma-separated source IPs / CIDRs allowed to call the beeper. Bare IPs are normalised to `/32` (v4) / `/128` (v6). Anything else gets a 403. |

The defaults are sufficient for container-to-host traffic via `host.docker.internal` on Docker Desktop / OrbStack (it forwards to host loopback). For VPN clients or other remote callers, widen `BEEPER_BIND` and add the source range to `BEEPER_ALLOW`:

```bash
export BEEPER_BIND=0.0.0.0:9999
export BEEPER_ALLOW=127.0.0.0/8,172.28.47.0/24
```

**Linux note:** on Linux Docker Engine, `host.docker.internal` resolves to the Docker bridge gateway (typically in `172.17.0.0/16` or `172.16.0.0/12`), not host loopback. The default `BEEPER_ALLOW=127.0.0.0/8` will block those requests. Add the bridge subnet to the allowlist. Note: `beeper/main.go` calls `afplay` (macOS only) — sound playback does not work on Linux.

`X-Forwarded-For` is not honoured — this is a direct-connection service.

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
│  │  │ bash/zsh/fish,│─────►│ socket-proxy     │     │     │
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

Additionally, the `git` binary is replaced with a wrapper that blocks pushes to protected branches (`main`, `master` by default) and any push that would publish tags (`--tags`, `--follow-tags`, `--mirror`, a `refs/tags/*` refspec, or the `<remote> tag <name>` shorthand). This is defense-in-depth — `git-real` is still callable directly by the unprivileged user, so the wrapper catches *bad-prompt* mistakes but won't defeat a deliberately adversarial Claude (see [Scope](#scope-what-this-is-what-it-isnt)). For real branch/tag protection, enforce it server-side. A `docker` wrapper blocks dangerous subcommands (`run`, `build`, `cp`).

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
| AWS credential proxy | `AWS_CRED_PROXY_PROFILES` env var (see [AWS Credentials](#aws-credentials-optional)) |

## Testing

```bash
bash -n bin/claude-docker bin/claude-docker-ctrl bin/claude-docker-vscode-wrapper bin/claude-docker-jetbrains-wrapper bin/lib/session-cleanup.sh scripts/*.sh test/*.sh
make test
```

Current tests cover:

- mount boundary logic
- credential helper quoting
- session PID file naming
- wrapper behavior with mocked `docker`
- start-time preflight/override generation with mocked `docker`
- `docker compose config` rendering smoke test
- VS Code wrapper forwarding

## License

MIT
