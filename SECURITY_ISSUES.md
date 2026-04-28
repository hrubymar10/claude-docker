# Known Security Issues & Trade-offs

This document lists known security limitations, intentional trade-offs, and potential escape vectors in the claude-docker sandbox.

## 1. Volume driver bind escape (socket-proxy)

**Status:** Open — no upstream fix available
**Severity:** Medium
**Requires:** Direct HTTP API calls via curl (not exploitable via `docker` CLI wrapper)

The socket-proxy's `allowbindmountfrom` restriction only checks `HostConfig.Binds` and `HostConfig.Mounts` with `Type: "bind"`. It does NOT inspect volume driver options. An attacker can:

1. `POST /volumes/create` with `Driver: "local"`, `DriverOpts: {"type": "none", "device": "/any/host/path", "o": "bind"}`
2. `POST /containers/create` with `Mounts: [{Type: "volume", Source: "escape-vol", ...}]`
3. The proxy allows both requests — the volume mount bypasses `allowbindmountfrom`

**Impact:** Read/write access to arbitrary host paths via the Docker API.

**Mitigations in place:**

**Mitigations in place:**
- `docker-wrapper.sh` blocks `docker run`, `docker volume`, `docker build`, `docker cp` at the CLI level
- Exploiting this requires crafting raw HTTP requests to `tcp://claude-filter-proxy:2375`

## 2. Git push to feature branches and force push

**Status:** By design
**Severity:** Low

The git wrapper blocks push only to protected branches (default: `main`, `master`, configurable via `GIT_PROTECTED_BRANCHES`). Push to all other branches is allowed, including force push (`--force`, `--force-with-lease`).

**Impact:** Claude can push (and force-push) to any non-protected branch.

**Rationale:** This is intentional — Claude needs to push feature branches for PR workflows. Force push on feature branches is standard practice (e.g., after rebase).

## 2a. Git wrapper bypass via NOPASSWD sudo

**Status:** Accepted trade-off (paired with #3)
**Severity:** Low (the wrapper is a usability hint, not a security boundary)

The real git binary at `/usr/libexec/git-real/git` is mode `0700 root:root`, and the wrapper at `/usr/bin/git` escalates via `sudo` to invoke it. This blocks the trivial bypass (`/usr/libexec/git-real/git push -f origin main`).

However, because the container user has `NOPASSWD: ALL` sudo (#3), a caller can still run `sudo /usr/libexec/git-real/git push ...` or `sudo apk add --force-overwrite git` to bypass the protected-branch check.

**Impact:** Force push to protected branches is possible from inside the container with whatever credentials are configured.

**Real fix:** Enforce branch protection server-side (a pre-receive hook on the upstream that rejects pushes to protected branches from this token). The in-container wrapper is best-effort.

## 3. Passwordless sudo inside container

**Status:** By design
**Severity:** Low (contained)

The container user has `NOPASSWD: ALL` sudo access. Claude can escalate to root inside the container at any time.

**Impact:** Full root access inside the container. However, the container itself is unprivileged and restricted by the Docker filter proxy (no `--privileged`, no host namespacing, no dangerous capabilities).

**Rationale:** Required for package installation, system configuration, and other development tasks inside the container.

## 4. Tokens visible in environment and config files

**Status:** Accepted trade-off
**Severity:** Low (container-scoped)

`GITHUB_TOKEN` is visible in:
- Process environment (`/proc/*/environ`, `env` command)
- Git credential helper script (embedded in bash function)
- `~/.docker/config.json` (base64-encoded, not encrypted) for ghcr.io registry auth

**Impact:** Any process running as the container user can read these tokens.

**Mitigations:** Tokens are scoped to the container. The container has no mechanism to exfiltrate them except via network (which is unrestricted — see #6).

## 5. Claude auth token mounted read-write

**Status:** Required for operation
**Severity:** Medium

`~/.claude/` and `~/.claude.json` are bind-mounted read-write into the container. These contain Claude authentication tokens.

**Impact:** A compromised process inside the container could read or modify Claude auth tokens.

**Rationale:** Claude Code requires write access to its auth directory for session management. Read-only mounting breaks functionality.

## 6. No network egress filtering

**Status:** By design
**Severity:** Low

The container has unrestricted outbound network access. It can reach any external host via DNS/HTTP/HTTPS.

**Impact:** A compromised process could exfiltrate data to external services.

**Rationale:** Required for package downloads (npm, go, pip), API calls, git operations, and MCP server communication. Egress filtering would break too many workflows.

## 7. Docker API surface is broad

**Status:** Accepted trade-off
**Severity:** Medium

The socket-proxy allows POST to `/containers/.*`, `/images/.*`, `/volumes/.*`, `/networks/.*`, and more. The filter proxy only inspects container-create request bodies.

**Impact:** Claude can create/delete containers, pull/delete images, create/delete volumes and networks via the Docker API. The filter proxy blocks dangerous container configurations (privileged, host namespacing, dangerous capabilities), but other API operations are unrestricted.

**Mitigations:**

- `docker-wrapper.sh` restricts CLI commands to a safe whitelist
- `docker-filter-proxy` blocks dangerous container-create configurations
- Socket-proxy restricts bind mounts to allowed directories
- Exploiting the broad API surface requires raw HTTP calls, not CLI

## Security layers summary

```text
Claude process
  └─ docker-wrapper.sh    CLI filter: blocks run/build/cp/volume
      └─ docker-filter-proxy  Body inspection: blocks privileged/host-ns/caps
          └─ socket-proxy      URL filter + bind mount allowlist
              └─ Docker daemon
```

```text
Claude process (unprivileged user)
  └─ git-wrapper.sh           Blocks push to protected branches
      └─ sudo                 Escalates to root (git-real is 0700 root:root)
          └─ /usr/libexec/git-real/git
```

Each layer provides defense-in-depth. Bypassing the CLI wrapper still hits the filter proxy; bypassing the filter proxy still hits the socket proxy's bind mount restrictions. The git wrapper is **best-effort only** — see #2a — because `NOPASSWD: ALL` sudo (#3) lets the caller invoke `git-real` directly. Real branch protection must be enforced server-side.
