#!/usr/bin/env bash
# loop/setup.sh — renders machine-specific output for the issue-loop and self-tests the guard.
#
# Usage:
#   bash loop/setup.sh                 render loop/loop-prompt.md + guard self-test. Writes NOTHING
#                                      to .claude/settings.json (see D4 below).
#   bash loop/setup.sh --interactive   as above, and ALSO wire the review hook (PostToolUse) and,
#                                      when the file exists, the guard (PreToolUse) into
#                                      <repo>/.claude/settings.json, for a repo where the operator
#                                      chose to run an INTERACTIVE /loop session.
#   bash loop/setup.sh --unwire        remove only OUR entries from .claude/settings.json.
#
# Why the guard is not wired by default (D4): the guard blocks `gh pr merge` and pushes to the base
# branch. It is meant for the headless worker, and reaches it through the runner's per-run
# --settings file. Writing it into a repo's own settings would also block the operator's own
# sessions in that repo. It is NEVER installed in the-grid's settings: the operator's merge-on-green
# sessions there must be able to run `gh pr merge`.
#
# Everything portable (hook scripts, prompt templates, runner, this script) lives in loop/ and is
# git-tracked, so the automation survives a clone or a move. The only machine-specific output is
# the absolute path baked into loop/loop-prompt.md (gitignored, derived).
#
# --interactive / --unwire merge by command basename: only OUR entries are replaced (a moved repo
# replaces the stale absolute path); foreign hooks are never touched; a re-run is byte-identical.
# A settings.json that is not valid JSON makes them exit 1 without modifying it.
#
# Bash 3.2 compatible. Requires: jq, awk.

set -euo pipefail

usage() {
  echo "usage: bash loop/setup.sh [--interactive | --unwire]" >&2
  exit 2
}

ACTION="render"
case "${1:-}" in
  "") ;;
  --interactive) ACTION="interactive" ;;
  --unwire) ACTION="unwire" ;;
  *) usage ;;
esac
[ "$#" -le 1 ] || usage

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd -P)"
cd "$REPO_ROOT"
echo "Repo root: $REPO_ROOT"

command -v jq >/dev/null 2>&1 || { echo "setup.sh: jq is required" >&2; exit 1; }
[ -f loop/loop.conf ] || { echo "setup.sh: loop/loop.conf not found; run scripts/instantiate.sh from the-grid first" >&2; exit 1; }

# --- 1. Render loop/loop-prompt.md from the TRACKED template + loop.conf ---
# The template is never modified (R10.qa.F5). loop.conf is sourced in a subshell (it is only
# assignments) and its values reach awk through the environment, so no value is ever
# interpolated into program text or a sed delimiter. The awk program:
#   - keeps the one MODE block that matches MODE and drops the other plus all marker lines;
#   - replaces {{KEY}} in a SINGLE left-to-right pass (a value is never re-scanned, so a value
#     that contains {{...}} is emitted literally).
render_prompt() {
  (
    # shellcheck disable=SC1091
    . loop/loop.conf >/dev/null 2>&1 || true
    mode="${MODE:-pr}"
    case "$mode" in
      pr|direct) ;;
      *) echo "setup.sh: MODE must be pr or direct (got '$mode')" >&2; exit 1 ;;
    esac
    V_GH_REPO="${GH_REPO:-}"
    V_ISSUE_REPO="${ISSUE_REPO:-${GH_REPO:-}}"
    V_BASE_BRANCH="${BASE_BRANCH:-main}"
    V_ISSUE_LABEL="${ISSUE_LABEL:-ready-for-agent}"
    V_VERIFY_CMD="${VERIFY_CMD:-}"
    [ -n "$V_VERIFY_CMD" ] || V_VERIFY_CMD="(none configured: run the project's own checks)"
    V_PROJECT_CONTEXT="${PROJECT_CONTEXT:-a software project}"
    V_WORKING_DIR="$REPO_ROOT"
    export V_GH_REPO V_ISSUE_REPO V_BASE_BRANCH V_ISSUE_LABEL V_VERIFY_CMD V_PROJECT_CONTEXT V_WORKING_DIR
    awk -v keep="$mode" '
      /^<!-- MODE:/ { if ($0 == "<!-- MODE:" keep " -->") { inskip = 0 } else { inskip = 1 }; next }
      /^<!-- \/MODE -->$/ { inskip = 0; next }
      inskip { next }
      {
        line = $0; out = ""
        while ((i = index(line, "{{")) > 0) {
          j = index(substr(line, i + 2), "}}")
          if (j == 0) break
          k = substr(line, i + 2, j - 1)
          out = out substr(line, 1, i - 1)
          if (("V_" k) in ENVIRON) { out = out ENVIRON["V_" k]; line = substr(line, i + j + 3) }
          else { out = out "{{"; line = substr(line, i + 2) }
        }
        print out line
      }' loop/loop-prompt.template.md
  ) > loop/loop-prompt.md.tmp
  mv loop/loop-prompt.md.tmp loop/loop-prompt.md
}
if [ "$ACTION" = "render" ] || [ "$ACTION" = "interactive" ]; then
  render_prompt
  echo "Regenerated loop/loop-prompt.md"
fi

# --- 2. Make the shipped scripts executable (git can lose the bit on some copies) ---
for f in loop/hooks/*.sh loop/run-issue.sh loop/wake.sh; do
  if [ -f "$f" ]; then chmod +x "$f"; fi
done

REVIEW_HOOK="$REPO_ROOT/loop/hooks/post-commit-review.sh"
GUARD_HOOK="$REPO_ROOT/loop/hooks/guard-main-push.sh"
SETTINGS=".claude/settings.json"

# --- 3. Guard self-test (every mode) ---
# The guard is a mistake-catcher, but one that silently does nothing is worse than none (R10.qa.F1
# was exactly that). It must block a push of the base branch in the plain, quoted and
# path-qualified forms (R10.qa.F14) and allow a push of an issue branch.
selftest_guard() {
  local base rc form
  base="$( (. loop/loop.conf >/dev/null 2>&1; printf '%s' "${BASE_BRANCH:-main}") 2>/dev/null || true)"
  [ -n "$base" ] || base="main"
  for form in "git push origin $base" "git push origin '$base'" "/usr/bin/git push origin $base"; do
    rc=0
    jq -n --arg c "$form" --arg d "$REPO_ROOT" '{tool_name:"Bash",tool_input:{command:$c},cwd:$d}' \
      | bash "$GUARD_HOOK" >/dev/null 2>&1 || rc=$?
    if [ "$rc" -ne 2 ]; then
      echo "setup.sh: ERROR guard did NOT block '$form' (exit $rc); inspect $GUARD_HOOK" >&2
      exit 1
    fi
  done
  rc=0
  jq -n --arg d "$REPO_ROOT" '{tool_name:"Bash",tool_input:{command:"git push -u origin issue-1"},cwd:$d}' \
    | bash "$GUARD_HOOK" >/dev/null 2>&1 || rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "setup.sh: ERROR guard blocked 'git push -u origin issue-1' (exit $rc); inspect $GUARD_HOOK" >&2
    exit 1
  fi
  echo "Guard self-test passed (blocks plain, quoted and path-qualified pushes to $base; allows issue branches)"
}
if [ "$ACTION" != "unwire" ]; then
  if [ -f "$GUARD_HOOK" ]; then
    selftest_guard
  else
    echo "No guard shipped in loop/hooks (direct profile): self-test skipped"
  fi
fi

if [ "$ACTION" = "render" ]; then
  echo "Setup complete. The guard is NOT wired into .claude/settings.json (the runner passes it to the headless worker per run)."
  echo "Paste loop/loop-prompt.md into /loop for an interactive session, or start the runner: bash loop/run-issue.sh"
  exit 0
fi

# --- 4. --interactive / --unwire: merge our entries into .claude/settings.json ---
if [ "$ACTION" = "unwire" ] && [ ! -f "$SETTINGS" ]; then
  echo "Nothing to unwire ($SETTINGS does not exist)"
  exit 0
fi
if [ -f "$SETTINGS" ]; then
  jq empty "$SETTINGS" 2>/dev/null || { echo "setup.sh: $SETTINGS is not valid JSON; fix or remove it" >&2; exit 1; }
else
  mkdir -p .claude
  echo '{}' > "$SETTINGS"
fi

# wire_hook <event> <script basename> <abs command or "" to just remove>
# Removes every hook whose command ends with "/<basename>", drops matcher entries left empty,
# then (if a command is given) appends ours. Re-running yields a byte-identical file.
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

if [ "$ACTION" = "unwire" ]; then
  wire_hook PostToolUse post-commit-review.sh ""
  wire_hook PreToolUse guard-main-push.sh ""
  echo "Removed issue-loop entries from $SETTINGS"
  exit 0
fi

wire_hook PostToolUse post-commit-review.sh "$REVIEW_HOOK"
echo "Wired PostToolUse -> $REVIEW_HOOK"
if [ -f "$GUARD_HOOK" ]; then
  wire_hook PreToolUse guard-main-push.sh "$GUARD_HOOK"
  echo "Wired PreToolUse  -> $GUARD_HOOK"
else
  # No guard shipped (direct profile): drop a stale entry from an earlier instantiation.
  wire_hook PreToolUse guard-main-push.sh ""
fi
echo "Setup complete (interactive). This guard now blocks 'gh pr merge' for EVERY session in this repo; run 'bash loop/setup.sh --unwire' to remove it."
