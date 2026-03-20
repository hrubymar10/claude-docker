#!/bin/bash
set -euo pipefail

GIT_REAL=/usr/libexec/git-real/git
PROTECTED_BRANCHES="${GIT_PROTECTED_BRANCHES:-main master}"

# Block push to protected branches
if [ "${1:-}" = "push" ]; then
  shift
  # Parse args to find remote and branch(es).
  # Track flags that consume the next argument so we don't misidentify
  # flag values as remote/branch names.
  remote=""
  branches=()
  skip_next=false
  for arg in "$@"; do
    if $skip_next; then
      skip_next=false
      continue
    fi
    case "$arg" in
      # Flags that take a separate argument — skip the next token
      -o|--push-option|--repo|--receive-pack|--exec|--signed)
        skip_next=true
        continue
        ;;
      # Flags with = value or single-letter flags
      --*=*|-f|-n|-v|-q|-u|--force|--dry-run|--verbose|--quiet|--set-upstream|--all|--mirror|--delete|--tags|--thin|--no-thin|--force-with-lease*|--no-verify|--porcelain|--progress|--prune|--follow-tags|--atomic|--no-signed|--ipv4|--ipv6)
        continue
        ;;
      -*)
        continue
        ;;
      *)
        if [ -z "$remote" ]; then
          remote="$arg"
        else
          # Extract branch name from refspec (e.g., "feature" or "HEAD:main")
          # Normalize refs/heads/X to just X
          local_branch="${arg##*:}"
          local_branch="${local_branch#refs/heads/}"
          branches+=("$local_branch")
        fi
        ;;
    esac
  done

  # If no explicit branch, check what the current branch is
  if [ ${#branches[@]} -eq 0 ]; then
    current=$("$GIT_REAL" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
    if [ -n "$current" ]; then
      branches=("$current")
    fi
  fi

  for branch in "${branches[@]}"; do
    for protected in $PROTECTED_BRANCHES; do
      if [ "$branch" = "$protected" ]; then
        echo "git push to '$protected' is blocked inside this container" >&2
        echo "Protected branches: $PROTECTED_BRANCHES" >&2
        exit 1
      fi
    done
  done

  exec "$GIT_REAL" push "$@"
fi

# All other git commands pass through
exec "$GIT_REAL" "$@"
