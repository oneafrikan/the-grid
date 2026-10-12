#!/usr/bin/env bash
# post-commit-review — Module 1 of the issue-loop pattern.
#
# A Claude Code PostToolUse hook (matcher: Bash) that fires after EVERY Bash tool
# call. If the command was a `git commit`, it queues a backgrounded, capped
# `claude -p` review of that commit and posts it where reviewers look: the open
# PR of the current branch, else the issue named by `#N` in the commit subject,
# else only the local log (~/.claude/hooks.log). The review runs detached so
# Claude Code is never blocked.
#
# Settings come from loop/loop.conf (next to this hook's parent dir): GH_REPO,
# PROJECT_CONTEXT, REVIEW_FOCUS. Env overrides: GRID_REVIEW_MODEL (default
# sonnet), GRID_REVIEW_BUDGET_USD (default 1), GRID_CLAUDE (the claude binary).
#
# Stands down (exit 0, no review) when GRID_LOOP_HEADLESS=1 (the headless runner
# does one Opus review per PR) or GRID_REVIEW_RUNNING=1 (recursion guard: the
# reviewer's own session would otherwise trigger this hook again).
#
# Wired by ../setup.sh (PostToolUse -> Bash -> this script's abs path).
# Bash 3.2 compatible. Requires: jq, git, gh (authenticated), claude CLI.

set -euo pipefail

[ "${GRID_LOOP_HEADLESS:-}" = "1" ] && exit 0
[ "${GRID_REVIEW_RUNNING:-}" = "1" ] && exit 0

# --- 1. Read the tool payload from stdin ---
# Claude Code sends JSON: { tool_name, tool_input, tool_response, cwd, ... }.
PAYLOAD="$(cat)"
COMMAND="$(printf '%s' "$PAYLOAD" | jq -r '.tool_input.command // ""')"

# --- 2. Fast exit for non-commit commands ---
# Fires on EVERY bash call, so the test is a cheap regex: a `git` word, optional
# `-C <dir>` / `-c k=v` / `--long-opt` args, then `commit`, anchored at the start
# or after ; & | ( or a newline. `git commit-tree` and `echo "git committed"` do
# not match.
nl=$'\n'
commit_re="(^|[;&|(${nl}])[[:space:]]*git([[:space:]]+(-C[[:space:]]+[^[:space:]]+|-c[[:space:]]+[^[:space:]]+|--[^[:space:]]+))*[[:space:]]+commit([[:space:]]|\$)"
[[ "$COMMAND" =~ $commit_re ]] || exit 0

# --- 3. Gather commit context from the repo the commit happened in ---
REPO_DIR="$(printf '%s' "$PAYLOAD" | jq -r '.cwd // ""')"
[ -n "$REPO_DIR" ] || REPO_DIR="$(pwd)"
COMMIT_HASH="$(git -C "$REPO_DIR" log -1 --format="%H" 2>/dev/null || true)"
[ -n "$COMMIT_HASH" ] || exit 0
COMMIT_MSG="$(git -C "$REPO_DIR" log -1 --format="%s" 2>/dev/null || true)"

# Dedupe: review each commit once. The marker lives in this checkout's own git
# dir (per worktree), so parallel worktrees do not suppress each other.
GIT_DIR_ABS="$(git -C "$REPO_DIR" rev-parse --absolute-git-dir 2>/dev/null || true)"
if [ -n "$GIT_DIR_ABS" ]; then
  LAST_FILE="$GIT_DIR_ABS/post-commit-review.last"
  if [ -f "$LAST_FILE" ] && [ "$(cat "$LAST_FILE")" = "$COMMIT_HASH" ]; then
    exit 0
  fi
  printf '%s\n' "$COMMIT_HASH" > "$LAST_FILE"
fi

# Settings from loop.conf (a tracked file of plain assignments; sourced in a
# subshell so nothing leaks into this shell).
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd -P)"
conf_get() {
  [ -f "$HOOK_DIR/../loop.conf" ] || return 0
  ( . "$HOOK_DIR/../loop.conf" >/dev/null 2>&1; eval "printf '%s' \"\${$1:-}\"" ) 2>/dev/null || true
}
GH_REPO="$(conf_get GH_REPO)"
PROJECT_CONTEXT="$(conf_get PROJECT_CONTEXT)"
REVIEW_FOCUS="$(conf_get REVIEW_FOCUS)"
[ -n "$PROJECT_CONTEXT" ] || PROJECT_CONTEXT="a software project"
[ -n "$REVIEW_FOCUS" ] || REVIEW_FOCUS="correctness, style, test coverage"

# Cap the diff so large commits do not make slow, expensive reviews — but be
# HONEST about truncation rather than silently under-reviewing.
DIFF_CAP=400
FULL_DIFF="$(git -C "$REPO_DIR" show --format= "$COMMIT_HASH" 2>/dev/null || true)"
DIFF="$(printf '%s\n' "$FULL_DIFF" | sed -n "1,${DIFF_CAP}p" | head -c 60000 || true)"
TRUNCATED=""
if [ "$(printf '%s\n' "$FULL_DIFF" | wc -l | tr -d ' ')" -gt "$DIFF_CAP" ]; then
  TRUNCATED=$'\n\n_(diff truncated to '"$DIFF_CAP"$' lines for review — large commit, review is partial)_'
fi

# Where the review is posted: the open PR of the current branch, else the issue
# referenced as #N in the subject, else nowhere (log only).
PR_NUM="$( (cd "$REPO_DIR" && gh pr view --json number -q .number 2>/dev/null) || true)"
ISSUE_NUM="$(printf '%s\n' "$COMMIT_MSG" | grep -oE '#[0-9]+' | sed -n '1p' | tr -d '#' || true)"

CLAUDE_BIN="${GRID_CLAUDE:-claude}"
MODEL="${GRID_REVIEW_MODEL:-sonnet}"
BUDGET="${GRID_REVIEW_BUDGET_USD:-1}"
LOG_FILE="$HOME/.claude/hooks.log"

# --- 4. Run the review in the background ---
# ( ... ) & detaches immediately so Claude Code keeps going. Its stdio is closed
# so the caller never waits on an inherited pipe. (`--tools` takes a variable
# number of values, so another flag follows it: the prompt must not be read as a tool name.)
(
  REVIEW="$(GRID_REVIEW_RUNNING=1 "$CLAUDE_BIN" -p \
    --model "$MODEL" --max-budget-usd "$BUDGET" --tools "" --output-format text \
    "You are a code reviewer for ${PROJECT_CONTEXT}.
Review this commit and give 3-5 bullet points of actionable feedback.
Focus on: ${REVIEW_FOCUS}. Be concise.

Commit: ${COMMIT_MSG}

Diff:
${DIFF}

Reply with bullet points only, no intro or summary line." </dev/null 2>/dev/null || true)"

  # Always log locally for an audit trail.
  mkdir -p "$(dirname "$LOG_FILE")"
  {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Review for ${COMMIT_HASH:0:8} (${COMMIT_MSG}):"
    echo "$REVIEW"
    echo "---"
  } >> "$LOG_FILE"

  [ -n "$REVIEW" ] || exit 0
  BODY="**Automated review for \`${COMMIT_HASH:0:8}\`**

${REVIEW}
${TRUNCATED}

_Posted by post-commit-review hook (automation-factory · issue-loop)_"

  repo_args=()
  [ -z "$GH_REPO" ] || repo_args=(--repo "$GH_REPO")
  if [ -n "$PR_NUM" ]; then
    gh pr comment "$PR_NUM" ${repo_args[@]+"${repo_args[@]}"} --body "$BODY" >/dev/null 2>&1 || true
  elif [ -n "$ISSUE_NUM" ]; then
    gh issue comment "$ISSUE_NUM" ${repo_args[@]+"${repo_args[@]}"} --body "$BODY" >/dev/null 2>&1 || true
  fi
) >/dev/null 2>&1 </dev/null &

# Exit immediately — the review runs async.
exit 0
