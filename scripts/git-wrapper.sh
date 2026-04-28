#!/bin/bash
set -euo pipefail

GIT_REAL=/usr/libexec/git-real/git
PROTECTED_BRANCHES="${GIT_PROTECTED_BRANCHES:-main master}"

# git-real is 0700 root:root, so the unprivileged user must escalate via
# sudo. Defense-in-depth only — NOPASSWD sudo still lets a determined
# caller invoke git-real directly. See SECURITY_ISSUES.md.
if [ "$(id -u)" -eq 0 ]; then
  GIT_REAL_CMD=("$GIT_REAL")
else
  GIT_REAL_CMD=(sudo -n \
    --preserve-env=HOME \
    --preserve-env=USER \
    --preserve-env=GIT_AUTHOR_NAME \
    --preserve-env=GIT_AUTHOR_EMAIL \
    --preserve-env=GIT_COMMITTER_NAME \
    --preserve-env=GIT_COMMITTER_EMAIL \
    --preserve-env=GIT_DIR \
    --preserve-env=GIT_WORK_TREE \
    --preserve-env=GIT_SSH \
    --preserve-env=GIT_SSH_COMMAND \
    --preserve-env=GPG_TTY \
    --preserve-env=SSH_AUTH_SOCK \
    -- "$GIT_REAL")
fi

# Block push to protected branches
if [ "${1:-}" = "push" ]; then
  shift
  # Parse args to find the refspec — look for branch names after remote
  remote=""
  branch=""
  for arg in "$@"; do
    case "$arg" in
      -*) continue ;;  # skip flags
      *)
        if [ -z "$remote" ]; then
          remote="$arg"
        else
          # Extract branch name from refspec (e.g., "feature" or "HEAD:main")
          branch="${arg##*:}"
          break
        fi
        ;;
    esac
  done

  # If no explicit branch, check what the current branch is
  if [ -z "$branch" ]; then
    branch=$("${GIT_REAL_CMD[@]}" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
  fi

  for protected in $PROTECTED_BRANCHES; do
    if [ "$branch" = "$protected" ]; then
      echo "git push to '$protected' is blocked inside this container" >&2
      echo "Protected branches: $PROTECTED_BRANCHES" >&2
      exit 1
    fi
  done

  exec "${GIT_REAL_CMD[@]}" push "$@"
fi

# All other git commands pass through
exec "${GIT_REAL_CMD[@]}" "$@"
