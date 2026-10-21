#!/usr/bin/env bash
# instantiate.sh — cut an automation-factory pattern into a target repo.
#
# Usage:
#   instantiate.sh <pattern> <target-repo-dir> --profile <profile> [options]
#
# Patterns:
#   issue-loop    Work labelled GitHub issues with a headless runner (one issue per run) and a
#                 runner-side verify gate; the runner either opens a PR for a human to merge or
#                 (--land direct) lands the verified commit on the base branch. Plus an
#                 interactive /loop prompt and a post-commit review hook.
#
# Profiles (they only choose the default MODE; --mode overrides):
#   personal      MODE=direct: interactive /loop pushing the base branch. No runner, no guard.
#   work          MODE=pr: runner + guard + worktree helper; PRs only.
#   mac-mini      MODE=pr: same as work (kept for old command lines; it writes no scheduler file,
#                 use --cron-every for a per-repo cron line)
#
# Options:
#   --repo <owner/name>         code repo (detected from the git remote if omitted)
#   --issue-repo <owner/name>   repo the issues live in (default: --repo); a private tracker
#                               keeps issue text out of a public code repo
#   --project-context <text>    one-line project + stack description
#   --verify-cmd <cmd>          the gate the RUNNER runs before it pushes (empty = the runner refuses)
#   --label <label>             opt-in issue label (default: ready-for-agent)
#   --review-focus <text>       what the post-commit reviewer should focus on
#   --base-branch <branch>      PR target / worktree base (default: origin/HEAD's branch, else main)
#   --mode <pr|direct>          override the profile's default mode (direct = the interactive
#                               /loop, no runner; see --land for headless direct landing)
#   --land <pr|direct>          headless runner landing mode, default pr. Ships the runner, worker
#                               prompt, guard, worktree helper and cron-run.sh in either case and
#                               renders MODE=<value> into loop.conf. direct = no PR: the runner
#                               verifies, rebases and pushes the base branch, then closes the issue
#                               (protect the branch accordingly). Works with any profile.
#   --setup-cmd <cmd>           run in each issue worktree before the worker (e.g. npm ci)
#   --worker-model <model>      model for the headless worker (default: sonnet)
#   --agent-labels <a,b>        also create an agent:<name> label for each name
#   --fast-verify               VERIFY_CMD='bash loop/verify.sh' (changed-files check, seconds) unless
#                               --verify-cmd or an existing loop.conf already sets one
#   --cron-every <N>            (needs the runner: pr mode or --land) render this repo's own cron
#                               line: poll every N minutes
#                               (1-59), plus loop/cron.env with PATH and HOME for cron's bare
#                               environment. Printed, never installed: crontab is a human step.
#   --cron-log <file>           log for that line (default: ~/.grid/logs/issue-loop-<repo>.log)
#
# Idempotent: safe to re-run. Shipped files are copied verbatim and only rewritten if the bytes
# differ; loop/loop.conf is rendered ONCE and never overwritten (hand edits survive); an existing
# CLAUDE.md is never touched. An existing loop/loop.conf, or else loop/loop.conf.seed, supplies
# the values for any option not given. Writes NO scheduler file and NO .claude/settings.json hook
# entry (the guard reaches the worker through the runner's per-run --settings). --cron-every only
# PRINTS a crontab line and its activation command (and writes the gitignored loop/cron.env).
#
# Needs: git, gh (logged in), jq, awk. The runner needs claude, but instantiating does not run it.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GRID_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PATTERNS_DIR="$GRID_ROOT/automation-factory/patterns"

usage() {
  echo "Usage: instantiate.sh <pattern> <target-repo-dir> --profile <profile> [options]"
  echo ""
  echo "Patterns:  issue-loop"
  echo "Profiles:  personal | work | mac-mini"
  echo "Options:   --repo --issue-repo --project-context --verify-cmd --label --review-focus"
  echo "           --base-branch --mode --land --setup-cmd --worker-model --agent-labels"
  echo "           --fast-verify --cron-every --cron-log"
  echo ""
  echo "Example:"
  echo "  instantiate.sh issue-loop ~/projects/my-app --profile work --verify-cmd 'pytest -q'"
  exit 1
}

# ---------------------------------------------------------------------------
# arg parsing
# ---------------------------------------------------------------------------
[[ $# -ge 2 ]] || usage

PATTERN="$1"; shift
[[ -d "$1" ]] || { echo "Error: target directory '$1' does not exist"; exit 1; }
TARGET_DIR="$(cd "$1" && pwd)"; shift   # absolute path

# Option values; an empty string means "not given" (then conf/seed, then the default applies).
PROFILE=""
GH_REPO=""
ISSUE_REPO=""
PROJECT_CONTEXT=""
VERIFY_CMD=""
ISSUE_LABEL=""
REVIEW_FOCUS=""
BASE_BRANCH=""
MODE=""
LAND=""   # --land: headless runner landing mode (pr|direct); set means "ship the runner"
SETUP_CMD=""
WORKER_MODEL=""
AGENT_LABELS=""
FAST_VERIFY=0; CRON_EVERY=""; CRON_LOG=""
# Keys with no option: taken from conf/seed, else the default below.
VERIFY_TIMEOUT=""; MAX_BUDGET_USD=""; ISSUE_TIMEOUT=""; WORKER_PERMISSIONS=""
WORKER_ALLOWED_TOOLS=""; MAX_ISSUES_PER_DAY=""; TRUST_GATE=""; RUN_ROLE=""

# need_value <option> <count of remaining args> — every option takes a value.
need_value() { [[ "$2" -ge 2 ]] || { echo "Error: $1 needs a value"; usage; }; }

while [[ $# -gt 0 ]]; do
  # --fast-verify is the one flag without a value
  if [[ "$1" == "--fast-verify" ]]; then FAST_VERIFY=1; shift; continue; fi
  need_value "$1" "$#"
  case "$1" in
    --profile)          PROFILE="$2";          shift 2 ;;
    --repo)             GH_REPO="$2";          shift 2 ;;
    --issue-repo)       ISSUE_REPO="$2";       shift 2 ;;
    --project-context)  PROJECT_CONTEXT="$2";  shift 2 ;;
    --verify-cmd)       VERIFY_CMD="$2";       shift 2 ;;
    --label)            ISSUE_LABEL="$2";      shift 2 ;;
    --review-focus)     REVIEW_FOCUS="$2";     shift 2 ;;
    --base-branch)      BASE_BRANCH="$2";      shift 2 ;;
    --mode)             MODE="$2";             shift 2 ;;
    --land)             LAND="$2";             shift 2 ;;
    --setup-cmd)        SETUP_CMD="$2";        shift 2 ;;
    --worker-model)     WORKER_MODEL="$2";     shift 2 ;;
    --agent-labels)     AGENT_LABELS="$2";     shift 2 ;;
    --cron-every)       CRON_EVERY="$2";       shift 2 ;;
    --cron-log)         CRON_LOG="$2";         shift 2 ;;
    *) echo "Unknown option: $1"; usage ;;
  esac
done

[[ -n "$PROFILE" ]] || { echo "Error: --profile is required (personal | work | mac-mini)"; exit 1; }
[[ "$PROFILE" =~ ^(personal|work|mac-mini)$ ]] || { echo "Error: profile must be personal, work or mac-mini"; exit 1; }
[[ "$PATTERN" == "issue-loop" ]] || { echo "Error: unknown pattern '$PATTERN' (available: issue-loop)"; exit 1; }
[[ -z "$MODE" || "$MODE" =~ ^(pr|direct)$ ]] || { echo "Error: --mode must be pr or direct"; exit 1; }
[[ -z "$LAND" || "$LAND" =~ ^(pr|direct)$ ]] || { echo "Error: --land must be pr or direct"; exit 1; }
[[ -z "$LAND" || -z "$MODE" || "$LAND" == "$MODE" ]] || { echo "Error: --land $LAND conflicts with --mode $MODE (--land sets the runner's MODE)"; exit 1; }
[[ -z "$AGENT_LABELS" || "$AGENT_LABELS" =~ ^[A-Za-z0-9._,-]+$ ]] || { echo "Error: --agent-labels is a comma-separated list of agent names ([A-Za-z0-9._-])"; exit 1; }
[[ -z "$CRON_EVERY" || "$CRON_EVERY" =~ ^([1-9]|[1-5][0-9])$ ]] || { echo "Error: --cron-every is a number of minutes (1-59)"; exit 1; }
# one-line values only: they are written into single-line assignments
for v in GH_REPO ISSUE_REPO PROJECT_CONTEXT VERIFY_CMD ISSUE_LABEL REVIEW_FOCUS BASE_BRANCH SETUP_CMD WORKER_MODEL CRON_LOG; do
  case "${!v}" in
    *$'\n'*) echo "Error: the value for $v must be a single line"; exit 1 ;;
  esac
done

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

# shq <text> — text as ONE shell word for a ${KEY:-word} default. Empty stays empty-quoted,
# anything else is single-quoted with ' written as '\'' (so spaces, &&, |, (), non-ASCII text
# survive sourcing). Only ${s%%pat} / ${s#pat}: ${s//a/b} behaves differently across bash versions.
shq() {
  local s="$1" out=""
  while :; do
    case "$s" in
      *\'*) out="$out${s%%\'*}'\\''"; s="${s#*\'}" ;;
      *)    out="$out$s"; break ;;
    esac
  done
  printf "'%s'" "$out"
}

# render_conf <template> — stdin-free: fill {{KEY}} from the V_<KEY> environment in ONE
# left-to-right pass (awk + ENVIRON, so no value is ever interpreted: &, |, \, quotes, {{...}}).
render_conf() {
  awk '
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
    }' "$1"
}

# conf_value <file> <KEY> — the value KEY has after sourcing <file> in a subshell with every loop key
# unset first, so neither the caller's environment nor a variable of this script leaks in.
CONF_KEYS="GH_REPO ISSUE_REPO BASE_BRANCH ISSUE_LABEL MODE VERIFY_CMD VERIFY_TIMEOUT SETUP_CMD PROJECT_CONTEXT REVIEW_FOCUS WORKER_MODEL MAX_BUDGET_USD ISSUE_TIMEOUT WORKER_PERMISSIONS WORKER_ALLOWED_TOOLS MAX_ISSUES_PER_DAY TRUST_GATE RUN_ROLE"
conf_value() {
  (
    # shellcheck disable=SC2086
    unset $CONF_KEYS
    # shellcheck disable=SC1090
    . "$1" >/dev/null 2>&1 || true
    eval "printf '%s' \"\${$2:-}\""
  ) 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# prereq check
# ---------------------------------------------------------------------------
check_prereqs() {
  local missing=() cmd
  for cmd in git gh jq awk; do
    command -v "$cmd" &>/dev/null || missing+=("$cmd")
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    echo "Error: missing required tools: ${missing[*]}"
    exit 1
  fi
  gh auth status &>/dev/null || { echo "Error: gh is not authenticated — run: gh auth login"; exit 1; }
  echo "  ok (git, gh, jq, awk present; gh logged in)"
}

# ---------------------------------------------------------------------------
# detect the GitHub repo and base branch from the target's git remote
# ---------------------------------------------------------------------------
detect_repo() {
  if [[ -z "$GH_REPO" ]]; then
    local remote_url
    remote_url=$(git -C "$TARGET_DIR" remote get-url origin 2>/dev/null || true)
    if [[ -n "$remote_url" ]]; then
      # URL form (https://host/o/r, ssh://git@host/o/r) or scp form (git@host-alias:o/r)
      GH_REPO=$(echo "$remote_url" \
        | sed -E -e 's#^[A-Za-z+]+://([^@/]+@)?[^/]+/##' -e 's#^[^@/:]+@[^:/]+:##' -e 's#\.git$##')
    fi
    [[ -n "$GH_REPO" ]] || {
      echo "Error: could not detect GitHub repo from git remote. Pass --repo <owner/name>"
      exit 1
    }
    echo "  detected repo: $GH_REPO"
  else
    echo "  repo: $GH_REPO"
  fi
}

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
# cron schedule (--cron-every): ONE crontab line per repo
# ---------------------------------------------------------------------------
# Every cut repo has its own loop/, lock and log, so each gets its own line; repos run
# concurrently and a repo never overlaps itself (the runner's lock). Writes only the
# machine-local loop/cron.env; the crontab line and its activation command are PRINTED.
# cron's environment is bare (PATH=/usr/bin:/bin), so the dirs of the tools the runner calls
# are resolved NOW and baked into loop/cron.env, which loop/cron-run.sh sources.
print_cron_schedule() {
  local log="${CRON_LOG:-${GRID_STATE_DIR:-$HOME/.grid}/logs/issue-loop-${GH_REPO##*/}.log}"
  local extra="" tool path d line
  # sourced only here: the renderer is needed for --cron-every alone
  # shellcheck source=lib/render-schedule.sh
  . "$SCRIPT_DIR/lib/render-schedule.sh"
  for tool in gh claude jq git awk timeout; do
    path="$(command -v "$tool" 2>/dev/null)" || path=""
    # macOS ships GNU timeout as gtimeout
    if [[ -z "$path" && "$tool" == "timeout" ]]; then path="$(command -v gtimeout 2>/dev/null)" || path=""; fi
    if [[ -z "$path" ]]; then echo "  Warning: '$tool' not found on PATH here; the cron run will fail until it is installed"; continue; fi
    d="$(dirname "$path")"
    case ":/usr/local/bin:/usr/bin:/bin$extra:" in *":$d:"*) ;; *) extra="$extra:$d" ;; esac
  done
  # System dirs first, resolved dirs appended: a system binary always wins over a user-dir one.
  write_if_changed "$TARGET_DIR/loop/cron.env" "# loop/cron.env: machine-local (ignored by version control), written by instantiate.sh --cron-every.
# Sourced by loop/cron-run.sh because cron starts with a bare PATH.
export HOME=$(shq "$HOME")
export PATH=$(shq "/usr/local/bin:/usr/bin:/bin$extra")"

  line="$(render_crontab_line "every:$CRON_EVERY" "$log" "$TARGET_DIR" bash loop/cron-run.sh)" || {
    echo "Error: could not render the cron line (see above); loop/ is cut, re-run with a different --cron-log or path"
    exit 2
  }
  section "Cron (printed, not installed)"
  echo "  One line per repo. Nothing was added to any crontab. Add it yourself:"
  echo ""
  echo "$line"
  echo ""
  echo "  Activate (idempotent, safe to paste twice):"
  echo "  $(render_activation_commands cron "$line")"
}

# ---------------------------------------------------------------------------
# issue-loop instantiation
# ---------------------------------------------------------------------------
instantiate_issue_loop() {
  local pattern_dir="$PATTERNS_DIR/issue-loop"
  # loop/ is a TRACKED top-level folder, not .claude/ — a target repo's .claude/ is commonly
  # gitignored, which would make the automation vanish on the next clone or move.
  local loop_dir="$TARGET_DIR/loop"
  local hooks_dir="$loop_dir/hooks"
  local src_conf="" k v

  # An existing loop.conf (hand-tuned, tracked) or else loop.conf.seed (the project factory's
  # defaults) supplies every value an option did not. Flags still win.
  if [[ -f "$loop_dir/loop.conf" ]]; then src_conf="$loop_dir/loop.conf"
  elif [[ -f "$loop_dir/loop.conf.seed" ]]; then src_conf="$loop_dir/loop.conf.seed"
  fi
  if [[ -n "$src_conf" ]]; then
    for k in $CONF_KEYS; do
      if [[ -z "${!k}" ]]; then
        v="$(conf_value "$src_conf" "$k")"
        printf -v "$k" '%s' "$v"
      fi
    done
  fi

  # --fast-verify fills only an empty VERIFY_CMD: --verify-cmd and a hand-tuned loop.conf win.
  if [[ "$FAST_VERIFY" -eq 1 && -z "$VERIFY_CMD" ]]; then VERIFY_CMD="bash loop/verify.sh"; fi

  section "Prereqs"
  check_prereqs

  section "Target"
  echo "  dir:     $TARGET_DIR"
  [[ -z "$src_conf" ]] || echo "  defaults from: ${src_conf#"$TARGET_DIR"/}"
  detect_repo
  detect_base_branch
  [[ -n "$ISSUE_REPO" ]] || ISSUE_REPO="$GH_REPO"
  echo "  issues:  $ISSUE_REPO"
  echo "  profile: $PROFILE"

  # --land is an explicit request for the headless runner in that landing mode, so it beats the
  # profile default and a conf value. (--land vs --mode was checked at parse time.)
  if [[ -n "$LAND" ]]; then
    MODE="$LAND"
    # loop.conf is rendered once and never rewritten: say so when it disagrees with --land
    if [[ -f "$loop_dir/loop.conf" && "$(conf_value "$loop_dir/loop.conf" MODE)" != "$LAND" ]]; then
      echo "  Warning: existing loop/loop.conf has MODE='$(conf_value "$loop_dir/loop.conf" MODE)'; it is left alone, set MODE='$LAND' there by hand"
    fi
  fi
  # profile -> default mode (an existing conf's MODE and --mode both win)
  if [[ -z "$MODE" ]]; then
    case "$PROFILE" in
      personal) MODE="direct" ;;
      *)        MODE="pr" ;;
    esac
  fi
  [[ "$MODE" =~ ^(pr|direct)$ ]] || { echo "Error: MODE must be pr or direct (got '$MODE')"; exit 1; }
  # Does this cut ship the headless runner? MODE=direct alone means the interactive /loop (no
  # runner), so direct needs --land, or a runner already cut here (a re-run must not drop to the
  # interactive text). pr always ships it.
  RUNNER=0
  if [[ "$MODE" == "pr" || -n "$LAND" || -f "$loop_dir/run-issue.sh" ]]; then RUNNER=1; fi
  [[ -z "$CRON_EVERY" || "$RUNNER" -eq 1 ]] || { echo "Error: --cron-every needs the headless runner (pr mode, or --land direct); the interactive direct mode has none"; exit 1; }
  echo "  mode:    $MODE$( [[ "$RUNNER" -eq 1 ]] && echo ' (headless runner)' || echo ' (interactive /loop, no runner)' )"

  # defaults for keys with no option and no conf/seed value
  : "${ISSUE_LABEL:=ready-for-agent}"
  : "${VERIFY_TIMEOUT:=900}"
  : "${WORKER_MODEL:=sonnet}"
  : "${MAX_BUDGET_USD:=5}"
  : "${ISSUE_TIMEOUT:=1800}"
  : "${WORKER_PERMISSIONS:=allowlist}"
  : "${WORKER_ALLOWED_TOOLS:=Read,Edit,Write,Glob,Grep,Bash(git status:*),Bash(git diff:*),Bash(git log:*),Bash(git show:*),Bash(git add:*),Bash(git commit:*)}"
  : "${MAX_ISSUES_PER_DAY:=0}"
  : "${TRUST_GATE:=on}"
  : "${RUN_ROLE:=issue-loop}"

  section "Configuration"
  prompt_if_missing PROJECT_CONTEXT "One-line project + stack description" "a software project"
  prompt_if_missing REVIEW_FOCUS    "What should the code review focus on?" "correctness, style, and test coverage"

  mkdir -p "$hooks_dir"

  # -------------------------------------------------------------------------
  # Shipped files, copied VERBATIM (one source of truth; the prompt template is never rewritten,
  # so re-cutting cannot change a tracked file: setup.sh renders loop/loop-prompt.md from it)
  # -------------------------------------------------------------------------
  section "Module 1: post-commit review hook"
  copy_if_changed "$pattern_dir/hooks/post-commit-review.sh" "$hooks_dir/post-commit-review.sh"
  chmod +x "$hooks_dir/post-commit-review.sh"

  section "Module 2: prompt template + setup"
  copy_if_changed "$pattern_dir/loop-prompt.template.md" "$loop_dir/loop-prompt.template.md"
  copy_if_changed "$pattern_dir/setup.sh" "$loop_dir/setup.sh"
  copy_if_changed "$pattern_dir/.gitignore" "$loop_dir/.gitignore"
  chmod +x "$loop_dir/setup.sh"

  # loop.conf: rendered ONCE from the template with single-quoted values; never overwritten.
  local conf_text
  conf_text=$(
    V_GH_REPO="$(shq "$GH_REPO")" \
    V_BASE_BRANCH="$(shq "$BASE_BRANCH")" \
    V_ISSUE_LABEL="$(shq "$ISSUE_LABEL")" \
    V_MODE="$(shq "$MODE")" \
    V_VERIFY_CMD="$(shq "$VERIFY_CMD")" \
    V_VERIFY_TIMEOUT="$(shq "$VERIFY_TIMEOUT")" \
    V_SETUP_CMD="$(shq "$SETUP_CMD")" \
    V_PROJECT_CONTEXT="$(shq "$PROJECT_CONTEXT")" \
    V_REVIEW_FOCUS="$(shq "$REVIEW_FOCUS")" \
    V_WORKER_MODEL="$(shq "$WORKER_MODEL")" \
    V_MAX_BUDGET_USD="$(shq "$MAX_BUDGET_USD")" \
    V_ISSUE_TIMEOUT="$(shq "$ISSUE_TIMEOUT")" \
    V_WORKER_PERMISSIONS="$(shq "$WORKER_PERMISSIONS")" \
    V_WORKER_ALLOWED_TOOLS="$(shq "$WORKER_ALLOWED_TOOLS")" \
    V_MAX_ISSUES_PER_DAY="$(shq "$MAX_ISSUES_PER_DAY")" \
    V_TRUST_GATE="$(shq "$TRUST_GATE")" \
    V_RUN_ROLE="$(shq "$RUN_ROLE")" \
    V_ISSUE_REPO="$( if [[ "$ISSUE_REPO" == "$GH_REPO" ]]; then printf '%s' '"$GH_REPO"'; else shq "$ISSUE_REPO"; fi )" \
    render_conf "$pattern_dir/loop.conf.template")
  if [[ ! -e "$loop_dir/loop.conf" ]]; then
    write_if_changed "$loop_dir/loop.conf" "$conf_text"
  else
    echo "  left alone: $loop_dir/loop.conf (rendered once; edit it by hand)"
  fi

  # runner cuts only (pr, or direct via --land): the headless runner, its prompt, the guard and
  # the worktree helper. The guard still stops the WORKER pushing; the runner does the landing.
  if [[ "$RUNNER" -eq 1 ]]; then
    section "Runner: runner, worker prompt, guard hook, worktree helper"
    copy_if_changed "$pattern_dir/run-issue.sh" "$loop_dir/run-issue.sh"
    copy_if_changed "$pattern_dir/cron-run.sh" "$loop_dir/cron-run.sh"
    copy_if_changed "$pattern_dir/verify.sh" "$loop_dir/verify.sh"
    copy_if_changed "$pattern_dir/worker-prompt.template.md" "$loop_dir/worker-prompt.template.md"
    copy_if_changed "$pattern_dir/hooks/guard-main-push.sh" "$hooks_dir/guard-main-push.sh"
    copy_if_changed "$pattern_dir/hooks/new-agent-worktree.sh" "$hooks_dir/new-agent-worktree.sh"
    chmod +x "$loop_dir/run-issue.sh" "$loop_dir/cron-run.sh" "$loop_dir/verify.sh" "$hooks_dir/guard-main-push.sh" "$hooks_dir/new-agent-worktree.sh"
  fi

  # setup.sh renders loop/loop-prompt.md from the template + loop.conf and self-tests the guard.
  # It writes NOTHING to .claude/settings.json: the guard reaches the worker through the
  # runner's per-run --settings file, never through the repo's own settings.
  bash "$loop_dir/setup.sh"

  # A repo's .claude/settings.json is machine-local (an interactive setup may wire absolute hook
  # paths into it): keep it out of git. Appended once.
  section ".gitignore"
  local gi="$TARGET_DIR/.gitignore"
  if [[ -f "$gi" ]] && grep -qxF '.claude/settings.json' "$gi"; then
    echo "  unchanged: $gi (already ignores .claude/settings.json)"
  else
    # make sure the existing last line ends in a newline before appending
    if [[ -s "$gi" ]] && [[ -n "$(tail -c1 "$gi")" ]]; then printf '\n' >> "$gi"; fi
    printf '%s\n' '.claude/settings.json' >> "$gi"
    echo "  appended:  .claude/settings.json to $gi"
  fi

  # -------------------------------------------------------------------------
  # GitHub labels, in the ISSUE repo (create only if absent; --limit 200 because the gh default of
  # 30 hides existing labels)
  # -------------------------------------------------------------------------
  section "GitHub labels (in $ISSUE_REPO)"
  local existing name names=()
  existing="$(gh label list --repo "$ISSUE_REPO" --json name --limit 200 2>/dev/null || echo '[]')"
  ensure_label() {
    local lname="$1" color="$2" desc="$3"
    if printf '%s' "$existing" | jq -e --arg l "$lname" 'map(.name) | index($l) != null' &>/dev/null; then
      echo "  label '$lname' already exists"
    else
      gh label create "$lname" --repo "$ISSUE_REPO" --color "$color" --description "$desc" >/dev/null 2>&1 \
        && echo "  created label '$lname'" \
        || echo "  Warning: could not create label '$lname' (check repo access)"
    fi
  }
  ensure_label "$ISSUE_LABEL" "0E8A16" "Ready for agent automation"
  ensure_label "ready-for-human" "D93F0B" "issue-loop: PR opened, needs human review and merge"
  ensure_label "needs-human" "D93F0B" "issue-loop: needs a human decision"
  ensure_label "blocked" "B60205" "issue-loop: could not land this"
  if [[ -n "$AGENT_LABELS" ]]; then
    IFS=',' read -r -a names <<< "$AGENT_LABELS"
    for name in ${names[@]+"${names[@]}"}; do
      [[ -n "$name" ]] || continue
      ensure_label "agent:$name" "5319E7" "issue-loop: build as agent $name"
    done
  fi

  # -------------------------------------------------------------------------
  # CLAUDE.md (never overwrite an existing one — that is human work)
  # -------------------------------------------------------------------------
  section "CLAUDE.md"
  if [[ -f "$TARGET_DIR/CLAUDE.md" ]]; then
    echo "  CLAUDE.md already exists — skipping (review $TARGET_DIR/CLAUDE.md manually)"
  else
    local profile_rules runner_note merge_rule repo_name="${GH_REPO##*/}" md_tmp
    if [[ "$RUNNER" -eq 1 && "$MODE" == "direct" ]]; then
      profile_rules="- The headless worker MUST NOT push at all: the guard hook blocks it. Only the RUNNER pushes \`${BASE_BRANCH}\`, after its own \`VERIFY_CMD\` passes. There is no PR and no review step, so branch protection and \`VERIFY_CMD\` are the only checks.
- Flow: implement on an \`issue-<N>\` worktree branch, the RUNNER verifies, rebases onto \`origin/${BASE_BRANCH}\` if it moved (and verifies again), pushes \`${BASE_BRANCH}\` without force and closes the issue. A rebase conflict or rejected push labels the issue \`blocked\` and pushes nothing.
- Start a branch by hand with: \`bash loop/hooks/new-agent-worktree.sh issue-<N>\`"
      runner_note="- **Headless runner** (\`loop/run-issue.sh\`): works ONE \`${ISSUE_LABEL}\` issue per invocation in its own
  worktree, runs \`VERIFY_CMD\` itself, then lands the commit on \`${BASE_BRANCH}\` (MODE=direct) and closes the issue.
  Started by hand (\`bash loop/run-issue.sh\`) or by a cron line (\`--cron-every\`). Config: \`loop/loop.conf\`."
    elif [[ "$MODE" == "pr" ]]; then
      profile_rules="- Agent MUST NOT push to \`${BASE_BRANCH}\` directly: the guard hook blocks it for the headless worker; branch protection is the real boundary.
- Flow: implement on an \`issue-<N>\` worktree branch, the RUNNER verifies and opens a PR to \`${BASE_BRANCH}\`, a human merges.
- Start a branch by hand with: \`bash loop/hooks/new-agent-worktree.sh issue-<N>\`"
      runner_note="- **Headless runner** (\`loop/run-issue.sh\`): works ONE \`${ISSUE_LABEL}\` issue per invocation in its own
  worktree, runs \`VERIFY_CMD\` itself, then pushes \`issue-<N>\` and opens the PR. It is started by hand
  (\`bash loop/run-issue.sh\`); nothing starts it for you. Config: \`loop/loop.conf\`."
    else
      profile_rules="- Agent may push directly to \`${BASE_BRANCH}\` (direct mode, interactive \`/loop\` only)."
      runner_note="- (direct mode: interactive \`/loop\` only; there is no headless runner in this repo.)"
    fi
    # the issue-hygiene line that differs by landing mode
    if [[ "$RUNNER" -eq 1 && "$MODE" == "direct" ]]; then
      merge_rule="The loop lands verified commits on \`${BASE_BRANCH}\` itself and opens no PRs."
    else
      merge_rule="The loop opens PRs and never merges."
    fi
    md_tmp=$(mktemp)
    cat > "$md_tmp" <<CLAUDEMD
# ${repo_name} — Claude context

Written once by \`instantiate.sh\` (automation-factory / issue-loop pattern). Edit freely.
Profile: **${PROFILE}**, mode: **${MODE}**

## What's wired

- **Post-commit review hook** (\`loop/hooks/post-commit-review.sh\`): after a \`git commit\` in an
  interactive session it queues a capped \`claude -p\` review and posts it on the PR or the issue.
${runner_note}
- **Interactive prompt** (\`loop/loop-prompt.md\`, rendered from \`loop/loop-prompt.template.md\` by
  \`bash loop/setup.sh\`): paste it into \`/loop\` for a session you watch.

\`loop/\` is tracked: it survives a clone or move. \`.claude/settings.json\` is machine-local and ignored.

## Profile rules

${profile_rules}

## Issue hygiene

- Label an issue \`${ISSUE_LABEL}\` to make it eligible. Everything else is the operator's call.
- \`blocked\`, \`needs-human\` and \`ready-for-human\` are set by the loop; remove \`blocked\` and re-add \`${ISSUE_LABEL}\` to retry.
- ${merge_rule}
- \`VERIFY_CMD\` in \`loop/loop.conf\` is the gate; empty means the runner refuses to start.
${VERIFY_CMD:+- Verify command: \`${VERIFY_CMD}\`}

## Forbidden

- Force push; merging a PR; editing \`.claude/settings.json\` or \`loop/\` without human review.
- Touching files outside \`${TARGET_DIR}\`.
CLAUDEMD
    write_if_changed "$TARGET_DIR/CLAUDE.md" "$(cat "$md_tmp")"
    rm -f "$md_tmp"
  fi

  # -------------------------------------------------------------------------
  # Done
  # -------------------------------------------------------------------------
  echo ""
  echo "=============================="
  echo "  issue-loop ready"
  echo "=============================="
  echo ""
  echo "  Code repo:  $GH_REPO"
  echo "  Issue repo: $ISSUE_REPO"
  echo "  Profile:    $PROFILE (mode $MODE)"
  echo "  Label:      $ISSUE_LABEL"
  if [[ -n "$VERIFY_CMD" ]]; then echo "  Verify:     $VERIFY_CMD"; else echo "  Verify:     (empty: set VERIFY_CMD in loop/loop.conf, the runner refuses to run without it)"; fi
  echo ""
  if [[ "$RUNNER" -eq 1 ]]; then
    echo "  First run, by hand, from $TARGET_DIR:"
    echo ""
    echo "    bash loop/run-issue.sh"
    echo ""
    echo "  (one issue per run; nothing is scheduled and no scheduler file was written)"
    echo ""
    echo "  Before that run: the worker is DENIED every Bash command not in WORKER_ALLOWED_TOOLS."
    echo "  VERIFY_CMD itself is allowed automatically. Other commands your tests run, or that your global"
    echo "  Claude rules trigger (a git identity check, for example), are not, and a worker that cannot"
    echo "  run its checks ends 'blocked'. Add them to WORKER_ALLOWED_TOOLS in loop/loop.conf."
  else
    echo "  Start the interactive loop (in Claude Code inside $TARGET_DIR):"
    echo ""
    # shellcheck disable=SC2016
    echo '    /loop $(cat loop/loop-prompt.md)'
  fi
  echo ""
  if [[ -n "$CRON_EVERY" ]]; then print_cron_schedule; echo ""; fi
}

# ---------------------------------------------------------------------------
# dispatch
# ---------------------------------------------------------------------------
case "$PATTERN" in
  issue-loop) instantiate_issue_loop ;;
  *) echo "Error: unknown pattern '$PATTERN' (available: issue-loop)"; usage ;;
esac
