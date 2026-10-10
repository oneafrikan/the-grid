#!/usr/bin/env bash
# instantiate.sh — cut an automation-factory pattern into a target repo.
#
# Usage:
#   instantiate.sh <pattern> <target-repo-dir> --profile <profile> [options]
#
# Patterns:
#   issue-loop    Autonomous issue-grinding loop: post-commit review hook, /loop prompt,
#                 and (pr mode) a headless runner, guard hook and worktree helper
#
# Profiles (each sets the default --mode):
#   personal      mode direct: interactive /loop pushes to the base branch
#   work          mode pr: worktree + PR only; guard hook blocks pushes to protected branches
#   mac-mini      mode pr: headless runner on a launchd nightly schedule (plist written, never loaded)
#   linux         mode pr: headless runner on a systemd user timer (units written, never enabled)
#
# Options:
#   --repo <owner/name>         GitHub repo (auto-detected from the git remote if omitted)
#   --project-context <text>    One-line project + stack description
#   --verify-cmd <cmd>          Test/lint/smoke command (non-zero on failure; leave blank to skip)
#   --label <label>             Issue opt-in label (default: ready-for-agent)
#   --review-focus <text>       What the reviewer should focus on
#   --base-branch <branch>      Branch PRs target / direct mode pushes (default: origin/HEAD's branch, else main)
#   --mode <pr|direct>          Integration mode (default by profile; scheduled profiles are pr-only)
#   --max-issues <n>            Issues per headless run (default 3)
#   --max-turns <n>             --max-turns for the worker, if the claude CLI supports it (default 40)
#   --issue-timeout <secs>      Wall-clock cap per worker run (default 1800)
#   --worker-model <m>          Model for the worker (default sonnet)
#   --review-model <m>          Model for the PR review (default opus)
#   --setup-cmd <cmd>           Run in each issue worktree before the agent (e.g. npm ci)
#   --role-labels <a,b,...>     Create a role:<name> label per agent name (issue routing)
#   --schedule-hour <0-23>      Hour for the nightly run (mac-mini, linux; default 2)
#   --launchd-hour <0-23>       Alias of --schedule-hour
#
# Environment: SYSTEMD_USER_DIR (default ~/.config/systemd/user) and LAUNCH_AGENTS_DIR
# (default ~/Library/LaunchAgents) say where unit files go, so tests never write to the real home.
#
# Idempotent: safe to re-run. Files are only rewritten if content changed; loop/loop.conf is
# rendered ONCE and never overwritten (tuned caps survive); settings.json is merged by
# loop/setup.sh; CLAUDE.md is never overwritten.
#
# Never runs systemctl, launchctl, crontab or a state-changing loginctl: it writes the
# files and PRINTS the activation commands for a human.
#
# Requires: git, gh (authenticated: or GH_TOKEN set), jq, claude CLI. Bash 3.2 compatible.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
GRID_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PATTERNS_DIR="$GRID_DIR/automation-factory/patterns"

# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib/render-schedule.sh"

# ---------------------------------------------------------------------------
# usage
# ---------------------------------------------------------------------------
usage() {
  echo "Usage: instantiate.sh <pattern> <target-repo-dir> --profile <profile> [options]"
  echo ""
  echo "Patterns:  issue-loop"
  echo "Profiles:  personal | work | mac-mini | linux"
  echo "Options:   --repo --project-context --verify-cmd --label --review-focus --base-branch --mode"
  echo "           --max-issues --max-turns --issue-timeout --worker-model --review-model --setup-cmd"
  echo "           --role-labels --schedule-hour (alias --launchd-hour)"
  echo ""
  echo "Example:"
  echo "  instantiate.sh issue-loop ~/projects/my-app --profile work --base-branch next"
  exit 1
}

# ---------------------------------------------------------------------------
# arg parsing
# ---------------------------------------------------------------------------
[[ $# -lt 2 ]] && usage

PATTERN="$1"; shift
[[ -d "$1" ]] || { echo "Error: target '$1' is not a directory"; exit 1; }
TARGET_DIR="$(cd "$1" && pwd -P)"; shift   # resolve to absolute path

PROFILE=""
GH_REPO=""
PROJECT_CONTEXT=""
VERIFY_CMD=""
ISSUE_LABEL="ready-for-agent"
REVIEW_FOCUS=""
BASE_BRANCH=""
MODE=""
MAX_ISSUES=3
MAX_TURNS=40
ISSUE_TIMEOUT=1800
WORKER_MODEL="sonnet"
REVIEW_MODEL="opus"
SETUP_CMD=""
ROLE_LABELS=""
SCHEDULE_HOUR=2

# need_value <option> <count of remaining args> — every option takes a value.
need_value() { [[ "$2" -ge 2 ]] || { echo "Error: $1 needs a value"; usage; }; }

while [[ $# -gt 0 ]]; do
  need_value "$1" "$#"
  case "$1" in
    --profile)          PROFILE="$2";          shift 2 ;;
    --repo)             GH_REPO="$2";          shift 2 ;;
    --project-context)  PROJECT_CONTEXT="$2";  shift 2 ;;
    --verify-cmd)       VERIFY_CMD="$2";       shift 2 ;;
    --label)            ISSUE_LABEL="$2";      shift 2 ;;
    --review-focus)     REVIEW_FOCUS="$2";     shift 2 ;;
    --base-branch)      BASE_BRANCH="$2";      shift 2 ;;
    --mode)             MODE="$2";             shift 2 ;;
    --max-issues)       MAX_ISSUES="$2";       shift 2 ;;
    --max-turns)        MAX_TURNS="$2";        shift 2 ;;
    --issue-timeout)    ISSUE_TIMEOUT="$2";    shift 2 ;;
    --worker-model)     WORKER_MODEL="$2";     shift 2 ;;
    --review-model)     REVIEW_MODEL="$2";     shift 2 ;;
    --setup-cmd)        SETUP_CMD="$2";        shift 2 ;;
    --role-labels)      ROLE_LABELS="$2";      shift 2 ;;
    --schedule-hour|--launchd-hour) SCHEDULE_HOUR="$2"; shift 2 ;;
    *) echo "Unknown option: $1"; usage ;;
  esac
done

[[ -z "$PROFILE" ]] && { echo "Error: --profile is required (personal | work | mac-mini | linux)"; exit 1; }
[[ "$PROFILE" =~ ^(personal|work|mac-mini|linux)$ ]] || { echo "Error: profile must be personal, work, mac-mini or linux"; exit 1; }
[[ "$PATTERN" == "issue-loop" ]] || { echo "Error: unknown pattern '$PATTERN' (available: issue-loop)"; exit 1; }

# profile -> default mode; the scheduled profiles run the headless runner, which is pr-only
if [[ -z "$MODE" ]]; then
  case "$PROFILE" in
    personal) MODE="direct" ;;
    *)        MODE="pr" ;;
  esac
fi
[[ "$MODE" =~ ^(pr|direct)$ ]] || { echo "Error: --mode must be pr or direct"; exit 1; }
if [[ "$MODE" == "direct" && ( "$PROFILE" == "mac-mini" || "$PROFILE" == "linux" ) ]]; then
  echo "Error: the $PROFILE profile schedules the headless runner, which is pr-only; use --mode pr"
  exit 1
fi
for n in MAX_ISSUES MAX_TURNS ISSUE_TIMEOUT; do
  [[ "${!n}" =~ ^[0-9]+$ && "${!n}" -ge 1 ]] || { echo "Error: --$(echo "$n" | tr 'A-Z_' 'a-z-') must be a positive integer"; exit 1; }
done
[[ "$SCHEDULE_HOUR" =~ ^[0-9]+$ && "$((10#$SCHEDULE_HOUR))" -le 23 ]] || { echo "Error: --schedule-hour must be 0-23"; exit 1; }
SCHEDULE_HOUR=$((10#$SCHEDULE_HOUR))
[[ -z "$ROLE_LABELS" || "$ROLE_LABELS" =~ ^[A-Za-z0-9._,-]+$ ]] || { echo "Error: --role-labels is a comma-separated list of agent names"; exit 1; }

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------

# Print a section header.
section() { echo ""; echo "=== $* ==="; }

# Write $2 to $1 only if the content differs — idempotent, prints status.
# Sets WRITE_RESULT to new | changed | unchanged.
WRITE_RESULT=""
write_if_changed() {
  local path="$1" content="$2"
  if [[ -f "$path" ]] && [[ "$(cat "$path")" == "$content" ]]; then
    echo "  unchanged: $path"
    WRITE_RESULT="unchanged"
    return
  fi
  if [[ -f "$path" ]]; then WRITE_RESULT="changed"; else WRITE_RESULT="new"; fi
  printf '%s\n' "$content" > "$path"
  echo "  wrote:     $path"
}

# Copy file $1 to $2 only if the bytes differ (a verbatim copy: no newline munging).
copy_if_changed() {
  local src="$1" dst="$2"
  if [[ -f "$dst" ]] && cmp -s "$src" "$dst"; then
    echo "  unchanged: $dst"
    return
  fi
  cp "$src" "$dst"
  echo "  wrote:     $dst"
}

# Prompt for a value if the variable is currently empty. A non-interactive run
# (no terminal on stdin) takes the default instead of blocking on read.
prompt_if_missing() {
  local var_name="$1" prompt_text="$2" default="$3" input=""
  if [[ -z "${!var_name}" ]]; then
    if [[ -t 0 ]]; then
      read -rp "  $prompt_text [${default}]: " input
    fi
    printf -v "$var_name" '%s' "${input:-$default}"
  fi
}

# fill — stdin -> stdout: replace {{NAME}} with $PH_<NAME> for each NAME in $PH_NAMES.
# awk + ENVIRON, so the values (&, |, \, quotes, newlines-free text) are never interpreted.
fill() {
  awk 'BEGIN { n = split(ENVIRON["PH_NAMES"], names, " ") }
    { line = $0
      for (k = 1; k <= n; k++) {
        from = "{{" names[k] "}}"; to = ENVIRON["PH_" names[k]]; out = ""
        while ((i = index(line, from)) > 0) { out = out substr(line, 1, i - 1) to; line = substr(line, i + length(from)) }
        line = out line
      }
      print line }'
}

# select_mode <mode> — stdin -> stdout: keep the <!-- MODE:x --> blocks for <mode>, drop the others, no markers left.
select_mode() {
  awk -v keep="$1" '
    /^<!-- MODE:/ { if ($0 == "<!-- MODE:" keep " -->") { inkeep = 1 } else { inskip = 1 } ; next }
    /^<!-- \/MODE -->$/ { inkeep = 0; inskip = 0; next }
    !inskip { print }'
}

# ---------------------------------------------------------------------------
# prereq check
# ---------------------------------------------------------------------------
check_prereqs() {
  local missing=()
  for cmd in git gh jq claude; do
    command -v "$cmd" &>/dev/null || missing+=("$cmd")
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    echo "Error: missing required tools: ${missing[*]}"
    exit 1
  fi
  # (a loop user has no stored gh login by design: run with GH_TOKEN=<App installation token>)
  gh auth status &>/dev/null || { echo "Error: gh is not authenticated — run: gh auth login (or set GH_TOKEN)"; exit 1; }
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

# detect_base_branch — origin/HEAD's branch, else main.
detect_base_branch() {
  if [[ -z "$BASE_BRANCH" ]]; then
    local ref
    ref=$(git -C "$TARGET_DIR" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null || true)
    BASE_BRANCH="${ref#origin/}"
    [[ -n "$BASE_BRANCH" ]] || BASE_BRANCH="main"
    echo "  base branch: $BASE_BRANCH (detected)"
  else
    echo "  base branch: $BASE_BRANCH"
  fi
}

# ---------------------------------------------------------------------------
# issue-loop instantiation
# ---------------------------------------------------------------------------
instantiate_issue_loop() {
  local pattern_dir="$PATTERNS_DIR/issue-loop"
  # loop/ is a TRACKED top-level folder, not .claude/ — a target repo's
  # .claude/ is commonly gitignored (Claude Code local settings convention),
  # which would make the automation vanish on the next clone/move. Only the
  # genuinely machine-specific wiring (.claude/settings.json's absolute hook
  # paths) lives under .claude/; loop/setup.sh regenerates that on demand.
  local loop_dir="$TARGET_DIR/loop"
  local hooks_dir="$loop_dir/hooks"

  section "Prereqs"
  check_prereqs

  section "Target"
  echo "  dir:     $TARGET_DIR"
  detect_repo
  detect_base_branch
  echo "  profile: $PROFILE"
  echo "  mode:    $MODE"

  section "Configuration"
  prompt_if_missing PROJECT_CONTEXT "One-line project + stack description" "a software project"
  prompt_if_missing REVIEW_FOCUS    "What should the code review focus on?" "correctness, style, and test coverage"

  # -------------------------------------------------------------------------
  # Scheduler text first: rendering validates the install path BEFORE anything is written.
  # The service timeout comes from the EFFECTIVE caps (an existing, hand-tuned loop.conf wins).
  # -------------------------------------------------------------------------
  local repo_slug schedule unit_name="" label="" service_text="" timer_text="" plist_text="" rc
  local e_max="$MAX_ISSUES" e_issue_t="$ISSUE_TIMEOUT" e_review_t=600 vals
  repo_slug="$(render_unit_slug "$GH_REPO")"
  schedule="daily:$(printf '%02d' "$SCHEDULE_HOUR"):00"
  if [[ -f "$loop_dir/loop.conf" ]]; then
    vals="$( (unset MAX_ISSUES ISSUE_TIMEOUT REVIEW_TIMEOUT; . "$loop_dir/loop.conf" >/dev/null 2>&1; \
      printf '%s %s %s' "${MAX_ISSUES:-}" "${ISSUE_TIMEOUT:-}" "${REVIEW_TIMEOUT:-}") 2>/dev/null || true)"
    # shellcheck disable=SC2086
    set -- $vals
    if [[ "${1:-}" =~ ^[0-9]+$ ]]; then e_max="$1"; fi
    if [[ "${2:-}" =~ ^[0-9]+$ ]]; then e_issue_t="$2"; fi
    if [[ "${3:-}" =~ ^[0-9]+$ ]]; then e_review_t="$3"; fi
  fi
  unit_name="issue-loop-$repo_slug"
  if [[ "$PROFILE" == "linux" ]]; then
    rc=0
    service_text="$(render_systemd_service "issue-loop runner for $GH_REPO" "$TARGET_DIR" \
      "$((e_max * (e_issue_t + e_review_t) + 600))" /bin/bash "$TARGET_DIR/loop/run-issues.sh")" || rc=$?
    if [[ $rc -eq 0 ]]; then
      timer_text="$(render_systemd_timer "Nightly issue-loop for $GH_REPO" "$unit_name.service" "$schedule")" || rc=$?
    fi
    if [[ $rc -ne 0 ]]; then
      echo "Error: install path contains unsafe characters; move the repo or job dir ($TARGET_DIR)" >&2
      exit 2
    fi
  elif [[ "$PROFILE" == "mac-mini" ]]; then
    rc=0
    label="io.the-grid.issue-loop.$repo_slug"
    plist_text="$(render_launchd_plist "$label" "$HOME" "$TARGET_DIR" "$HOME/.grid/logs" "$schedule" \
      /bin/bash "$TARGET_DIR/loop/run-issues.sh")" || rc=$?
    if [[ $rc -ne 0 ]]; then
      echo "Error: install path contains unsafe characters; move the repo or job dir ($TARGET_DIR)" >&2
      exit 2
    fi
  fi

  mkdir -p "$hooks_dir"

  # -------------------------------------------------------------------------
  # Module 1: post-commit review hook (verbatim: it reads loop/loop.conf at run time)
  # -------------------------------------------------------------------------
  section "Module 1: post-commit review hook"
  copy_if_changed "$pattern_dir/hooks/post-commit-review.sh" "$hooks_dir/post-commit-review.sh"
  chmod +x "$hooks_dir/post-commit-review.sh"

  # -------------------------------------------------------------------------
  # Module 2: loop prompt + machine wiring
  # -------------------------------------------------------------------------
  section "Module 2: loop prompt + wiring"

  # loop-prompt.template.md keeps {{WORKING_DIR}} as the only unfilled
  # placeholder — the rest don't vary by machine, so bake them in now. Exactly one
  # of the MODE blocks survives, with no marker left behind.
  local prompt_content
  prompt_content=$(select_mode "$MODE" < "$pattern_dir/loop-prompt.template.md" \
    | PH_NAMES="GH_REPO PROJECT_CONTEXT VERIFY_CMD ISSUE_LABEL BASE_BRANCH" \
      PH_GH_REPO="$GH_REPO" PH_PROJECT_CONTEXT="$PROJECT_CONTEXT" PH_VERIFY_CMD="$VERIFY_CMD" \
      PH_ISSUE_LABEL="$ISSUE_LABEL" PH_BASE_BRANCH="$BASE_BRANCH" fill)

  write_if_changed "$loop_dir/loop-prompt.template.md" "$prompt_content"
  copy_if_changed "$pattern_dir/setup.sh" "$loop_dir/setup.sh"
  copy_if_changed "$pattern_dir/.gitignore" "$loop_dir/.gitignore"
  chmod +x "$loop_dir/setup.sh"

  # loop.conf: rendered ONCE. %q-quoting keeps spaces and && in values intact when it is sourced.
  local q_names="GH_REPO BASE_BRANCH ISSUE_LABEL MODE VERIFY_CMD SETUP_CMD PROJECT_CONTEXT REVIEW_FOCUS MAX_ISSUES MAX_TURNS ISSUE_TIMEOUT WORKER_MODEL REVIEW_MODEL"
  local conf_text
  conf_text=$(PH_NAMES="$q_names" \
    PH_GH_REPO="$(printf '%q' "$GH_REPO")" PH_BASE_BRANCH="$(printf '%q' "$BASE_BRANCH")" \
    PH_ISSUE_LABEL="$(printf '%q' "$ISSUE_LABEL")" PH_MODE="$(printf '%q' "$MODE")" \
    PH_VERIFY_CMD="$(printf '%q' "$VERIFY_CMD")" PH_SETUP_CMD="$(printf '%q' "$SETUP_CMD")" \
    PH_PROJECT_CONTEXT="$(printf '%q' "$PROJECT_CONTEXT")" PH_REVIEW_FOCUS="$(printf '%q' "$REVIEW_FOCUS")" \
    PH_MAX_ISSUES="$MAX_ISSUES" PH_MAX_TURNS="$MAX_TURNS" PH_ISSUE_TIMEOUT="$ISSUE_TIMEOUT" \
    PH_WORKER_MODEL="$(printf '%q' "$WORKER_MODEL")" PH_REVIEW_MODEL="$(printf '%q' "$REVIEW_MODEL")" \
    fill < "$pattern_dir/loop.conf.template")
  if [[ ! -e "$loop_dir/loop.conf" ]]; then
    write_if_changed "$loop_dir/loop.conf" "$conf_text"
  elif [[ "$(cat "$loop_dir/loop.conf")" == "$conf_text" ]]; then
    echo "  unchanged: $loop_dir/loop.conf"
  else
    echo "  loop.conf exists, left alone: $loop_dir/loop.conf (it differs from what these options would render; edit it by hand)"
  fi

  # -------------------------------------------------------------------------
  # pr mode: headless runner, App-token minter, guard hook, worktree helper
  # (shipped pattern files, copied verbatim: no heredocs, one source of truth)
  # -------------------------------------------------------------------------
  if [[ "$MODE" == "pr" ]]; then
    section "PR mode: runner, token minter, guard hook, worktree helper"
    copy_if_changed "$pattern_dir/run-issues.sh" "$loop_dir/run-issues.sh"
    copy_if_changed "$GRID_DIR/scripts/lib/gh-app-token.sh" "$loop_dir/gh-app-token.sh"
    copy_if_changed "$pattern_dir/hooks/guard-main-push.sh" "$hooks_dir/guard-main-push.sh"
    copy_if_changed "$pattern_dir/hooks/new-agent-worktree.sh" "$hooks_dir/new-agent-worktree.sh"
    chmod +x "$loop_dir/run-issues.sh" "$loop_dir/gh-app-token.sh" \
      "$hooks_dir/guard-main-push.sh" "$hooks_dir/new-agent-worktree.sh"
  fi

  # setup.sh fills {{WORKING_DIR}} -> loop/loop-prompt.md, makes the scripts
  # executable, merges the PostToolUse review hook and (when shipped) the PreToolUse
  # guard into .claude/settings.json and self-tests the guard. It is the SAME script
  # a future clone/move re-runs by hand, so instantiate-time and regenerate-time
  # wiring never drift apart.
  bash "$loop_dir/setup.sh"

  # -------------------------------------------------------------------------
  # Scheduler files (written, never activated)
  # -------------------------------------------------------------------------
  local unit_dir="" unit_changed=0 plist_path="" log_dir="" linger="" cron_line="" env_file_hint="\$HOME/.config/the-grid/issue-loop.env"
  if [[ "$PROFILE" == "linux" ]]; then
    section "Linux profile: systemd user units"
    unit_dir="${SYSTEMD_USER_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user}"
    mkdir -p "$unit_dir"
    write_if_changed "$unit_dir/$unit_name.service" "$service_text"
    if [[ "$WRITE_RESULT" == "changed" ]]; then unit_changed=1; fi
    write_if_changed "$unit_dir/$unit_name.timer" "$timer_text"
    if [[ "$WRITE_RESULT" == "changed" ]]; then unit_changed=1; fi
    if [[ $unit_changed -eq 1 ]]; then
      echo "  unit changed: run systemctl --user daemon-reload"
    fi
  elif [[ "$PROFILE" == "mac-mini" ]]; then
    section "Mac-mini profile: launchd plist"
    plist_path="${LAUNCH_AGENTS_DIR:-$HOME/Library/LaunchAgents}/$label.plist"
    log_dir="$HOME/.grid/logs"
    mkdir -p "$(dirname "$plist_path")" "$log_dir"
    write_if_changed "$plist_path" "$plist_text"
  fi

  # -------------------------------------------------------------------------
  # GitHub labels (create only if absent; --limit 200 because the gh default of 30 hides existing labels)
  # -------------------------------------------------------------------------
  section "GitHub labels"
  local existing role roles=()
  existing="$(gh label list --repo "$GH_REPO" --json name --limit 200 2>/dev/null || echo '[]')"
  ensure_label() {
    local name="$1" color="$2" desc="$3"
    if printf '%s' "$existing" | jq -e --arg l "$name" 'map(.name) | index($l) != null' &>/dev/null; then
      echo "  label '$name' already exists"
    else
      gh label create "$name" --repo "$GH_REPO" --color "$color" --description "$desc" >/dev/null 2>&1 \
        && echo "  created label '$name'" \
        || echo "  Warning: could not create label '$name' (check repo access)"
    fi
  }
  ensure_label "$ISSUE_LABEL" "0E8A16" "Ready for agent automation"
  ensure_label "ready-for-human" "D93F0B" "issue-loop: PR opened, needs human review and merge"
  ensure_label "needs-human" "D93F0B" "issue-loop: needs a human decision"
  ensure_label "blocked" "B60205" "issue-loop: could not land this"
  if [[ -n "$ROLE_LABELS" ]]; then
    IFS=',' read -r -a roles <<< "$ROLE_LABELS"
    for role in ${roles[@]+"${roles[@]}"}; do
      [[ -n "$role" ]] || continue
      ensure_label "role:$role" "5319E7" "issue-loop: build as agent $role"
    done
  fi

  # -------------------------------------------------------------------------
  # Generate CLAUDE.md (skip if one already exists — don't overwrite human work)
  # -------------------------------------------------------------------------
  section "CLAUDE.md"

  if [[ -f "$TARGET_DIR/CLAUDE.md" ]]; then
    echo "  CLAUDE.md already exists — skipping (review $TARGET_DIR/CLAUDE.md manually)"
  else
    local profile_rules runner_note
    if [[ "$MODE" == "pr" ]]; then
      profile_rules="- Agent MUST NOT push to \`${BASE_BRANCH}\` directly — the guard hook blocks it (exit 2); branch protection is the real boundary.
- Flow: implement on an \`issue-<N>\` worktree branch → PR to \`${BASE_BRANCH}\` → human merges.
- Start a branch with: \`bash loop/hooks/new-agent-worktree.sh issue-<N>\`"
      runner_note="- **Headless runner** (\`loop/run-issues.sh\`): the unattended path. One capped, tokenless
  \`claude -p\` session per issue in its own worktree; the RUNNER pushes, opens the PR to
  \`${BASE_BRANCH}\`, relabels and posts an Opus review. Config: \`loop/loop.conf\`; credentials
  live in the loop user's env file, never in this repo."
    else
      profile_rules="- Agent may push directly to \`${BASE_BRANCH}\`."
      runner_note="- (direct mode: interactive \`/loop\` only; there is no headless runner.)"
    fi
    case "$PROFILE" in
      mac-mini) profile_rules="$profile_rules
- Scheduled nightly at ${SCHEDULE_HOUR}:00 via launchd (${plist_path})." ;;
      linux)    profile_rules="$profile_rules
- Scheduled nightly at ${SCHEDULE_HOUR}:00 via a systemd user timer (${unit_name}.timer)." ;;
    esac

    local repo_name="${GH_REPO##*/}"
    local claude_md claude_md_tmp
    claude_md_tmp=$(mktemp)
    cat <<CLAUDEMD > "$claude_md_tmp"
# ${repo_name} — Claude context

Auto-generated by \`instantiate.sh\` (automation-factory / issue-loop pattern).
Machine profile: **${PROFILE}** · integration mode: **${MODE}** · base branch: **${BASE_BRANCH}**

## What's wired

- **Post-commit review hook** (\`loop/hooks/post-commit-review.sh\`): PostToolUse
  on Bash — fires after every \`git commit\`, queues an async capped \`claude -p\` review, posts
  it on the branch's open PR (else the issue named by \`#N\` in the commit message).
- **Loop prompt** (\`loop/loop-prompt.md\`): drives the interactive issue-loop.
  Picks the lowest-numbered \`${ISSUE_LABEL}\`-labelled issue, implements, verifies, commits,
  and hands over (${MODE} mode).
${runner_note}

\`loop/\` is a tracked folder — everything needed to regenerate this wiring
survives a clone or repo move. Only \`.claude/settings.json\` (machine-local,
gitignored by convention) is regenerated on demand, via \`bash loop/setup.sh\`.

## Profile rules

${profile_rules}

## Running the loop

\`\`\`
/loop \$(cat loop/loop-prompt.md)
\`\`\`

## After cloning or moving this repo

\`\`\`
bash loop/setup.sh
\`\`\`

## Issue hygiene

- Label issues \`${ISSUE_LABEL}\` to make them eligible.
- \`blocked\` label is auto-applied when the loop could not land an issue — remove it to retry.
- \`needs-human\` marks an issue that needs a decision; \`ready-for-human\` marks one with a PR waiting.
- Commit messages carry the \`#N\`, which tells the review hook which issue the commit belongs to.

## Allowed agent actions

- Read/write files within \`${TARGET_DIR}\` (in PR mode: within the issue worktree)
- \`git commit\`; \`git push\` only as the profile rules above allow
- \`gh issue\` commands (comment, label)
${VERIFY_CMD:+- Run: \`${VERIFY_CMD}\`}

## Forbidden

- Force push (\`--force\`), \`gh pr merge\`, pushing to \`${BASE_BRANCH}\` in PR mode
- Modify \`.claude/settings.json\` or \`loop/\` without human review
- Touch files outside \`${TARGET_DIR}\`
CLAUDEMD
    claude_md=$(cat "$claude_md_tmp")
    rm -f "$claude_md_tmp"
    write_if_changed "$TARGET_DIR/CLAUDE.md" "$claude_md"
  fi

  # -------------------------------------------------------------------------
  # Done: print (never run) what a human does next
  # -------------------------------------------------------------------------
  echo ""
  echo "=============================="
  echo "  issue-loop ready"
  echo "=============================="
  echo ""
  echo "  Repo:    $GH_REPO"
  echo "  Profile: $PROFILE  (mode $MODE, base $BASE_BRANCH)"
  echo "  Label:   $ISSUE_LABEL"
  [[ -n "$VERIFY_CMD" ]] && echo "  Verify:  $VERIFY_CMD"
  echo ""
  echo "  Interactive loop (in Claude Code inside $TARGET_DIR):"
  echo ""
  echo "    /loop \$(cat loop/loop-prompt.md)"
  echo ""

  if [[ "$MODE" == "pr" ]]; then
    echo "  Headless runner (loop/run-issues.sh) — run it as a DEDICATED unprivileged user that cannot"
    echo "  read your home, with its own claude login. Credentials are NEVER created by this script."
    echo "  The loop user creates $env_file_hint (mode 600) with these keys only:"
    echo "    GH_APP_ID=...                  the GitHub App id (required)"
    echo "    GH_APP_INSTALLATION_ID=...     the installation id (optional if the App has one installation)"
    echo "    GH_APP_KEY_FILE=...            the App private key, mode 600 (default \$HOME/.config/the-grid/app.pem)"
    echo "    LOOP_TRUSTED_ACTORS=login,...  GitHub logins whose labelling/edits the loop trusts (required)"
    echo "    LOOP_OPERATOR_HOME=/path       a path the loop user must NOT be able to list (required)"
    echo "  See automation-factory/patterns/issue-loop/README.md (\"Running unattended safely\")."
    echo ""
  fi

  if [[ "$PROFILE" == "linux" ]]; then
    echo "  Activate the timer (as the loop user) — printed, NOT run:"
    echo ""
    echo "    $(render_activation_commands systemd "$unit_name.timer")"
    echo ""
    echo "  A user timer only fires while the user manager runs; for a headless box enable linger once (needs sudo):"
    echo ""
    echo "    sudo loginctl enable-linger <loop-user>"
    echo ""
    if command -v loginctl &>/dev/null; then
      linger="$(loginctl show-user "${USER:-$(id -un)}" --property=Linger --value 2>/dev/null || true)"
      if [[ "$linger" != "yes" ]]; then
        echo "  WARNING: linger is '${linger:-unknown}' for this user: the timer will NOT fire while you are logged out"
        echo "  (Persistent=true then runs the missed job at your next login). Alternative that fires while logged out"
        echo "  without linger — one crontab line, printed, NOT installed:"
        echo ""
        if cron_line="$(render_crontab_line "$schedule" "$HOME/.grid/logs/$unit_name.log" "$TARGET_DIR" /bin/bash "$TARGET_DIR/loop/run-issues.sh" 2>/dev/null)"; then
          echo "    $cron_line"
          echo "    $(render_activation_commands cron "$cron_line")"
        else
          echo "    (not renderable: a path contains unsafe characters)"
        fi
        echo ""
      fi
    fi
    echo "  Fire it once by hand: systemctl --user start $unit_name.service   (journal: journalctl --user -u $unit_name.service)"
    echo ""
  elif [[ "$PROFILE" == "mac-mini" ]]; then
    echo "  Activate the LaunchAgent (as the loop user) — printed, NOT run:"
    echo ""
    echo "    $(render_activation_commands launchd "$plist_path")"
    echo ""
    echo "  Logs: $log_dir/$label.log"
    echo "  A LaunchAgent only runs while its user has a GUI session, and the Keychain-held claude login"
    echo "  is not readable over bare SSH: a headless Mac needs auto-login of the dedicated loop user."
    echo ""
  elif [[ "$PROFILE" == "personal" || "$PROFILE" == "work" ]]; then
    echo "  Or schedule via the cloud:"
    echo ""
    echo "    /schedule \"nightly at 2am, in $TARGET_DIR: /loop \$(cat loop/loop-prompt.md)\""
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
