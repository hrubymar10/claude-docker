#!/bin/bash
set -euo pipefail

GIT_REAL=/usr/libexec/git-real/git
PROTECTED_BRANCHES="${GIT_PROTECTED_BRANCHES:-main master}"

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
    branch=$("$GIT_REAL" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
  fi

  for protected in $PROTECTED_BRANCHES; do
    if [ "$branch" = "$protected" ]; then
      echo "git push to '$protected' is blocked inside this container" >&2
      echo "Protected branches: $PROTECTED_BRANCHES" >&2
      exit 1
    fi
  done

  exec "$GIT_REAL" push "$@"
fi

# All other git commands pass through
exec "$GIT_REAL" "$@"
