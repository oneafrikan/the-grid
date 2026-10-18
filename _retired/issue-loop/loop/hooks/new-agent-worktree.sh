#!/usr/bin/env bash
# new-agent-worktree.sh — cut a worktree off origin/<base> for an agent branch.
#
# Usage: bash loop/hooks/new-agent-worktree.sh <branch-name>
# Prints the worktree path on stdout (and nothing else there), so callers can
# `cd "$(bash loop/hooks/new-agent-worktree.sh issue-7)"`.
#
# Layout: <root>/<branch> where <root> = ${LOOP_WORKTREE_ROOT:-<parent of the
# main checkout>/<repo-name>-loop}, i.e. outside the repo, so no ignore rules are
# needed. The base branch comes from loop/loop.conf (default: main).
#
# The branch is created with --no-track: a branch that tracked origin/<base>
# would make a bare `git push` aim at the base branch.
#
# Bash 3.2 compatible.

set -euo pipefail

BRANCH="${1:?Usage: new-agent-worktree.sh <branch-name>}"

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd -P)"
BASE="main"
if [ -f "$HOOK_DIR/../loop.conf" ]; then
  conf_base="$( (. "$HOOK_DIR/../loop.conf" >/dev/null 2>&1; printf '%s' "${BASE_BRANCH:-}") 2>/dev/null || true)"
  [ -z "$conf_base" ] || BASE="$conf_base"
fi

# The MAIN checkout, even when run from inside another worktree: the common git
# dir is <main>/.git, and `--git-common-dir` can be relative, hence the cd/pwd.
COMMON="$(cd "$(git rev-parse --git-common-dir)" && pwd -P)"
REPO_ROOT="${COMMON%/.git}"
ROOT="${LOOP_WORKTREE_ROOT:-$(dirname "$REPO_ROOT")/$(basename "$REPO_ROOT")-loop}"
WT="$ROOT/$BRANCH"

git fetch origin "$BASE" >&2
mkdir -p "$ROOT"
git worktree add --no-track -B "$BRANCH" "$WT" "origin/$BASE" >&2
echo "Open a PR with: gh pr create --head $BRANCH --base $BASE" >&2
echo "$WT"
