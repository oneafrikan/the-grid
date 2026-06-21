#!/usr/bin/env bash
# post-commit-review — Module 1 of the issue-loop pattern.
#
# A Claude Code PostToolUse hook (matcher: Bash) that fires after EVERY Bash tool
# call. If the command was a `git commit`, it queues a backgrounded `claude -p`
# reviewer on the commit diff and — if the commit message references an issue
# (#N) — posts the review as a comment on that GitHub issue. The review runs
# detached so Claude Code is never blocked.
#
# PATTERN FILE — fill the {{PLACEHOLDERS}} when instantiating into a target repo:
#   {{GH_REPO}}          owner/name, e.g. oneafrikan/games-dev
#   {{PROJECT_CONTEXT}}  one line: what the project is and its stack
#   {{REVIEW_FOCUS}}     what the reviewer should prioritise (e.g. "correctness,
#                        browser compatibility, game UX")
#
# Wire it via settings.snippet.json (PostToolUse → Bash → this script's abs path).
# Requires: jq, gh (authenticated), claude CLI.

set -euo pipefail

# --- 1. Read the tool payload from stdin ---
# Claude Code sends JSON: { tool_name, tool_input, tool_response }.
PAYLOAD=$(cat)
COMMAND=$(echo "$PAYLOAD" | jq -r '.tool_input.command // ""')

# --- 2. Fast exit for non-commit commands ---
# Fires on EVERY bash call — grep is cheap, `claude -p` is not.
echo "$COMMAND" | grep -q "git commit" || exit 0

# --- 3. Gather commit context ---
REPO_DIR=$(pwd)
COMMIT_HASH=$(git -C "$REPO_DIR" log -1 --format="%H" 2>/dev/null)
COMMIT_MSG=$(git -C "$REPO_DIR" log -1 --format="%s" 2>/dev/null)

# Cap the diff so large commits don't make slow/expensive reviews — but be HONEST
# about truncation rather than silently under-reviewing.
DIFF_CAP=400
FULL_DIFF=$(git -C "$REPO_DIR" diff HEAD~1 HEAD 2>/dev/null)
DIFF=$(echo "$FULL_DIFF" | head -"$DIFF_CAP")
TRUNCATED=""
if [ "$(echo "$FULL_DIFF" | wc -l)" -gt "$DIFF_CAP" ]; then
  TRUNCATED=$'\n\n_(diff truncated to '"$DIFF_CAP"$' lines for review — large commit, review is partial)_'
fi

# Extract an issue number if the commit message references one (e.g. "… #3").
ISSUE_NUM=$(echo "$COMMIT_MSG" | grep -oE '#[0-9]+' | head -1 | tr -d '#' || true)

# --- 4. Run the review sub-agent in the background ---
# ( … ) & detaches immediately so Claude Code keeps going.
(
  REVIEW=$(claude -p "You are a code reviewer for {{PROJECT_CONTEXT}}.
Review this commit and give 3-5 bullet points of actionable feedback.
Focus on: {{REVIEW_FOCUS}}. Be concise.

Commit: $COMMIT_MSG

Diff:
$DIFF

Reply with bullet points only, no intro or summary line." 2>/dev/null)

  # Always log locally for an audit trail.
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] Review for ${COMMIT_HASH:0:8} (${COMMIT_MSG}):" >> ~/.claude/hooks.log
  echo "$REVIEW" >> ~/.claude/hooks.log
  echo "---" >> ~/.claude/hooks.log

  # If the commit references an issue, post the review there too.
  if [ -n "$ISSUE_NUM" ]; then
    gh issue comment "$ISSUE_NUM" \
      --repo {{GH_REPO}} \
      --body "**Automated review for \`${COMMIT_HASH:0:8}\`**

$REVIEW
$TRUNCATED

_Posted by post-commit-review hook (automation-factory · issue-loop)_"
  fi
) &

# Exit immediately — the review runs async.
exit 0
