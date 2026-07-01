#!/usr/bin/env bash
# loop/setup.sh — regenerates machine-specific wiring for the issue-loop automation.
#
# Everything portable (hook script, prompt template, this script) lives in loop/
# and is git-tracked, so the automation survives a clone/move (e.g. laptop -> server).
# The only thing that's genuinely machine-specific is the absolute working directory,
# which this script bakes into loop/loop-prompt.md and .claude/settings.json.
#
# Safe to re-run any time: after cloning, after moving/renaming the repo directory,
# or after pulling an update to loop/loop-prompt.template.md.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"
echo "Repo root: $REPO_ROOT"

# 1. Fill {{WORKING_DIR}} into the loop-prompt template -> generated instance.
sed "s#{{WORKING_DIR}}#$REPO_ROOT#g" loop/loop-prompt.template.md > loop/loop-prompt.md
echo "Regenerated loop/loop-prompt.md"

# 2. Hook script has no path placeholders (it resolves its own dir via `pwd` at
#    runtime) -- just make sure it's executable.
chmod +x loop/hooks/post-commit-review.sh

# 3. Wire the hook into .claude/settings.json (create if absent, merge if present).
#    Idempotent: replaces .hooks.PostToolUse wholesale each run, so re-running
#    never appends duplicate entries.
mkdir -p .claude
HOOK_PATH="$REPO_ROOT/loop/hooks/post-commit-review.sh"
if [ -f .claude/settings.json ]; then
  jq --arg cmd "$HOOK_PATH" \
    '.hooks.PostToolUse = [{"matcher": "Bash", "hooks": [{"type": "command", "command": $cmd}]}]' \
    .claude/settings.json > .claude/settings.json.tmp && mv .claude/settings.json.tmp .claude/settings.json
else
  jq -n --arg cmd "$HOOK_PATH" \
    '{"hooks": {"PostToolUse": [{"matcher": "Bash", "hooks": [{"type": "command", "command": $cmd}]}]}}' \
    > .claude/settings.json
fi
echo "Wired .claude/settings.json -> $HOOK_PATH"

echo "Setup complete. Paste loop/loop-prompt.md into /loop to start."
