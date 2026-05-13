#!/bin/bash
set -euo pipefail

GIT_REAL="${GIT_REAL_OVERRIDE:-/usr/libexec/git-real/git}"

# Normalize a refname to its full form. Short names (e.g. "main") are
# interpreted as branches under refs/heads/. Anything already under refs/
# is left alone.
__gw_to_full_refname() {
  case "$1" in
    refs/*) printf '%s' "$1" ;;
    *)      printf 'refs/heads/%s' "$1" ;;
  esac
}

# Emit the protected-ref allowlist in full-refname form, one per line.
# Reads GIT_PROTECTED_BRANCHES at call time so tests (and operators) can
# override the list per-invocation.
__gw_protected_refs() {
  local p
  for p in ${GIT_PROTECTED_BRANCHES:-main master}; do
    __gw_to_full_refname "$p"
    printf '\n'
  done
}

# Check if a normalised refname matches the protected allowlist.
__gw_is_protected_ref() {
  local candidate="$1" pref
  while IFS= read -r pref; do
    [ -z "$pref" ] && continue
    [ "$candidate" = "$pref" ] && return 0
  done < <(__gw_protected_refs)
  return 1
}

# Returns 0 if the push should be blocked, 1 if it should be allowed.
# Args: everything after `git push` (the subcommand has already been consumed).
should_block_push() {
  local seen_dashdash=0
  local positionals=()
  local arg

  while [ $# -gt 0 ]; do
    arg="$1"; shift
    if [ "$seen_dashdash" -eq 0 ]; then
      case "$arg" in
        --)
          seen_dashdash=1
          continue
          ;;
        # Options taking a value as the *next* argument. Skipping just the
        # flag would leave the value to be parsed as the remote, letting
        # `-o foo origin HEAD:main` smuggle a protected destination past us.
        --repo|--push-option|--receive-pack|--exec|-o)
          [ $# -gt 0 ] && shift
          continue
          ;;
        -*)
          continue
          ;;
      esac
    fi
    positionals+=("$arg")
  done

  # No remote → nothing to protect; let the real git surface its own error.
  [ "${#positionals[@]}" -eq 0 ] && return 1

  local refspecs=("${positionals[@]:1}")

  # `git push <remote>` with no refspec pushes the current branch. Block
  # iff HEAD points at a protected ref.
  if [ "${#refspecs[@]}" -eq 0 ]; then
    local head_ref
    head_ref=$("$GIT_REAL" symbolic-ref HEAD 2>/dev/null || echo "")
    [ -z "$head_ref" ] && return 1
    __gw_is_protected_ref "$head_ref" && return 0
    return 1
  fi

  local refspec stripped dst norm
  for refspec in "${refspecs[@]}"; do
    # Drop the leading `+` force marker so `+HEAD:refs/heads/main` is parsed
    # as `HEAD:refs/heads/main`.
    stripped="${refspec#+}"
    case "$stripped" in
      *:*) dst="${stripped##*:}" ;;
      *)   dst="$stripped" ;;
    esac
    # Empty dst with no source (rare; e.g. a stray `:`) — skip.
    [ -z "$dst" ] && continue
    norm=$(__gw_to_full_refname "$dst")
    __gw_is_protected_ref "$norm" && return 0
  done

  return 1
}

# Returns 0 if the push includes one or more tags, 1 otherwise.
# Covers the documented forms: `--tags`, `--follow-tags`, `--mirror`, an
# explicit `refs/tags/<name>` refspec destination, and the `<remote> tag
# <name>` two-word shorthand.
should_block_tag_push() {
  local seen_dashdash=0
  local positionals=()
  local arg

  while [ $# -gt 0 ]; do
    arg="$1"; shift
    if [ "$seen_dashdash" -eq 0 ]; then
      case "$arg" in
        --)
          seen_dashdash=1
          continue
          ;;
        --tags|--follow-tags|--mirror)
          return 0
          ;;
        --repo|--push-option|--receive-pack|--exec|-o)
          [ $# -gt 0 ] && shift
          continue
          ;;
        -*)
          continue
          ;;
      esac
    fi
    positionals+=("$arg")
  done

  # `git push <remote> tag <name>` — documented shorthand for pushing a
  # single tag.
  if [ "${#positionals[@]}" -ge 3 ] && [ "${positionals[1]}" = "tag" ]; then
    return 0
  fi

  local refspecs=("${positionals[@]:1}")
  local refspec stripped dst
  for refspec in "${refspecs[@]}"; do
    stripped="${refspec#+}"
    case "$stripped" in
      *:*) dst="${stripped##*:}" ;;
      *)   dst="$stripped" ;;
    esac
    [ -z "$dst" ] && continue
    case "$dst" in
      refs/tags/*) return 0 ;;
    esac
  done

  return 1
}

# When sourced (e.g. by tests), expose the functions and stop here. Without
# this guard the `exec` below would replace the test process with git.
if [ "${BASH_SOURCE[0]:-$0}" != "$0" ]; then
  return 0
fi

# Block push to protected branches and any push that includes tags.
if [ "${1:-}" = "push" ]; then
  shift
  if should_block_tag_push "$@"; then
    echo "git push of tags is blocked inside this container" >&2
    exit 1
  fi
  if should_block_push "$@"; then
    echo "git push to a protected branch is blocked inside this container" >&2
    echo "Protected branches: ${GIT_PROTECTED_BRANCHES:-main master}" >&2
    exit 1
  fi
  exec "$GIT_REAL" push "$@"
fi

# All other git commands pass through.
exec "$GIT_REAL" "$@"
