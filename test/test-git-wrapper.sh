#!/bin/bash
# Tests for scripts/git-wrapper.sh push protection.
#
# These tests source the wrapper and exercise the should_block_push function
# directly so we can cover the parser without invoking the real git binary.
# The wrapper short-circuits its main `exec` block when sourced.
set -euo pipefail
cd "$(dirname "$0")/.."

# Stub `git-real` repository identity and HEAD lookups. Honour the STUB_*
# variables so tests can simulate different remotes and checkouts.
STUB_GIT=$(mktemp)
cat > "$STUB_GIT" <<'EOF'
#!/bin/bash
if [ "${1:-}" = "symbolic-ref" ] && [ "${2:-}" = "HEAD" ]; then
  printf '%s\n' "${STUB_HEAD_REF:-refs/heads/feature}"
  exit 0
fi
if [ "${1:-}" = "remote" ] && [ "${2:-}" = "get-url" ]; then
  [ "${STUB_REMOTE_MISSING:-0}" = "1" ] && exit 1
  printf '%s\n' "${STUB_REMOTE_URL:-git@github.com:acme/example.git}"
  exit 0
fi
echo "stub git-real: unexpected call: $*" >&2
exit 1
EOF
chmod +x "$STUB_GIT"
export GIT_REAL_OVERRIDE="$STUB_GIT"

# shellcheck disable=SC1091
. scripts/git-wrapper.sh

PASS=0; FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
nope() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

# block NAME -- ARGS...   asserts should_block_push returns 0
block() {
  local name="$1"; shift
  if should_block_push "$@"; then ok "block: $name"
  else nope "should block: $name (args: $*)"; fi
}
# allow NAME -- ARGS...   asserts should_block_push returns non-zero
allow() {
  local name="$1"; shift
  if should_block_push "$@"; then nope "should allow: $name (args: $*)"
  else ok "allow: $name"; fi
}
# tag_block / tag_allow exercise should_block_tag_push.
tag_block() {
  local name="$1"; shift
  if should_block_tag_push "$@"; then ok "tag block: $name"
  else nope "should block tag push: $name (args: $*)"; fi
}
tag_allow() {
  local name="$1"; shift
  if should_block_tag_push "$@"; then nope "should allow tag push: $name (args: $*)"
  else ok "tag allow: $name"; fi
}

echo ""
echo "═══ Vuln 9: full-refname refspec must be normalised ═══"
block "HEAD:refs/heads/main"           origin HEAD:refs/heads/main
block "HEAD:refs/heads/master"         origin HEAD:refs/heads/master
block "force HEAD:refs/heads/main"     origin +HEAD:refs/heads/main
block "delete refs/heads/main"         origin :refs/heads/main

echo ""
echo "═══ Short-name refspec (regression) ═══"
block "origin main"                    origin main
block "origin HEAD:main"               origin HEAD:main
block "origin :main"                   origin :main
block "origin +main"                   origin +main

echo ""
echo "═══ Allowed refspecs ═══"
allow "feature"                        origin feature
allow "HEAD:refs/heads/feature"        origin HEAD:refs/heads/feature
allow "tag (branch check ignores)"     origin refs/tags/v1.0
allow "main as source"                 origin main:feature
allow "feature force"                  origin +feature

echo ""
echo "═══ Flag-with-value bypass ═══"
block "-o val origin HEAD:main"        -o anything origin HEAD:main
block "--push-option val + main"       --push-option foo origin HEAD:refs/heads/main
block "--receive-pack val + main"      --receive-pack /usr/bin/x origin main
block "--repo val + main"              --repo something origin main
block "--exec val + main"              --exec /bin/x origin main
allow "-o val origin feature"          -o anything origin HEAD:feature

echo ""
echo "═══ Attached-value flags ═══"
block "--push-option=val origin main"  --push-option=foo origin main
block "--repo=val origin main"         --repo=x origin main
block "--force-with-lease=v origin main" --force-with-lease=feature origin main
block "--signed=true origin main"      --signed=true origin main
allow "--force origin feature"         --force origin feature

echo ""
echo "═══ -- argument terminator ═══"
block "-- origin main"                 -- origin main
allow "-- origin feature"              -- origin feature

echo ""
echo "═══ No-refspec uses HEAD ═══"
STUB_HEAD_REF=refs/heads/main    block "no-refspec on main"     origin
STUB_HEAD_REF=refs/heads/master  block "no-refspec on master"   origin
STUB_HEAD_REF=refs/heads/feature allow "no-refspec on feature"  origin

echo ""
echo "═══ Multiple refspecs: any protected blocks ═══"
block "feature and main"               origin feature HEAD:refs/heads/main
allow "feature and bug"                origin feature bug

echo ""
echo "═══ Custom protected branches ═══"
GIT_PROTECTED_BRANCHES="develop release" block "develop full"  origin HEAD:refs/heads/develop
GIT_PROTECTED_BRANCHES="develop release" block "release short" origin release
GIT_PROTECTED_BRANCHES="develop release" allow "main not protected" origin main
GIT_PROTECTED_BRANCHES="refs/heads/develop" block "preformatted protected" origin develop

echo ""
echo "═══ Per-repository branch exemptions ═══"
GIT_PROTECTED_BRANCH_EXEMPT_REPOS="github.com/acme/widgets" STUB_REMOTE_URL="git@github.com:acme/widgets.git" allow "SSH remote name" origin main
GIT_PROTECTED_BRANCH_EXEMPT_REPOS="github.com/acme/widgets" STUB_REMOTE_URL="https://GITHUB.COM/acme/widgets.git" allow "HTTPS remote, uppercase host" upstream main
GIT_PROTECTED_BRANCH_EXEMPT_REPOS="github.com/acme/widgets" allow "explicit URL" https://github.com/acme/widgets.git main
GIT_PROTECTED_BRANCH_EXEMPT_REPOS="github.com/acme/widgets" STUB_REMOTE_URL="git@github.com:acme/other.git" block "non-exempt repo" origin main
GIT_PROTECTED_BRANCH_EXEMPT_REPOS="github.com/acme/widgets" STUB_REMOTE_URL="git@github.com:acme/widgets2.git" block "lookalike repo" origin main
GIT_PROTECTED_BRANCH_EXEMPT_REPOS="github.com/acme/widgets" STUB_REMOTE_URL="git@evil.com:acme/widgets.git" block "lookalike host" origin main
GIT_PROTECTED_BRANCH_EXEMPT_REPOS="github.com/acme/widgets" STUB_REMOTE_MISSING=1 block "unresolvable destination" origin main
GIT_PROTECTED_BRANCH_EXEMPT_REPOS="github.com/acme/widgets" STUB_REMOTE_URL=$'git@github.com:acme/other.git\nhttps://github.com/acme/widgets.git' block "mixed push URLs, victim first" dual main
GIT_PROTECTED_BRANCH_EXEMPT_REPOS="github.com/acme/widgets" STUB_REMOTE_URL=$'https://github.com/acme/widgets.git\ngit@github.com:acme/other.git' block "mixed push URLs, exempt first" dual main
GIT_PROTECTED_BRANCH_EXEMPT_REPOS="github.com/acme/widgets" STUB_REMOTE_URL=$'git@github.com:acme/widgets.git\nhttps://GITHUB.COM/acme/widgets.git' allow "all push URLs exempt" dual main
GIT_PROTECTED_BRANCH_EXEMPT_REPOS="github.com/acme/widgets" block "newline in literal URL" $'https://github.com/acme/widgets.git\nhttps://github.com/acme/widgets.git' main
GIT_PROTECTED_BRANCH_EXEMPT_REPOS="" block "empty exemption list" origin main
unset GIT_PROTECTED_BRANCH_EXEMPT_REPOS
block "unset exemption list" origin main

echo ""
echo "═══ Tag pushes are blocked ═══"
tag_block "--tags"                     origin --tags
tag_block "--follow-tags"              --follow-tags origin
tag_block "--mirror"                   --mirror origin
tag_block "refs/tags/v1.0"             origin refs/tags/v1.0
tag_block "force refs/tags/v1.0"       origin +refs/tags/v1.0
tag_block "HEAD:refs/tags/v1.0"        origin HEAD:refs/tags/v1.0
tag_block "delete refs/tags/v1.0"      origin :refs/tags/v1.0
tag_block "tag <name> shorthand"       origin tag v1.0
tag_block "tag with branch refspec"    origin feature refs/tags/v1.0
GIT_PROTECTED_BRANCH_EXEMPT_REPOS="github.com/acme/widgets" STUB_REMOTE_URL="git@github.com:acme/widgets.git" tag_block "exempt destination tag" origin refs/tags/v2.0
tag_allow "branch push, no tags"       origin feature
tag_allow "branch push, full refname"  origin HEAD:refs/heads/feature
tag_allow "force branch, no tags"      origin +feature
tag_allow "no remote"                  ""
tag_allow "no args"

# Cleanup
rm -f "$STUB_GIT"

echo ""
echo "═══════════════════════════════"
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] && echo "ALL TESTS PASSED" || { echo "SOME TESTS FAILED"; exit 1; }
