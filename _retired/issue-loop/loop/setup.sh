#!/usr/bin/env bash
# loop/setup.sh — regenerates machine-specific wiring for the issue-loop automation.
#
# Everything portable (hook scripts, prompt template, runner, this script) lives
# in loop/ and is git-tracked, so the automation survives a clone/move (e.g.
# laptop -> server). The only genuinely machine-specific things are the absolute
# paths, which this script bakes into loop/loop-prompt.md and
# .claude/settings.json (gitignored).
#
# Safe to re-run any time: after cloning, after moving/renaming the repo
# directory, or after pulling an update to the pattern files. Hook entries are
# merged by command basename: only OUR entries are replaced (a moved repo
# replaces the stale absolute path); foreign hooks are never touched.
#
# Wires:  PostToolUse(Bash) -> loop/hooks/post-commit-review.sh
#         PreToolUse(Bash)  -> loop/hooks/guard-main-push.sh   (only if the file exists;
#                                                               if absent, a stale entry is removed)
# Then smoke-tests the guard and exits non-zero if it does not behave.
#
# Bash 3.2 compatible. Requires: jq.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd -P)"
cd "$REPO_ROOT"
echo "Repo root: $REPO_ROOT"

command -v jq >/dev/null 2>&1 || { echo "setup.sh: jq is required" >&2; exit 1; }

# 1. Fill {{WORKING_DIR}} into the loop-prompt template -> generated instance.
#    The path is escaped for sed's replacement side (\, & and the # delimiter).
esc_root="$(printf '%s' "$REPO_ROOT" | sed 's/[\\&#]/\\&/g')"
sed "s#{{WORKING_DIR}}#$esc_root#g" loop/loop-prompt.template.md > loop/loop-prompt.md
echo "Regenerated loop/loop-prompt.md"

# 2. Make the shipped scripts executable (git can lose the bit on some copies).
for f in loop/hooks/*.sh loop/run-issues.sh; do
  [ -f "$f" ] && chmod +x "$f"
done

# 3. Merge our hook entries into .claude/settings.json.
mkdir -p .claude
SETTINGS=".claude/settings.json"
[ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"
jq empty "$SETTINGS" 2>/dev/null || { echo "setup.sh: $SETTINGS is not valid JSON; fix or remove it" >&2; exit 1; }

# wire_hook <event> <script basename> <abs command or "" to just remove>
# Removes every hook whose command ends with "/<basename>", drops matcher entries
# left empty, then (if a command is given) appends ours. Re-running yields a
# byte-identical file.
wire_hook() {
  local event="$1" base="$2" cmd="$3" tmp
  tmp="$(mktemp)"
  jq --arg ev "$event" --arg base "$base" --arg cmd "$cmd" '
    .hooks //= {} |
    .hooks[$ev] = (
      (.hooks[$ev] // [])
      | map(.hooks = ((.hooks // []) | map(select(((.command // "") | endswith("/" + $base)) | not))))
      | map(select((.hooks | length) > 0))
    ) |
    if $cmd != "" then
      .hooks[$ev] += [{"matcher": "Bash", "hooks": [{"type": "command", "command": $cmd}]}]
    else . end |
    if (.hooks[$ev] | length) == 0 then del(.hooks[$ev]) else . end |
    if (.hooks | length) == 0 then del(.hooks) else . end
  ' "$SETTINGS" > "$tmp"
  if cmp -s "$tmp" "$SETTINGS"; then rm -f "$tmp"; else mv "$tmp" "$SETTINGS"; fi
}

REVIEW_HOOK="$REPO_ROOT/loop/hooks/post-commit-review.sh"
GUARD_HOOK="$REPO_ROOT/loop/hooks/guard-main-push.sh"

wire_hook PostToolUse post-commit-review.sh "$REVIEW_HOOK"
echo "Wired PostToolUse -> $REVIEW_HOOK"

if [ -f "$GUARD_HOOK" ]; then
  wire_hook PreToolUse guard-main-push.sh "$GUARD_HOOK"
  echo "Wired PreToolUse  -> $GUARD_HOOK"

  # 4. Smoke-test the guard: it must block a push to the base branch and allow
  #    a push of an issue branch. The guard is a mistake-catcher, but one that
  #    silently does nothing is worse than none.
  base="$( (. loop/loop.conf >/dev/null 2>&1; printf '%s' "${BASE_BRANCH:-main}") 2>/dev/null || true)"
  [ -n "$base" ] || base="main"
  rc=0
  printf '%s' "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git push origin $base\"},\"cwd\":\"$REPO_ROOT\"}" \
    | bash "$GUARD_HOOK" >/dev/null 2>&1 || rc=$?
  if [ "$rc" -ne 2 ]; then
    echo "setup.sh: ERROR guard did NOT block 'git push origin $base' (exit $rc); inspect $GUARD_HOOK" >&2
    exit 1
  fi
  rc=0
  printf '%s' "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git push -u origin issue-1\"},\"cwd\":\"$REPO_ROOT\"}" \
    | bash "$GUARD_HOOK" >/dev/null 2>&1 || rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "setup.sh: ERROR guard blocked 'git push -u origin issue-1' (exit $rc); inspect $GUARD_HOOK" >&2
    exit 1
  fi
  echo "Guard self-test passed (blocks push to $base, allows issue branches)"
else
  # No guard shipped (direct mode): make sure a stale entry from an earlier
  # instantiation does not point at a missing file.
  wire_hook PreToolUse guard-main-push.sh ""
fi

echo "Setup complete. Paste loop/loop-prompt.md into /loop to start."
