#!/usr/bin/env bash
# uninstall.sh — remove what the-grid put on this machine. A DRY RUN unless --yes.
#
# Use it to decommission a machine, or to reset a test HOME between clean-install
# tests. It removes only what the-grid owns, by the same resolved-path test wire.sh
# uses (a link is ours when its target resolves under GRID_DIR):
#   - links in SKILLS_DIR and AGENTS_DIR (the gstack runtime-root link included)
#   - rule-pack links under RULES_DIR/grid/, then grid/ (and pack dirs) once empty
#   - links in the other harness dirs listed in scripts/lib/harnesses.txt
#   - the generated auto-handoff entry in CLAUDE_CONFIG_DIR/settings.json (via
#     deploy_hooks.py --user --hooks "", the path `-hook:auto-handoff` takes); your own
#     hooks and keys stay. Caveat: the writer reformats the file as 2-space JSON the first
#     time it writes; a file that already held our entry went through that when wire.sh
#     added it, so only the entry changes.
#   - the marked rules block that `rules.py emit` put into other harnesses' instruction
#     files (codex, opencode, gemini, pi). Not removable cleanly: printed, not edited.
#   - `grid install`'s ledger and placed dirs, through `scripts/grid uninstall`.
# It never touches a real dir, a foreign link, or a dangling link that is not ours.
#
# NOT removed by default: the state dir (~/.grid). It also holds instincts and learning
# data (docs/instincts.md). --purge deletes it.
# Scheduled jobs (launchd, systemd, cron) are only DETECTED and their deactivation
# commands PRINTED: activating them was a human step, so deactivating is too.
#
# Usage:
#   bash scripts/uninstall.sh                 # dry run: print what would go, change nothing
#   bash scripts/uninstall.sh --yes           # remove it
#   bash scripts/uninstall.sh --yes --purge   # ...and delete the clone (GRID_DIR) and the
#                                             # state dir. Refused when the clone has
#                                             # uncommitted changes, unpushed commits, stashes
#                                             # or dirty worktrees, unless --force. Never
#                                             # touches ~/.the-grid-private.
#   (--purge without --yes only adds the purge lines to the dry-run plan.)
#
# Env (same contract as wire.sh):
#   GRID_DIR          root of the-grid clone       (default: parent of scripts/)
#   SKILLS_DIR        Claude skills dir            (default: ~/.claude/skills)
#   AGENTS_DIR        Claude subagents dir         (default: ~/.claude/agents)
#   RULES_DIR         Claude rules dir             (default: ~/.claude/rules)
#   CLAUDE_CONFIG_DIR Claude config dir            (default: ~/.claude)
#   GRID_STATE_DIR    machine-local state          (default: ~/.grid)
#   GRID_HARNESS_HOME base of every non-Claude harness dir (default: $HOME)
#   LAUNCH_AGENTS_DIR, SYSTEMD_USER_DIR   where scheduled-job files are looked for
#
# Exit: 0 done (or dry run) | 1 something was kept or failed, or --purge refused |
#       2 bad argument or environment (nothing changed)
set -euo pipefail

# --- arguments ----------------------------------------------------------------
YES=0 PURGE=0 FORCE=0
for arg in "$@"; do
  case "$arg" in
    --yes) YES=1 ;;
    --purge) PURGE=1 ;;
    --force) FORCE=1 ;;
    -h|--help)
      sed -n '2,/^set -euo/{/^set -euo/!p;}' "$0"  # print the header comment as help
      exit 0 ;;
    *) echo "uninstall.sh: unknown argument: $arg" >&2; exit 2 ;;
  esac
done
if [ "$FORCE" = 1 ] && [ "$PURGE" = 0 ]; then
  echo "uninstall.sh: --force only applies to --purge" >&2
  exit 2
fi

# Everything below runs inside main(), invoked on the last line. bash has then parsed the
# whole file before --purge deletes the clone this script lives in.
main() {
  # A relative GRID_DIR or GRID_STATE_DIR is refused up front: --purge does `cd /` before it
  # deletes, and from there a relative path would name something else.
  local rel_v
  for rel_v in GRID_DIR GRID_STATE_DIR; do
    case "${!rel_v:-}" in
      ""|/*) ;;
      *) echo "uninstall: $rel_v must be an absolute path (got '${!rel_v}'); nothing was changed" >&2; exit 2 ;;
    esac
  done
  SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
  GRID_DIR="${GRID_DIR:-$(cd "$SCRIPT_DIR/.." && pwd)}"
  # Canonical spelling, as wire.sh: ownership is decided on resolved paths.
  GRID_DIR="$(cd "$GRID_DIR" 2>/dev/null && pwd -P)" || { echo "uninstall: GRID_DIR is not a directory" >&2; exit 2; }
  export GRID_DIR

  # A dry-run home is a wire.sh notion (it forces every target under it). An uninstall
  # acts on the targets named by the variables below, so an inherited one must not
  # silently redirect harness paths.
  unset GRID_DRY_HOME

  # HOME preflight, as wire.sh: with HOME unset or empty every dir derived from it must
  # have been given explicitly, or `set -u` would die half way (or map to /.claude).
  if [ -z "${HOME:-}" ]; then
    local missing="" v
    for v in SKILLS_DIR AGENTS_DIR RULES_DIR CLAUDE_CONFIG_DIR GRID_STATE_DIR; do
      [ -n "${!v:-}" ] || missing="$missing $v"
    done
    if [ -n "$missing" ]; then
      echo "uninstall: HOME is unset or empty, so these cannot be resolved:$missing; nothing was changed" >&2
      exit 2
    fi
  fi
  HOME_DIR="${HOME:-}"
  SKILLS_DIR="${SKILLS_DIR:-$HOME_DIR/.claude/skills}"
  AGENTS_DIR="${AGENTS_DIR:-$HOME_DIR/.claude/agents}"
  RULES_DIR="${RULES_DIR:-$HOME_DIR/.claude/rules}"
  CLAUDE_CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME_DIR/.claude}"
  STATE="${GRID_STATE_DIR:-$HOME_DIR/.grid}"
  # No trailing slash: "link/" makes rm follow a symlinked state dir into its target.
  while [ "${STATE%/}" != "$STATE" ] && [ -n "${STATE%/}" ]; do STATE="${STATE%/}"; done
  # The children (deploy_hooks.py, scripts/grid) read these, so pass the resolved values.
  export CLAUDE_CONFIG_DIR SKILLS_DIR GRID_STATE_DIR="$STATE"

  # A GRID_DIR that is HOME or contains it makes every link in HOME "ours": refuse, even
  # for a dry run. (Only a hand-set GRID_DIR can do this; the default is the clone.)
  if [ -n "$HOME_DIR" ]; then
    local home_phys
    home_phys="$(cd "$HOME_DIR" 2>/dev/null && pwd -P || true)"
    if [ -n "$home_phys" ] && { [ "$GRID_DIR" = / ] || path_inside "$home_phys" "$GRID_DIR"; }; then
      echo "uninstall: refusing: GRID_DIR ($GRID_DIR) is, or contains, your home directory; nothing was changed" >&2
      exit 2
    fi
  fi

  # harness registry helpers (harness_names/field/path, rules block removal).
  # shellcheck source=lib/harness.sh disable=SC1091
  . "$SCRIPT_DIR/lib/harness.sh"

  N_ITEMS=0 N_KEPT=0 N_FAILED=0 SEEN_DIRS="|"

  if [ "$YES" = 1 ]; then echo "uninstall: removing what the-grid owns (clone: $GRID_DIR)"
  else echo "uninstall: DRY RUN, nothing changes; pass --yes to remove (clone: $GRID_DIR)"; fi

  purge_preflight      # refuses BEFORE anything is removed
  step_ledger          # first: its own wire.sh refresh may re-link, the sweeps below catch that
  step_links "$SKILLS_DIR" skill
  step_links "$AGENTS_DIR" agent
  step_rule_links
  step_harness_links
  step_hook
  step_rules_blocks
  report_schedules
  step_purge           # last: deletes the clone and the state dir

  # Summary: one line, and a no-op second run says so.
  if [ "$N_ITEMS" -eq 0 ] && [ "$N_FAILED" -eq 0 ]; then
    echo "uninstall: nothing to remove (kept $N_KEPT)"
  elif [ "$YES" = 1 ]; then
    echo "uninstall: removed $N_ITEMS item(s), kept $N_KEPT, failed $N_FAILED"
  else
    echo "uninstall: dry run: would remove $N_ITEMS item(s), keep $N_KEPT; nothing changed. Re-run with --yes to remove."
  fi
  [ "$N_FAILED" -eq 0 ] || exit 1
  exit 0
}

# --- output: one line per item -------------------------------------------------
say_remove() { # <what>: counted; the verb tells a plan from a result
  N_ITEMS=$((N_ITEMS + 1))
  if [ "$YES" = 1 ]; then printf 'removed       %s\n' "$1"; else printf 'would remove  %s\n' "$1"; fi
}
say_kept() { N_KEPT=$((N_KEPT + 1)); printf 'kept          %s\n' "$1"; }
say_failed() { N_FAILED=$((N_FAILED + 1)); printf 'FAILED        %s\n' "$1"; }

# --- ownership: is a link target inside the grid? ------------------------------
# Mirrors wire.sh (lex_norm / target_is_ours): wire.sh cannot be sourced, so the logic is
# copied. Keep the two in step; tests/test_uninstall.bats pins the `${GRID_DIR}-private`
# sibling case. Ours = the target RESOLVES to a path under GRID_DIR/ (with the slash), so
# "${GRID_DIR}-private/x" and "$GRID_DIR/../x" are never matched.
lex_norm() {
  local part res="" parts
  IFS=/ read -r -d '' -a parts < <(printf '%s' "$1") || true
  for part in "${parts[@]:-}"; do
    case "$part" in
      ''|.) ;;
      ..)   res="${res%/*}" ;;
      *)    res="$res/$part" ;;
    esac
  done
  NORM="${res:-/}"
}

target_is_ours() {
  local t="$1" dir base phys res=""
  case "$t" in /*) ;; *) return 1 ;; esac
  while [ "${t%/}" != "$t" ] && [ -n "${t%/}" ]; do t="${t%/}"; done   # trailing slashes
  base="${t##*/}"
  case "$base" in
    .|..)
      if phys="$(cd -P "$t" 2>/dev/null && pwd -P)"; then res="$phys"; fi ;;
    *)
      dir="${t%/*}"; [ -n "$dir" ] || dir=/
      if phys="$(cd -P "$dir" 2>/dev/null && pwd -P)"; then
        [ "$phys" = / ] && phys=""
        res="$phys/$base"
      fi ;;
  esac
  if [ -z "$res" ]; then lex_norm "$t"; res="$NORM"; fi   # parent missing (dangling link): lexical
  case "$res" in "$GRID_DIR"/*) return 0 ;; esac
  return 1
}

# link_ours <path>: a symlink whose target is ours. Sets LINK_TARGET.
link_ours() {
  [ -L "$1" ] || return 1
  LINK_TARGET="$(readlink "$1")" || return 1
  target_is_ours "$LINK_TARGET"
}

# drop_link <kind> <path>: remove one owned link (after link_ours), one output line.
drop_link() {
  if [ "$YES" = 1 ] && ! rm -- "$2" 2>/dev/null; then
    say_failed "$1 $2 (cannot remove)"
    return 0
  fi
  say_remove "$1 $2 -> $LINK_TARGET"
}

# --- links in one flat dir (skills, agents, every harness dir) -----------------
# Names of runtime-root links (scripts/lib/runtimes.txt), only to label them in the output.
runtime_link_names() {
  local f="$GRID_DIR/scripts/lib/runtimes.txt" repo link
  [ -f "$f" ] || return 0
  while IFS='|' read -r repo link _rest; do
    repo="${repo%%#*}"; repo="${repo//[[:space:]]/}"; [ -n "$repo" ] || continue
    link="${link//[[:space:]]/}"; [ -z "$link" ] || printf '%s ' "$link"
  done < "$f"
}

step_links() { # <dir> <kind>
  local dir="$1" kind="$2" phys entry name k foreign=0 rt
  [ -d "$dir" ] || return 0
  phys="$(cd -P "$dir" 2>/dev/null && pwd -P)" || return 0
  # Several harnesses share ~/.agents/skills: visit each physical dir once.
  case "$SEEN_DIRS" in *"|$phys|"*) return 0 ;; esac
  SEEN_DIRS="$SEEN_DIRS$phys|"
  rt=" $(runtime_link_names)"
  # -H: follow the dir itself when it is a symlink (a dotfiles-managed skills dir).
  while IFS= read -r -d '' entry; do
    name="${entry##*/}"
    if link_ours "$entry"; then
      k="$kind"
      case "$rt" in *" $name "*) [ "$kind" = skill ] && k=runtime-link ;; esac
      drop_link "$k" "$entry"
    else
      foreign=$((foreign + 1))
    fi
  done < <(find -H "$dir" -mindepth 1 -maxdepth 1 -print0)
  [ "$foreign" -eq 0 ] || say_kept "$dir: $foreign entr$([ "$foreign" -eq 1 ] && echo y || echo ies) not ours (real dirs, foreign or dangling links)"
}

# --- rule packs: $RULES_DIR/grid/<pack>/<topic>.md ------------------------------
# has_blocker <dir>: something under <dir> that is neither a dir nor one of our links,
# so <dir> will not be empty after our links go.
has_blocker() {
  local e
  while IFS= read -r -d '' e; do
    if [ -L "$e" ]; then link_ours "$e" && continue; return 0; fi
    [ -d "$e" ] && continue
    return 0
  done < <(find "$1" -mindepth 1 -print0)
  return 1
}

step_rule_links() {
  local root="$RULES_DIR/grid" e foreign d drop=""
  [ -d "$root" ] || return 0
  # Real files under grid/ are the user's (counted now: grid/ may be gone afterwards).
  foreign="$(find -H "$root" ! -type d ! -type l | wc -l | tr -d ' ')"
  # Decide which dirs end up empty BEFORE removing anything, so a dry run and a real run
  # print the same plan. -depth lists children before parents.
  while IFS= read -r -d '' d; do
    has_blocker "$d" || drop="$drop$d"$'\n'
  done < <(find -H "$root" -depth -type d -print0)
  while IFS= read -r -d '' e; do
    if link_ours "$e"; then drop_link rule "$e"; else foreign=$((foreign + 1)); fi
  done < <(find -H "$root" -type l -print0)
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    if [ "$YES" = 1 ] && ! rmdir -- "$d" 2>/dev/null; then say_failed "dir $d (cannot remove)"; continue; fi
    say_remove "empty dir $d"
  done <<EOF
$drop
EOF
  [ "$foreign" -eq 0 ] || say_kept "$root: $foreign entr$([ "$foreign" -eq 1 ] && echo y || echo ies) not ours"
}

# --- other harnesses' skills and agents dirs -------------------------------------
# Every distinct non-Claude dir in the registry, active or not (a deactivated harness
# may still hold links), resolved the way wire.sh resolves them.
step_harness_links() {
  local h col raw dir seen="|"
  while IFS= read -r h; do
    [ "$h" = claude ] && continue
    for col in skills_dir agents_dir; do
      raw="$(harness_field "$h" "$col")"
      [ "$raw" != "-" ] || continue
      case "$seen" in *"|$raw|"*) continue ;; esac
      seen="$seen$raw|"
      if ! dir="$(harness_path "$raw" 2>/dev/null)"; then
        echo "uninstall: warning: cannot resolve harness dir $raw (is HOME set?); not checked" >&2
        continue
      fi
      step_links "$dir" "harness"
    done
  done < <(harness_names)
}

# --- the generated auto-handoff hook ----------------------------------------------
# Same emitter and call wire.sh uses; --hooks "" asks for none, so every entry it
# generated goes and hand-written hooks and keys are never edited. --dry-run lists the
# `remove` lines, which is also how the plan is counted.
step_hook() {
  local emitter="$GRID_DIR/agent-factory/deploy_hooks.py" settings="$CLAUDE_CONFIG_DIR/settings.json"
  local out rc=0 ids id
  [ -f "$emitter" ] || return 0                       # a grid without the emitter wrote no hook
  { [ -e "$settings" ] || [ -L "$settings" ]; } || return 0
  if ! command -v python3 >/dev/null 2>&1; then
    say_failed "hook: python3 not found, cannot inspect $settings"; return 0
  fi
  out="$(python3 "$emitter" --user --hooks "" --dry-run 2>&1)" || rc=$?
  if [ "$rc" -ne 0 ]; then   # symlinked or invalid settings: the emitter refuses, so do we
    say_failed "hook: $settings not inspected: $(printf '%s\n' "$out" | head -n 1)"; return 0
  fi
  ids="$(printf '%s\n' "$out" | sed -n 's/^  remove  *\([a-z0-9-]*\) .*/\1/p')"
  [ -n "$ids" ] || return 0
  if [ "$YES" = 1 ] && ! out="$(python3 "$emitter" --user --hooks "" 2>&1)"; then
    say_failed "hook: $settings not changed: $(printf '%s\n' "$out" | head -n 1)"; return 0
  fi
  for id in $ids; do say_remove "hook $id entry in $settings (your own hooks and keys stay)"; done
}

# --- rules blocks delivered into other harnesses' instruction files ---------------
# rules.py marks its block with BEGIN/END lines (scripts/lib/rules-markers.txt). Only a
# file holding that marker is considered. Removal goes through rules.py itself (empty
# pack list); when it cannot be done cleanly (symlinked file, unbalanced markers) the
# file is left alone and what remains is printed.
step_rules_blocks() {
  local h raw file act out rc
  while IFS= read -r h; do
    [ "$h" = claude ] && continue
    raw="$(harness_field "$h" rules_file)"; [ "$raw" != "-" ] || continue
    file="$(harness_path "$raw" 2>/dev/null)" || continue
    { [ -f "$file" ] || [ -L "$file" ]; } || continue
    [ -n "$HARNESS_BLOCK_BEGIN" ] || continue
    grep -qF -- "$HARNESS_BLOCK_BEGIN" "$file" 2>/dev/null || continue
    act="$(harness_rules_action "$file" 0 "" "$raw")"
    if [ "$act" != remove ]; then
      say_kept "rules block remains in $file (symlink or not an instruction file the grid may edit); delete the lines from the BEGIN to the END marker by hand"
      continue
    fi
    rc=0
    if [ "$YES" = 1 ]; then
      out="$(harness_rules_emit "$(harness_field "$h" rules_harness)" "" "$file" 2>&1)" || rc=$?
    else
      # --check writes nothing: rc 1 = a block would be removed, 2 = refused (damaged markers).
      out="$(harness_rules_emit "$(harness_field "$h" rules_harness)" "" "$file" --check 2>&1)" || rc=$?
      [ "$rc" -ne 1 ] || rc=0
    fi
    if [ "$rc" -ne 0 ]; then
      say_kept "rules block remains in $file ($(printf '%s' "$out" | head -n 1)); delete the lines from the BEGIN to the END marker by hand"
      N_FAILED=$((N_FAILED + 1))
      continue
    fi
    say_remove "rules block in $file"
  done < <(harness_names)
}

# --- `grid install` ledger ----------------------------------------------------------
# `scripts/grid uninstall` owns the ledger and the dirs it placed under repos/. Its link
# lines are left out of the output: step_links lists those. It refreshes wire.sh when it
# removed something; that is why this step runs BEFORE the sweeps.
step_ledger() {
  local ledger="$STATE/installed.manifest" out rc=0 line
  [ -f "$ledger" ] || return 0
  if [ ! -f "$GRID_DIR/scripts/grid" ] || ! command -v python3 >/dev/null 2>&1; then
    say_failed "ledger $ledger: python3 or scripts/grid missing, cannot run 'grid uninstall'"; return 0
  fi
  if [ "$YES" = 1 ]; then out="$(python3 "$GRID_DIR/scripts/grid" uninstall --yes 2>&1)" || rc=$?
  else out="$(python3 "$GRID_DIR/scripts/grid" uninstall 2>&1)" || rc=$?; fi
  while IFS= read -r line; do
    case "$line" in
      "would remove dir "*|"removing dir "*|"would remove ledger "*|"removing ledger "*)
        N_ITEMS=$((N_ITEMS + 1)); printf 'grid install  %s\n' "$line" ;;
      "would remove link "*|"removing link "*|"nothing to remove"|"grid: dry run: "*|"") ;;
      *) printf 'grid install  %s\n' "$line" ;;
    esac
  done <<EOF
$out
EOF
  if [ "$rc" -ne 0 ]; then say_failed "'grid uninstall' exited $rc (see above)"; fi
}

# --- scheduled jobs: detect and PRINT, never run ------------------------------------
# Files written by scripts/usage/install-schedule.sh, `grid schedule install`, or saved by
# hand from `instincts.sh schedule`; plus crontab lines that run something in the clone.
report_schedules() {
  local la="${LAUNCH_AGENTS_DIR:-$HOME_DIR/Library/LaunchAgents}" sd="${SYSTEMD_USER_DIR:-$HOME_DIR/.config/systemd/user}"
  local j f lines="" cron=""
  for j in usage instincts drift; do
    f="$la/io.the-grid.$j.plist"
    # shellcheck disable=SC2016  # $(id -u) is printed for the person's shell to expand
    [ ! -e "$f" ] || lines="$lines  launchctl bootout gui/\$(id -u)/io.the-grid.$j; rm \"$f\""$'\n'
    if [ -e "$sd/grid-$j.timer" ] || [ -e "$sd/grid-$j.service" ]; then
      lines="$lines  systemctl --user disable --now grid-$j.timer; rm -f \"$sd/grid-$j.timer\" \"$sd/grid-$j.service\"; systemctl --user daemon-reload"$'\n'
    fi
  done
  if command -v crontab >/dev/null 2>&1; then
    cron="$(crontab -l 2>/dev/null | grep -F -- "$GRID_DIR/scripts/" || true)"
  fi
  [ -n "$lines$cron" ] || return 0
  echo "scheduled jobs found. NOT touched; deactivate them yourself:"
  printf '%s' "$lines"
  if [ -n "$cron" ]; then
    echo "  crontab -e   # delete these lines:"
    printf '%s\n' "$cron" | sed 's/^/    /'
  fi
  if [ "$PURGE" = 1 ]; then echo "  (--purge deletes the clone these jobs run from: deactivate them first)"; fi
}

# --- --purge --------------------------------------------------------------------------
# path_inside <path> <root>: <path> is <root> or below it (both already physical).
path_inside() { case "$1/" in "$2"/*) return 0 ;; esac; return 1; }

# guard_path <path> <label>: refuse a purge target that is, contains or sits in a place that
# must survive: /, HOME, or the private repo (~/.the-grid-private, and GRID_PRIVATE_DIR when
# that points elsewhere). Returns 1 with the reason printed.
guard_path() {
  local p="$1" label="$2" home priv
  home="$(cd "${HOME_DIR:-/nonexistent}" 2>/dev/null && pwd -P || true)"
  if [ "$p" = / ] || [ -z "$p" ]; then echo "uninstall: refusing to purge $label: it is /" >&2; return 1; fi
  if [ -n "$home" ] && path_inside "$home" "$p"; then
    echo "uninstall: refusing to purge $label ($p): it is, or contains, your home directory" >&2; return 1
  fi
  for priv in "$HOME_DIR/.the-grid-private" "${GRID_PRIVATE_DIR:-}"; do
    [ -n "$priv" ] || continue
    priv="$(cd "$priv" 2>/dev/null && pwd -P || printf '%s' "$priv")"
    if path_inside "$priv" "$p" || path_inside "$p" "$priv"; then
      echo "uninstall: refusing to purge $label ($p): it overlaps the private repo ($priv)" >&2; return 1
    fi
  done
  return 0
}

purge_preflight() {
  [ "$PURGE" = 1 ] || return 0
  local state_phys="" why="" wt n ignored
  if [ -L "$STATE" ]; then
    # A symlinked state dir: only the link is removed, so judge the link's own location,
    # not its target.
    state_phys="$(cd -P "$(dirname "$STATE")" && pwd -P)/${STATE##*/}"
  elif [ -d "$STATE" ]; then
    state_phys="$(cd -P "$STATE" && pwd -P)"
  fi
  guard_path "$GRID_DIR" "the clone" || exit 1
  if [ -n "$state_phys" ]; then
    guard_path "$state_phys" "the state dir" || exit 1
    # The state dir must not be (or sit in) the Claude config dir or the clone: both
    # hold things --purge must not take with it.
    local cfg_phys
    cfg_phys="$(cd "$CLAUDE_CONFIG_DIR" 2>/dev/null && pwd -P || true)"
    if [ -n "$cfg_phys" ] && path_inside "$state_phys" "$cfg_phys"; then
      echo "uninstall: refusing to purge the state dir ($state_phys): it is, or is inside, the Claude config dir ($cfg_phys)" >&2; exit 1
    fi
    if path_inside "$state_phys" "$GRID_DIR"; then
      echo "uninstall: refusing to purge the state dir ($state_phys): it is, or is inside, the clone ($GRID_DIR)" >&2; exit 1
    fi
  fi

  # Work that exists only in the clone: uncommitted changes, commits no remote has, stashes,
  # and the same for linked worktrees inside it. --force overrides, naming what it overrides.
  if ! git -C "$GRID_DIR" rev-parse --git-dir >/dev/null 2>&1; then
    why="$GRID_DIR is not a git clone, so unsaved work cannot be ruled out"
  else
    export GIT_OPTIONAL_LOCKS=0
    n="$(git -C "$GRID_DIR" status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
    [ "$n" -eq 0 ] || why="$why; $n uncommitted change(s) in the clone"
    n="$(git -C "$GRID_DIR" log HEAD --branches --not --remotes --oneline 2>/dev/null | wc -l | tr -d ' ')"
    [ "$n" -eq 0 ] || why="$why; $n commit(s) not on any remote (unpushed)"
    n="$(git -C "$GRID_DIR" stash list 2>/dev/null | wc -l | tr -d ' ')"
    [ "$n" -eq 0 ] || why="$why; $n stash entr$([ "$n" -eq 1 ] && echo y || echo ies)"
    while IFS= read -r wt; do
      wt="$(cd "$wt" 2>/dev/null && pwd -P)" || continue
      [ "$wt" != "$GRID_DIR" ] || continue
      path_inside "$wt" "$GRID_DIR" || continue
      n="$(git -C "$wt" status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
      [ "$n" -eq 0 ] || why="$why; worktree $wt has $n uncommitted change(s)"
    done < <(git -C "$GRID_DIR" worktree list --porcelain 2>/dev/null | sed -n 's/^worktree //p')
    why="${why#; }"
  fi
  if [ -n "$why" ]; then
    if [ "$FORCE" = 1 ]; then
      echo "uninstall: --force: purging anyway despite: $why" >&2
    else
      echo "uninstall: refusing to purge, nothing changed: $why" >&2
      echo "uninstall: commit and push it, or re-run without --purge, or pass --force to discard it" >&2
      exit 1
    fi
  fi
  # What a purge loses besides tracked files: personal curation that is gitignored.
  if git -C "$GRID_DIR" rev-parse --git-dir >/dev/null 2>&1; then
    ignored="$(git -C "$GRID_DIR" ls-files -o -i --exclude-standard --directory 2>/dev/null | head -n 8 | paste -sd' ' -)"
    [ -z "$ignored" ] || echo "note: --purge also deletes gitignored files in the clone, e.g.: $ignored"
  fi
}

step_purge() {
  [ "$PURGE" = 1 ] || {
    if [ -d "$STATE" ]; then say_kept "$STATE (state dir: instincts and learning data; --purge deletes it)"; fi
    return 0
  }
  # Run from outside the dir being deleted.
  cd /
  if [ -L "$STATE" ]; then
    # Never rm -rf through a symlink: drop the link, keep what it points at.
    if [ "$YES" = 1 ] && ! rm -- "$STATE"; then say_failed "state dir link $STATE (cannot remove)"
    else say_remove "state dir $STATE (a symlink: only the link goes, its target is kept)"; fi
  elif [ -d "$STATE" ]; then
    if [ "$YES" = 1 ] && ! rm -rf -- "$STATE"; then say_failed "state dir $STATE (cannot remove)"
    else say_remove "state dir $STATE"; fi
  fi
  if [ "$YES" = 1 ] && ! rm -rf -- "$GRID_DIR"; then say_failed "clone $GRID_DIR (cannot remove)"
  else say_remove "clone $GRID_DIR"; fi
}

main
