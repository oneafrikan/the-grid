#!/usr/bin/env bash
# instantiate.sh — cut an automation-factory pattern into a target repo.
#
# Usage:
#   instantiate.sh <pattern> <target-repo-dir> --profile <profile> [options]
#
# Patterns:
#   issue-loop    Autonomous issue-grinding loop with post-commit review hook
#
# Profiles:
#   personal      Direct push to main; cloud /schedule or local scheduling
#   work          Worktree + PR only; guard hook physically blocks push to main
#   mac-mini      Direct push; launchd nightly cron (survives reboot)
#
# Options:
#   --repo <owner/name>         GitHub repo (auto-detected from git remote if omitted)
#   --project-context <text>    One-line project + stack description
#   --verify-cmd <cmd>          Test/lint/smoke command (non-zero on failure; leave blank to skip)
#   --label <label>             Issue opt-in label (default: agent-ready)
#   --review-focus <text>       What the post-commit reviewer should focus on
#   --launchd-hour <0-23>       Hour for nightly launchd run (mac-mini only; default: 2)
#
# Idempotent: safe to re-run. Files are only rewritten if content changed;
# settings.json is merged (never clobbered); CLAUDE.md is never overwritten.
#
# Requires: git, gh (authenticated), jq, claude CLI.
# mac-mini profile also requires: launchctl (macOS built-in).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GRID_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PATTERNS_DIR="$GRID_DIR/automation-factory/patterns"

# ---------------------------------------------------------------------------
# usage
# ---------------------------------------------------------------------------
usage() {
  echo "Usage: instantiate.sh <pattern> <target-repo-dir> --profile <profile> [options]"
  echo ""
  echo "Patterns:  issue-loop"
  echo "Profiles:  personal | work | mac-mini"
  echo "Options:   --repo --project-context --verify-cmd --label --review-focus --launchd-hour"
  echo ""
  echo "Example:"
  echo "  instantiate.sh issue-loop ~/projects/my-app --profile personal"
  exit 1
}

# ---------------------------------------------------------------------------
# arg parsing
# ---------------------------------------------------------------------------
[[ $# -lt 2 ]] && usage

PATTERN="$1"; shift
TARGET_DIR="$(cd "$1" && pwd)"; shift   # resolve to absolute path

PROFILE=""
GH_REPO=""
PROJECT_CONTEXT=""
VERIFY_CMD=""
ISSUE_LABEL="agent-ready"
REVIEW_FOCUS=""
LAUNCHD_HOUR=2

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile)          PROFILE="$2";          shift 2 ;;
    --repo)             GH_REPO="$2";          shift 2 ;;
    --project-context)  PROJECT_CONTEXT="$2";  shift 2 ;;
    --verify-cmd)       VERIFY_CMD="$2";       shift 2 ;;
    --label)            ISSUE_LABEL="$2";      shift 2 ;;
    --review-focus)     REVIEW_FOCUS="$2";     shift 2 ;;
    --launchd-hour)     LAUNCHD_HOUR="$2";     shift 2 ;;
    *) echo "Unknown option: $1"; usage ;;
  esac
done

[[ -z "$PROFILE" ]] && { echo "Error: --profile is required (personal | work | mac-mini)"; exit 1; }
[[ "$PROFILE" =~ ^(personal|work|mac-mini)$ ]] || { echo "Error: profile must be personal, work, or mac-mini"; exit 1; }
[[ "$PATTERN" == "issue-loop" ]] || { echo "Error: unknown pattern '$PATTERN' (available: issue-loop)"; exit 1; }

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------

# Print a section header.
section() { echo ""; echo "=== $* ==="; }

# Write $2 to $1 only if the content differs — idempotent, prints status.
write_if_changed() {
  local path="$1" content="$2"
  if [[ -f "$path" ]] && [[ "$(cat "$path")" == "$content" ]]; then
    echo "  unchanged: $path"
    return
  fi
  printf '%s\n' "$content" > "$path"
  echo "  wrote:     $path"
}

# Prompt for a value if the variable is currently empty.
prompt_if_missing() {
  local var_name="$1" prompt_text="$2" default="$3"
  if [[ -z "${!var_name}" ]]; then
    read -rp "  $prompt_text [${default}]: " input
    printf -v "$var_name" '%s' "${input:-$default}"
  fi
}

# Merge a hook entry into .claude/settings.json (idempotent via jq).
# Args: settings_file hook_type matcher command
merge_hook() {
  local settings_file="$1" hook_type="$2" matcher="$3" command="$4"

  # Create a minimal settings file if none exists.
  [[ -f "$settings_file" ]] || echo '{}' > "$settings_file"

  # Guard: don't corrupt a non-JSON file.
  if ! jq empty "$settings_file" 2>/dev/null; then
    echo "  Warning: $settings_file is not valid JSON — backing up to .bak and starting fresh"
    cp "$settings_file" "$settings_file.bak"
    echo '{}' > "$settings_file"
  fi

  local tmp
  tmp=$(mktemp)

  # Idempotent: add the matcher entry if absent, then add the command if absent.
  jq --arg ht "$hook_type" --arg m "$matcher" --arg cmd "$command" '
    .hooks[$ht] //= [] |
    if (.hooks[$ht] | map(select(.matcher == $m)) | length) == 0
    then .hooks[$ht] += [{"matcher": $m, "hooks": []}]
    else . end |
    .hooks[$ht] |= map(
      if .matcher == $m then
        if (.hooks | map(select(.command == $cmd)) | length) == 0
        then .hooks += [{"type": "command", "command": $cmd}]
        else . end
      else . end
    )
  ' "$settings_file" > "$tmp" && mv "$tmp" "$settings_file"
}

# ---------------------------------------------------------------------------
# prereq check
# ---------------------------------------------------------------------------
check_prereqs() {
  local missing=()
  for cmd in git gh jq claude; do
    command -v "$cmd" &>/dev/null || missing+=("$cmd")
  done
  [[ "$PROFILE" == "mac-mini" ]] && ! command -v tmux &>/dev/null \
    && echo "  note: tmux not found (optional — useful for live observation via SSH)"
  if [[ ${#missing[@]} -gt 0 ]]; then
    echo "Error: missing required tools: ${missing[*]}"
    exit 1
  fi
  gh auth status &>/dev/null || { echo "Error: gh is not authenticated — run: gh auth login"; exit 1; }
  echo "  ok (git, gh, jq, claude all present)"
}

# ---------------------------------------------------------------------------
# auto-detect GitHub repo from the target's git remote
# ---------------------------------------------------------------------------
detect_repo() {
  if [[ -z "$GH_REPO" ]]; then
    local remote_url
    remote_url=$(git -C "$TARGET_DIR" remote get-url origin 2>/dev/null || true)
    if [[ -n "$remote_url" ]]; then
      GH_REPO=$(echo "$remote_url" \
        | sed -E 's#(git@github\.com:|https://github\.com/)##; s#\.git$##')
    fi
    [[ -z "$GH_REPO" ]] && {
      echo "Error: could not detect GitHub repo from git remote. Pass --repo <owner/name>"
      exit 1
    }
    echo "  detected repo: $GH_REPO"
  else
    echo "  repo: $GH_REPO"
  fi
}

# ---------------------------------------------------------------------------
# issue-loop instantiation
# ---------------------------------------------------------------------------
instantiate_issue_loop() {
  local pattern_dir="$PATTERNS_DIR/issue-loop"
  local hooks_dir="$TARGET_DIR/.claude/hooks"
  local settings_file="$TARGET_DIR/.claude/settings.json"

  mkdir -p "$hooks_dir"

  section "Prereqs"
  check_prereqs

  section "Target"
  echo "  dir:     $TARGET_DIR"
  detect_repo
  echo "  profile: $PROFILE"

  section "Configuration"
  prompt_if_missing PROJECT_CONTEXT "One-line project + stack description" "a software project"
  prompt_if_missing REVIEW_FOCUS    "What should the code review focus on?" "correctness, style, and test coverage"

  # -------------------------------------------------------------------------
  # Module 1: post-commit review hook
  # -------------------------------------------------------------------------
  section "Module 1: post-commit review hook"

  local hook_content
  hook_content=$(sed \
    -e "s|{{GH_REPO}}|$GH_REPO|g" \
    -e "s|{{PROJECT_CONTEXT}}|$PROJECT_CONTEXT|g" \
    -e "s|{{REVIEW_FOCUS}}|$REVIEW_FOCUS|g" \
    "$pattern_dir/hooks/post-commit-review.sh")

  write_if_changed "$hooks_dir/post-commit-review.sh" "$hook_content"
  chmod +x "$hooks_dir/post-commit-review.sh"

  merge_hook "$settings_file" "PostToolUse" "Bash" \
    "$TARGET_DIR/.claude/hooks/post-commit-review.sh"
  echo "  wired:     PostToolUse hook in settings.json"

  # -------------------------------------------------------------------------
  # Module 2: loop prompt
  # -------------------------------------------------------------------------
  section "Module 2: loop prompt"

  local loop_content
  loop_content=$(sed \
    -e "s|{{GH_REPO}}|$GH_REPO|g" \
    -e "s|{{WORKING_DIR}}|$TARGET_DIR|g" \
    -e "s|{{PROJECT_CONTEXT}}|$PROJECT_CONTEXT|g" \
    -e "s|{{VERIFY_CMD}}|$VERIFY_CMD|g" \
    -e "s|{{ISSUE_LABEL}}|$ISSUE_LABEL|g" \
    "$pattern_dir/loop-prompt.md")

  write_if_changed "$TARGET_DIR/.claude/loop-prompt.md" "$loop_content"

  # -------------------------------------------------------------------------
  # Work profile: guard hook + worktree helper
  # -------------------------------------------------------------------------
  if [[ "$PROFILE" == "work" ]]; then
    section "Work profile: guard hook"

    # Guard hook — blocks direct push to main/master.
    # TODO: extract to patterns/guard-main-push/ when reused beyond issue-loop.
    local guard_content
    guard_content=$(cat <<'GUARD'
#!/usr/bin/env bash
# guard-main-push — PreToolUse hook: block direct push to main/master.
# Agents must use new-agent-worktree.sh to branch and open a PR instead.
INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // ""')
if echo "$COMMAND" | grep -q 'git push' && echo "$COMMAND" | grep -qE '\b(main|master)\b'; then
  echo "BLOCKED: Direct push to main/master is forbidden on this machine." >&2
  echo "Use: bash .claude/hooks/new-agent-worktree.sh <branch-name>" >&2
  exit 2
fi
GUARD
)
    write_if_changed "$hooks_dir/guard-main-push.sh" "$guard_content"
    chmod +x "$hooks_dir/guard-main-push.sh"

    merge_hook "$settings_file" "PreToolUse" "Bash" \
      "$TARGET_DIR/.claude/hooks/guard-main-push.sh"
    echo "  wired:     PreToolUse guard in settings.json"

    # Smoke-test: verify the guard actually blocks (Rule 5 — trust the output).
    echo "  smoke-testing guard hook..."
    local test_payload='{"tool_name":"Bash","tool_input":{"command":"git push origin main"},"tool_response":""}'
    if echo "$test_payload" | bash "$hooks_dir/guard-main-push.sh" 2>/dev/null; then
      echo "ERROR: guard hook did NOT block push to main — inspect $hooks_dir/guard-main-push.sh" >&2
      exit 1
    fi
    echo "  guard fires correctly (exit 2 on push to main)"

    # Worktree helper — cuts a new branch off origin/main for agent work.
    local worktree_content
    worktree_content=$(cat <<WORKTREE
#!/usr/bin/env bash
# new-agent-worktree.sh — create a worktree off origin/main for an agent branch.
# Usage: bash .claude/hooks/new-agent-worktree.sh <branch-name>
set -euo pipefail
BRANCH="\${1:?Usage: new-agent-worktree.sh <branch-name>}"
REPO_ROOT="\$(git rev-parse --show-toplevel)"
WORKTREE_DIR="\$(dirname "\$REPO_ROOT")/\$(basename "\$REPO_ROOT")-agent-\$BRANCH"
git fetch origin main
git worktree add -b "\$BRANCH" "\$WORKTREE_DIR" origin/main
echo "Worktree ready: \$WORKTREE_DIR"
echo "Open PR with:   gh pr create --head \$BRANCH --base main"
WORKTREE
)
    write_if_changed "$hooks_dir/new-agent-worktree.sh" "$worktree_content"
    chmod +x "$hooks_dir/new-agent-worktree.sh"
  fi

  # -------------------------------------------------------------------------
  # Mac-mini profile: launchd plist
  # -------------------------------------------------------------------------
  if [[ "$PROFILE" == "mac-mini" ]]; then
    section "Mac-mini profile: launchd plist"
    prompt_if_missing LAUNCHD_HOUR "Nightly run hour (0-23)" "2"

    local repo_slug
    repo_slug=$(echo "$GH_REPO" | tr '/' '-')
    local plist_label="com.gareth.issue-loop.$repo_slug"
    local plist_path="$HOME/Library/LaunchAgents/$plist_label.plist"
    local log_path="$HOME/.claude/issue-loop-$repo_slug.log"
    local err_path="$HOME/.claude/issue-loop-$repo_slug.err"

    # ProgramArguments runs bash -l (login shell) so PATH includes homebrew/nvm etc.
    # &amp; is the XML entity for & — required inside plist string values.
    local plist_content
    plist_content=$(cat <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${plist_label}</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>-l</string>
        <string>-c</string>
        <string>cd ${TARGET_DIR} &amp;&amp; claude --dangerously-skip-permissions -p "\$(cat .claude/loop-prompt.md)"</string>
    </array>
    <key>StartCalendarInterval</key>
    <dict>
        <key>Hour</key>
        <integer>${LAUNCHD_HOUR}</integer>
        <key>Minute</key>
        <integer>0</integer>
    </dict>
    <key>EnvironmentVariables</key>
    <dict>
        <key>HOME</key>
        <string>${HOME}</string>
        <key>PATH</key>
        <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
    </dict>
    <key>RunAtLoad</key>
    <false/>
    <key>StandardOutPath</key>
    <string>${log_path}</string>
    <key>StandardErrorPath</key>
    <string>${err_path}</string>
</dict>
</plist>
PLIST
)
    write_if_changed "$plist_path" "$plist_content"
    echo "  To activate:   launchctl load $plist_path"
    echo "  To deactivate: launchctl unload $plist_path"
    echo "  Logs:          $log_path"
  fi

  # -------------------------------------------------------------------------
  # GitHub label
  # -------------------------------------------------------------------------
  section "GitHub label"
  if gh label list --repo "$GH_REPO" --json name 2>/dev/null \
      | jq -e --arg l "$ISSUE_LABEL" '[.[].name] | contains([$l])' &>/dev/null; then
    echo "  label '$ISSUE_LABEL' already exists"
  else
    gh label create "$ISSUE_LABEL" \
      --repo "$GH_REPO" \
      --color "0E8A16" \
      --description "Ready for agent automation" 2>/dev/null \
      && echo "  created label '$ISSUE_LABEL'" \
      || echo "  Warning: could not create label (check repo access)"
  fi

  # -------------------------------------------------------------------------
  # Generate CLAUDE.md (skip if one already exists — don't overwrite human work)
  # -------------------------------------------------------------------------
  section "CLAUDE.md"

  if [[ -f "$TARGET_DIR/CLAUDE.md" ]]; then
    echo "  CLAUDE.md already exists — skipping (review $TARGET_DIR/CLAUDE.md manually)"
  else
    local profile_rules
    case "$PROFILE" in
      personal)
        profile_rules="- Agent may push directly to \`main\`."
        ;;
      work)
        profile_rules=$(cat <<'RULES'
- Agent MUST NOT push to `main` directly — the guard hook enforces this with exit 2.
- Flow: implement → worktree branch → PR → human merges.
- Start a branch with: `bash .claude/hooks/new-agent-worktree.sh <branch-name>`
RULES
)
        ;;
      mac-mini)
        profile_rules="- Agent may push directly to \`main\`.
- Scheduled nightly at ${LAUNCHD_HOUR}:00 via launchd (~/Library/LaunchAgents/)."
        ;;
    esac

    local repo_name="${GH_REPO##*/}"
    local claude_md
    claude_md=$(cat <<CLAUDEMD
# ${repo_name} — Claude context

Auto-generated by \`instantiate.sh\` (automation-factory / issue-loop pattern).
Machine profile: **${PROFILE}**

## What's wired

- **Post-commit review hook** (\`.claude/hooks/post-commit-review.sh\`): PostToolUse
  on Bash — fires after every \`git commit\`, queues an async \`claude -p\` review,
  posts it as a comment on the issue referenced in the commit message (\`#N\`).
- **Loop prompt** (\`.claude/loop-prompt.md\`): drives the autonomous issue-loop.
  Picks the lowest-numbered \`${ISSUE_LABEL}\`-labelled issue, implements, verifies,
  commits, closes, and reschedules for the next.

## Profile rules

${profile_rules}

## Running the loop

\`\`\`
/loop \$(cat .claude/loop-prompt.md)
\`\`\`

## Issue hygiene

- Label issues \`${ISSUE_LABEL}\` to make them eligible.
- \`blocked\` label is auto-applied when verify fails — remove it to retry.
- The review hook reads the \`#N\` in the commit message to know which issue to comment on.

## Allowed agent actions

- Read/write files within \`${TARGET_DIR}\`
- \`git commit\`, \`git push\` (profile rules above apply)
- \`gh issue\` commands (comment, close, label)
${VERIFY_CMD:+- Run: \`${VERIFY_CMD}\`}

## Forbidden

- Force push (\`--force\`)
- Modify \`.claude/settings.json\` or hooks without human review
- Touch files outside \`${TARGET_DIR}\`
CLAUDEMD
)
    write_if_changed "$TARGET_DIR/CLAUDE.md" "$claude_md"
  fi

  # -------------------------------------------------------------------------
  # Done
  # -------------------------------------------------------------------------
  echo ""
  echo "=============================="
  echo "  issue-loop ready"
  echo "=============================="
  echo ""
  echo "  Repo:    $GH_REPO"
  echo "  Profile: $PROFILE"
  echo "  Label:   $ISSUE_LABEL"
  [[ -n "$VERIFY_CMD" ]] && echo "  Verify:  $VERIFY_CMD"
  echo ""
  echo "  Start the loop (in Claude Code inside $TARGET_DIR):"
  echo ""
  echo "    /loop \$(cat .claude/loop-prompt.md)"
  echo ""
  if [[ "$PROFILE" == "personal" || "$PROFILE" == "work" ]]; then
    echo "  Or schedule via the cloud:"
    echo ""
    echo "    /schedule \"nightly at 2am, in $TARGET_DIR: /loop \$(cat .claude/loop-prompt.md)\""
    echo ""
  fi
}

# ---------------------------------------------------------------------------
# dispatch
# ---------------------------------------------------------------------------
case "$PATTERN" in
  issue-loop) instantiate_issue_loop ;;
  *) echo "Error: unknown pattern '$PATTERN' (available: issue-loop)"; usage ;;
esac
