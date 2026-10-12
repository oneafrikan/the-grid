#!/usr/bin/env bash
# hooks/lib/auto-handoff-worker.sh <session_id> <transcript_path> <cwd> <reason>
#
# The detached half of the auto-handoff hook (hooks/scripts/auto-handoff.sh starts it
# with its own session and an outer alarm; never run it from a hook's foreground).
# Flow, numbered as in openspec/changes/hook-profiles/design.md "Auto-handoff flow":
#
#   0  read the transcript through one jq prefilter (invalid and sidechain lines gone)
#   1  unreadable transcript            -> skip   no-transcript
#   2  a handoff already ran            -> skip   already-ran
#   3  fewer than MIN_TURNS human turns -> skip   short-session
#   4  same session, no new turns       -> skip   no-new-turns
#      (GRID_AUTOHANDOFF_FORCE=1 bypasses 2 to 4 only)
#   5  digest the transcript into a private temp dir; create the fallback dir
#   6  snapshot .git/config and .git/hooks/, stamp the clock, run `claude -p "/handoff ..."`
#      in <cwd> (write-only tool set, wall-clock alarm, budget cap)
#   7  verify what the child wrote: .git untouched, exactly one handoff pair, nothing else new
#   8  secret-scan both files (always); a hit quarantines them
#   9  commit the pair by explicit path, in the repo that holds the files
#  10  push, but only the private repo and only when that commit is the sole unpushed one
#  11  write the per-session marker, log, record the run
#
# The child only WRITES the two files. This script (deterministic shell) checks,
# scans, commits and pushes, so a model can never be talked into sweeping up the
# operator's staged work, planting a git hook or committing a secret.
#
# Log: one line per decision in ${GRID_HOOK_LOG_DIR:-$HOME/.grid/hook-logs}/auto-handoff.log
#   ts=<UTC> session=<id> action=<skip|spawn|done|error> reason=<token> [turns= commit= push= paths= ...]
# Env knobs: GRID_AUTOHANDOFF_{MIN_TURNS,MAX_BYTES,TIMEOUT,MAX_USD,FORCE},
#   GRID_HANDOFF_FALLBACK_DIR, GRID_PRIVATE_DIR, GRID_CLAUDE, GRID_HOOK_LOG_DIR,
#   GRID_HOOK_STATE_DIR, GRID_STATE_DIR (quarantine root).
#
# Bash 3.2-compatible (no mapfile, no associative arrays); no `set -u` (empty arrays).

# The digest is a copy of the conversation: nothing this script creates may be
# readable by other users. First command, before anything else runs.
umask 077
LC_ALL=C; export LC_ALL

SID="${1:-}"; TRANSCRIPT="${2:-}"; CWD="${3:-}"; END_REASON="${4:-}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
GRID_ROOT="$(cd "$HERE/../.." && pwd -P)"
# shellcheck source=common.sh
. "$HERE/common.sh"
# shellcheck source=secret-patterns.sh
. "$HERE/secret-patterns.sh"

# ---- knobs (a non-numeric value falls back to the default) -----------------------
num() { if [[ "${1:-}" =~ ^[0-9]+$ ]]; then printf '%s' "$1"; else printf '%s' "$2"; fi; }
MIN_TURNS="$(num "${GRID_AUTOHANDOFF_MIN_TURNS:-}" 5)"
MAX_BYTES="$(num "${GRID_AUTOHANDOFF_MAX_BYTES:-}" 300000)"
TIMEOUT="$(num "${GRID_AUTOHANDOFF_TIMEOUT:-}" 900)"
MAX_USD="${GRID_AUTOHANDOFF_MAX_USD:-1.00}"
[[ "$MAX_USD" =~ ^[0-9]+(\.[0-9]+)?$ ]] || MAX_USD="1.00"
FORCE="${GRID_AUTOHANDOFF_FORCE:-0}"

LOG="${GRID_HOOK_LOG_DIR:-$HOME/.grid/hook-logs}/auto-handoff.log"
STATE="${GRID_HOOK_STATE_DIR:-$HOME/.grid/hook-state}/handoff"
QUARANTINE="${GRID_STATE_DIR:-$HOME/.grid}/handoff-quarantine"
PRIVATE="${GRID_PRIVATE_DIR:-$HOME/.the-grid-private}"
FALLBACK_ROOT="${GRID_HANDOFF_FALLBACK_DIR:-$PRIVATE/handoffs}"

# Temp state, all removed by the EXIT trap (the digest is a copy of the conversation).
DIGEST_DIR=""; SNAP_DIR=""
# Lock directories this process holds (see take_lock); released here on every exit path.
LOCKS=()
cleanup() {
  local l
  [ -n "$DIGEST_DIR" ] && rm -rf "$DIGEST_DIR"
  [ -n "$SNAP_DIR" ] && rm -rf "$SNAP_DIR"
  for l in "${LOCKS[@]}"; do rmdir "$l" 2>/dev/null; done
  return 0
}
trap cleanup EXIT

# ---- logging and the run record ---------------------------------------------------
# log <action> <reason> [extra key=value tokens]
log() {
  grid_log "$LOG" "ts=$(date -u +%Y-%m-%dT%H:%M:%SZ) session=$SID action=$1 reason=$2${3:+ $3}"
}
# record <ok|error|skipped> <note>: one run-record line; never fatal (needs python3).
record() {
  "$GRID_ROOT/scripts/run-record.sh" --role auto-handoff --action handoff --outcome "$1" \
    --target "$(basename "${CWD:-unknown}")" --note "$2" >/dev/null 2>&1 || true
}
# finish_skip / finish_error <reason> [extra]: log, record and leave. Exit is 0 either
# way: nobody is waiting for this process, the log is the report.
finish_skip()  { log skip "$1" "${2:-}"; record skipped "$1"; exit 0; }
finish_error() { log error "$1" "${2:-}"; record error "$1"; exit 0; }

# ---- small helpers ----------------------------------------------------------------
# rp <path>: physical path of a file or directory (no readlink -f: not on stock macOS).
rp() {
  local p="$1"
  if [ -d "$p" ]; then (cd "$p" 2>/dev/null && pwd -P)
  else
    local d; d="$(cd "$(dirname "$p")" 2>/dev/null && pwd -P)" || return 1
    printf '%s/%s\n' "$d" "$(basename "$p")"
  fi
}
# disp <path>: the path relative to cwd when it is under it (keeps log lines short).
disp() {
  local p="$1"
  case "$p" in
    "$CWD"/*) p="${p#"$CWD"/}" ;;
    "$CWD_REAL"/*) p="${p#"$CWD_REAL"/}" ;;
  esac
  printf '%s' "${p//[$'\n\r']/?}"
}
# join_csv <items...>: comma-joined, for log tokens.
join_csv() { local out="" i; for i in "$@"; do out="${out:+$out,}$i"; done; printf '%s' "$out"; }
# trim <string>: strip surrounding whitespace.
trim() { local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; s="${s%"${s##*[![:space:]]}"}"; printf '%s' "$s"; }

# The ONE transcript prefilter: lines that are not valid JSON (a truncated last line
# must not break parsing) and sidechain (subagent) lines are dropped. Every later
# step reads the transcript through this. transcript-digest.sh carries the same filter.
prefilter() {
  jq -R -c 'fromjson? | select(type == "object" and .isSidechain != true)' "$TRANSCRIPT" 2>/dev/null
}

# jq helper definitions shared by the already-ran check and the turn counter.
JQ_DEFS='
  # text of a content value: a string, or the text blocks of an array (never tool_result)
  def texts: if type == "string" then .
             elif type == "array" then .[] | select(type == "object" and .type == "text") | (.text // "")
             else empty end;
  # a human turn: non-meta user line; content is a non-empty string, or an array with a
  # text block and no tool_result block
  def human: .type == "user" and (.isMeta != true)
             and (.message.content
                  | if type == "string" then length > 0
                    elif type == "array" then (any(.[]; type == "object" and .type == "text")
                                               and (any(.[]; type == "object" and .type == "tool_result") | not))
                    else false end);
'

# ---- 0/1: payload and transcript --------------------------------------------------
case "$SID" in ''|*[!A-Za-z0-9_-]*) SID="unknown"; finish_skip bad-payload ;; esac
# The id is a file name (marker, lock, quarantine dir): cap it well under NAME_MAX.
[ "${#SID}" -le 64 ] || { SID="unknown"; finish_skip bad-payload; }
if [ -z "$TRANSCRIPT" ] || [ -z "$CWD" ] || [ ! -d "$CWD" ]; then finish_skip bad-payload; fi
CWD_REAL="$(rp "$CWD")" || finish_skip bad-payload
# A session started in HOME (or / or a parent of HOME) would have the whole home tree as
# its scan root: the worker's own log is "new" there, so such a run could never succeed.
HOME_REAL="$(rp "$HOME" 2>/dev/null)" || HOME_REAL="$HOME"
[ "$CWD_REAL" = "/" ] && finish_skip cwd-too-broad
case "$HOME_REAL/" in "$CWD_REAL"/*) finish_skip cwd-too-broad ;; esac
if [ ! -f "$TRANSCRIPT" ] || [ ! -r "$TRANSCRIPT" ]; then finish_skip no-transcript; fi

# ---- per-session lock ------------------------------------------------------------------
# SessionEnd can fire several times for one session (5 simultaneous payloads gave 5 paid
# model runs, 4 of them commit-failed). mkdir is the atomic test-and-set; a lock older than
# TIMEOUT + 300 s belongs to a worker that died without its EXIT trap and is taken over.
# take_lock <dir>: 0 and registered for release in cleanup(), or 1 when someone holds it.
take_lock() {
  local d="$1" mins=$(( (TIMEOUT + 300 + 59) / 60 ))
  if ! mkdir "$d" 2>/dev/null; then
    [ -n "$(find "$d" -maxdepth 0 -mmin "+$mins" 2>/dev/null)" ] || return 1
    rmdir "$d" 2>/dev/null
    mkdir "$d" 2>/dev/null || return 1
  fi
  LOCKS+=("$d")
  return 0
}
mkdir -p "$STATE" 2>/dev/null
take_lock "$STATE/$SID.lock" || finish_skip already-running

# Human-turn count (always computed: the marker stores it, the log shows it).
TURNS="$(prefilter | jq -n "$JQ_DEFS"'[inputs | select(human)] | length' 2>/dev/null)"
[[ "$TURNS" =~ ^[0-9]+$ ]] || TURNS=0

if [ "$FORCE" != 1 ]; then
  # ---- 2: has a handoff already run in this session? -------------------------------
  # Three signals, anywhere in the session:
  #   a) a user/system line whose TEXT STARTS with <command-name>/handoff</command-name>
  #      (after the optional <command-message> line Claude Code emits first; a tag typed
  #      mid-sentence is not a handoff, D33)
  #      (or /<plugin>:handoff); tool_result blocks never count, because the same tag
  #      appears inside tool output whenever a transcript is cat-ed
  #   b) an assistant Skill tool_use whose input.skill is handoff or <x>:handoff
  #   c) an assistant Write/Edit tool_use whose file_path ends -handoff.md
  if prefilter | jq -e -n "$JQ_DEFS"'
      any(inputs;
        ((.type == "user" or .type == "system")
           and any((.message.content?, .content?) | texts; type == "string" and test("^\\s*(<command-message>[^<]*</command-message>\\s*)?<command-name>/([^<>:/]+:)?handoff</command-name>")))
        or (.type == "assistant"
           and any(.message.content[]?; type == "object" and .type == "tool_use" and .name == "Skill"
                   and ((.input.skill // "") | test("(^|:)handoff$"))))
        or (.type == "assistant"
           and any(.message.content[]?; type == "object" and .type == "tool_use"
                   and (.name == "Write" or .name == "Edit")
                   and ((.input.file_path // "") | endswith("-handoff.md")))))' >/dev/null 2>&1; then
    finish_skip already-ran
  fi
  # ---- 3: trivial session ----------------------------------------------------------
  if [ "$TURNS" -lt "$MIN_TURNS" ]; then finish_skip short-session "turns=$TURNS"; fi
  # ---- 4: same session already handed off, and no new work since -------------------
  if [ -f "$STATE/$SID" ]; then
    T0="$(cat "$STATE/$SID" 2>/dev/null)"
    if [[ "$T0" =~ ^[0-9]+$ ]] && [ "$TURNS" -lt $((T0 + MIN_TURNS)) ]; then
      finish_skip no-new-turns "turns=$TURNS"
    fi
  fi
fi

# ---- per-cwd lock ------------------------------------------------------------------
# Handoff pairs carry no session id in their names, so one session's pair cannot be told
# apart on disk from another's. Two sessions in the same directory therefore take turns:
# the second waits up to GRID_AUTOHANDOFF_WAIT seconds (default 120), then skips as
# cwd-busy WITHOUT a marker (it may be retried later). A build or editor writing into the
# directory during the run is still reported as unexpected-file.
WAIT="$(num "${GRID_AUTOHANDOFF_WAIT:-}" 120)"
CWD_KEY="$(printf '%s' "$CWD_REAL" | cksum | cut -d' ' -f1)"
waited=0
until take_lock "$STATE/cwd-$CWD_KEY.lock"; do
  [ "$waited" -ge "$WAIT" ] && finish_skip cwd-busy
  sleep 1; waited=$((waited + 1))
done

# ---- 5: digest, fallback dir, target dir -------------------------------------------
DIGEST_DIR="$(mktemp -d)" || finish_error digest-failed
SNAP_DIR="$(mktemp -d)" || finish_error digest-failed
DIGEST="$DIGEST_DIR/session-digest.md"
bash "$HERE/transcript-digest.sh" "$TRANSCRIPT" "$DIGEST" "$MAX_BYTES" 2>/dev/null || finish_error digest-failed

# The child writes into <fallback>/<basename of cwd>; the worker creates it (the child
# has no mkdir). A failure to create it is not fatal: the child may still use <target>.
# The directory name goes into a permission rule, so glob metacharacters and newlines in
# the cwd's name become `_` here (see add_rule); the prompt names this exact path.
FALLBACK_NAME="$(basename "$CWD")"; FALLBACK_NAME="${FALLBACK_NAME//$'\n'/_}"
FALLBACK_NAME="$(printf '%s' "$FALLBACK_NAME" | sed 's/[][*?{}()!]/_/g')"
FALLBACK="$FALLBACK_ROOT/$FALLBACK_NAME"
mkdir -p "$FALLBACK" 2>/dev/null
FALLBACK_REAL="$(rp "$FALLBACK" 2>/dev/null)" || FALLBACK_REAL="$FALLBACK"

# resolve_target: the directory the handoff skill will choose, with the skill's own
# first-match rule (skills/handoff/SKILL.md "Document locations reference"):
#   1. the first row of ~/.the-grid-private/handoff-locations.md whose first column
#      matches the cwd name or path glob; its location (relative = against cwd)
#   2. otherwise the existing direct child of cwd named logs, in any casing
# Sets TARGET to an absolute, EXISTING directory, or "" (no rule for it is then
# granted and the child can write only to the fallback dir).
resolve_target() {
  TARGET=""; TARGET_ROW=0; ROW_LOC=""
  # The table lives with the private data: GRID_PRIVATE_DIR first, then the default home
  # location (the skill documents ~/.the-grid-private/ and reads only that one).
  local table="$PRIVATE/handoff-locations.md" base line c1 c2 loc e matched=0
  [ -r "$table" ] || table="$HOME/.the-grid-private/handoff-locations.md"
  base="$(basename "$CWD")"
  if [ -r "$table" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in '|'*) ;; *) continue ;; esac
      IFS='|' read -r _ c1 c2 _ <<< "$line"
      c1="$(trim "$c1")"; c1="${c1//\`/}"
      c2="$(trim "$c2")"; c2="${c2//\`/}"
      [ -n "$c1" ] || continue
      case "$c1" in *[!-]*) ;; *) continue ;; esac     # a |---|---| separator row
      # c1 is a glob on purpose (a directory name or a path pattern).
      # shellcheck disable=SC2254
      case "$base" in $c1) matched=1 ;; esac
      # shellcheck disable=SC2254
      case "$CWD" in $c1) matched=1 ;; esac
      if [ "$matched" = 1 ]; then
        loc="$c2"
        # a leading ~ is a literal in the table; expand it to $HOME by hand
        case "$loc" in \~|\~/*) loc="$HOME${loc#\~}" ;; esac
        case "$loc" in /*) ;; *) loc="$CWD/$loc" ;; esac
        loc="${loc%/}"
        ROW_LOC="$loc"
        [ -d "$loc" ] && { TARGET="$loc"; TARGET_ROW=1; }
        return 0
      fi
    done < "$table"
  fi
  for e in "$CWD"/[Ll][Oo][Gg][Ss]; do
    if [ -d "$e" ]; then TARGET="$e"; return 0; fi
  done
  return 0
}
resolve_target

# accept_target: containment for the directory the child will be granted write access to.
# `[ -d ]` follows symlinks, so a tracked LOGS -> <any dir> link, or a table row (the agent
# can edit that file), used to turn into a write grant anywhere (R07.sec.F1, high). The
# resolved path must now be under the cwd or the private repo. The one designed exception
# is a table row naming another repo (tests: "mapped location outside cwd"): absolute,
# no `..` component, inside a git work tree, and not HOME, / or a sensitive dir. Anything
# else is refused: TARGET stays empty, only the fallback dir is granted, and the spawn log
# line says why (target-refused=<why>).
PRIVATE_REAL="$(rp "$PRIVATE" 2>/dev/null)" || PRIVATE_REAL="$PRIVATE"
TARGET_REAL=""; TARGET_WHY=""
accept_target() {
  [ -n "$TARGET" ] || return 0
  local real s
  real="$(rp "$TARGET")" || { TARGET=""; return 0; }
  case "$real/" in
    "$CWD_REAL"/*|"$PRIVATE_REAL"/*) TARGET_REAL="$real"; return 0 ;;
  esac
  if [ "$TARGET_ROW" != 1 ]; then
    TARGET_WHY="symlink-outside"
  else
    case "$ROW_LOC/" in
      */../*) TARGET_WHY="dotdot" ;;
    esac
    if [ -z "$TARGET_WHY" ]; then
      case "$real" in
        /|"$HOME"|"$HOME_REAL") TARGET_WHY="home-or-root" ;;
      esac
    fi
    if [ -z "$TARGET_WHY" ]; then
      for s in .ssh .claude .config .gnupg .aws; do
        case "$real/" in "$HOME/$s"/*|"$HOME_REAL/$s"/*) TARGET_WHY="sensitive-dir" ;; esac
      done
      [ -n "${CLAUDE_CONFIG_DIR:-}" ] && case "$real/" in "$CLAUDE_CONFIG_DIR"/*) TARGET_WHY="sensitive-dir" ;; esac
    fi
    if [ -z "$TARGET_WHY" ] && [ "$(git -C "$real" rev-parse --is-inside-work-tree 2>/dev/null)" != true ]; then
      TARGET_WHY="not-a-git-work-tree"
    fi
    [ -z "$TARGET_WHY" ] && { TARGET_REAL="$real"; return 0; }
  fi
  TARGET=""
}
accept_target

# Path-scoped write rules: Edit(//<abs path>/**) in default permission mode is the form
# Claude Code enforces (tests/fixtures/hooks/README.md, task 0.6); `//` anchors at the
# filesystem root, so it is "/" in front of the absolute path. Never a bare Edit/Write.
RULES=()
add_rule() {
  # A path with a glob metacharacter (or a newline) would widen or break the rule, and a
  # `..` component is not a normalised path: grant nothing for it. The fallback dir (whose
  # name is sanitised below) then remains the child's place to write.
  case "$1" in
    *[\*\?\[\]\{\}\(\)\!]*|*$'\n'*) return 0 ;;
    */../*|*/..) return 0 ;;
  esac
  local r="Edit(/${1}/**)" x
  for x in "${RULES[@]}"; do [ "$x" = "$r" ] && return 0; done
  RULES+=("$r")
}
if [ -n "$TARGET" ]; then add_rule "$TARGET"; add_rule "$TARGET_REAL"; fi
add_rule "$FALLBACK"; add_rule "$FALLBACK_REAL"

# ---- 6: snapshot .git, stamp, run the child ----------------------------------------
# A changed git config, hook, info/ file or HEAD means the write-only boundary failed, and
# the commit below runs in the TARGET repo, not only the cwd repo: a hook planted there
# would execute as the operator (R07.sec.F2). So every repo we will read or commit in is
# watched: the cwd repo, the target repo and the fallback repo. State = path + type +
# checksum (or link target), written outside any directory the child can see.
GITDIRS=()
# add_gitdir <dir>: remember the git dir (and the common dir of a linked worktree, where
# config and hooks live) of the repo containing <dir>, once.
add_gitdir() {
  local g c x
  [ -d "$1" ] || return 0
  g="$(git -C "$1" rev-parse --absolute-git-dir 2>/dev/null)" || return 0
  [ -n "$g" ] || return 0
  c="$(cd "$1" && cc="$(git rev-parse --git-common-dir 2>/dev/null)" && cd "$cc" 2>/dev/null && pwd -P)"
  for x in "$g" "$c"; do
    [ -n "$x" ] && { have_gitdir "$x" || GITDIRS+=("$x"); }
  done
  return 0
}
have_gitdir() { local x; for x in "${GITDIRS[@]}"; do [ "$x" = "$1" ] && return 0; done; return 1; }
# state_lines: stdin = paths; prints "<path>\t<F|L>\t<cksum|target>" for every file or
# symlink at or below them (a directory contributes its files). Missing paths print nothing.
state_lines() {
  local p f
  while IFS= read -r p; do
    { [ -e "$p" ] || [ -L "$p" ]; } || continue
    find -P "$p" \( -type f -o -type l \) -print 2>/dev/null
  done | sort -u | while IFS= read -r f; do
    if [ -L "$f" ]; then printf '%s\tL\t%s\n' "$f" "$(readlink "$f")"
    else printf '%s\tF\t%s\n' "$f" "$(cksum < "$f" 2>/dev/null | tr ' ' ':')"; fi
  done
}
# git_watch <gitdir>: the paths whose change means a git hook, alias or ref could now run
# or point somewhere else: config, HEAD, info/, hooks/, a submodule's config and hooks, a
# linked worktree's config/hooks/info, and any core.hooksPath directory.
git_watch() {
  local d="$1" p hp
  for p in "$d/config" "$d/HEAD" "$d/info" "$d/hooks" "$d"/modules/*/config "$d"/modules/*/hooks \
           "$d"/worktrees/*/config.worktree "$d"/worktrees/*/hooks "$d"/worktrees/*/info; do
    printf '%s\n' "$p"
  done
  hp="$(git --git-dir="$d" config --get core.hooksPath 2>/dev/null)"
  if [ -n "$hp" ]; then
    case "$hp" in \~|\~/*) hp="$HOME${hp#\~}" ;; esac
    case "$hp" in /*) ;; *) hp="$(dirname "$d")/$hp" ;; esac
    printf '%s\n' "$hp"
  fi
}
git_state() { git_watch "$1" | state_lines; }

add_gitdir "$CWD"
[ -n "$TARGET_REAL" ] && add_gitdir "$TARGET_REAL"
add_gitdir "$FALLBACK_REAL"
i=0
for d in "${GITDIRS[@]}"; do
  git_state "$d" > "$SNAP_DIR/git$i.state"
  i=$((i + 1))
done

# Files the child must never touch, outside every repo: shell startup files, ssh login
# config, the global git config, Claude's own settings and the user systemd units (each of
# these runs code or grants access later). Same state snapshot, same compare.
home_watch() {
  local f
  for f in .bashrc .bash_profile .bash_login .profile .bash_logout .zshrc .zshenv .zprofile \
           .zlogin .zlogout .gitconfig .ssh/authorized_keys .ssh/config .ssh/rc .config/git/config; do
    printf '%s\n' "$HOME/$f"
  done
  printf '%s\n' "${CLAUDE_CONFIG_DIR:-$HOME/.claude}"/settings*.json "$HOME/.config/systemd/user"
}
home_watch | state_lines > "$SNAP_DIR/home.state"

# Roots the verification scans: the cwd, the fallback dir, the target dir and the work
# trees of the repos the commit lands in (a write elsewhere in the private repo would
# otherwise go unseen). All real paths: find -P never follows a link out of a root.
ROOTS=("$CWD_REAL" "$FALLBACK_REAL")
if [ -n "$TARGET_REAL" ]; then
  case "$TARGET_REAL/" in
    "$CWD_REAL"/*) ;;
    *) ROOTS+=("$TARGET_REAL") ;;
  esac
fi
for d in "$TARGET_REAL" "$FALLBACK_REAL"; do
  [ -n "$d" ] && [ -d "$d" ] || continue
  t="$(git -C "$d" rev-parse --show-toplevel 2>/dev/null)" && [ -n "$t" ] && ROOTS+=("$(rp "$t")")
done
DIGEST_REAL="$(rp "$DIGEST_DIR")"; SNAP_REAL="$(rp "$SNAP_DIR")"   # roots are real paths: prune by real path too
LOG_DIR="$(dirname "$LOG")"; LOG_DIR_REAL="$(rp "$LOG_DIR" 2>/dev/null)" || LOG_DIR_REAL="$LOG_DIR"

# fs_snapshot: "<path> TAB <F|L> TAB <mtime> TAB <size>" for every regular file and symlink
# under ROOTS, sorted. This replaces the old clock stamp (`-newer` a time 2 s before the
# start): a file edited moments before the run, a sibling session's pair or the worker's
# own log under cwd all looked "new" to the stamp. A before/after diff only reports what
# changed DURING the child run. Stat is done in perl with sub-second mtimes (no GNU `find
# -printf`; whole seconds would miss a same-second rewrite). .git is
# pruned (7a watches the parts that matter); so are our temp dirs, Claude's config dir
# and the hook log dir, in case a root happens to contain them.
fs_snapshot() {
  find -P "${ROOTS[@]}" \( -name .git -o -path "$DIGEST_DIR" -o -path "$SNAP_DIR" -o -path "$DIGEST_REAL" \
         -o -path "$SNAP_REAL" -o -path "$HOME/.claude" -o -path "$HOME_REAL/.claude" \
         -o -path "$LOG_DIR" -o -path "$LOG_DIR_REAL" \) -prune \
       -o \( -type f -o -type l \) -print0 2>/dev/null |
    perl -MTime::HiRes=lstat -0ne 'chomp; my @s = lstat($_) or next; print join("\t", $_, (-l _ ? "L" : "F"), $s[9], $s[7]), "\n"' |
    sort -u
}
fs_snapshot > "$SNAP_DIR/fs.before"

TARGET_TEXT="${TARGET:-none (use the fallback directory)}"
PROMPT="/handoff Source conversation is the digest file $DIGEST, not this session. Target directory: $TARGET_TEXT. Fallback directory: $FALLBACK."

# The turn marker is written BEFORE the child runs: whatever the outcome, this session
# is not paid for again until it gains MIN_TURNS new turns (an error outcome used to leave
# no marker, so every later SessionEnd of the session ran the model again).
printf '%s\n' "$TURNS" > "$STATE/$SID" 2>/dev/null
log spawn ok "turns=$TURNS${END_REASON:+ end=${END_REASON//[^A-Za-z0-9_-]/}}${TARGET_WHY:+ target-refused=$TARGET_WHY}"
cd "$CWD" || finish_skip bad-payload
OUT="$SNAP_DIR/child.out"
# GRID_AUTOHANDOFF_CHILD=1 is the recursion guard (the child's own SessionEnd hook
# checks it first). The alarm survives exec, so the child is killed at TIMEOUT and
# the shell sees 142 (128 + SIGALRM). exec failing (no such binary) is exit 127.
#
# Isolation (D-extra-1 B). The rule form Edit(//<abs>/**) is the primary confinement but
# was never proven live, so nothing below depends on it:
#   - --permission-mode default and --setting-sources user: the operator's own
#     permission mode (say acceptEdits) and project settings do not apply to this run
#   - --strict-mcp-config: no MCP server config is picked up
#   - extra denies for the places a write would persist code or access (ssh, Claude and
#     user config, shell startup files, anything under a .git directory)
#   - env -i: the child sees PATH, HOME, locale, TMPDIR, the Claude config dir and OAuth
#     token, the recursion guard, and only what GRID_AUTOHANDOFF_KEEP_ENV names (a comma
#     list of NAMEs or PREFIX*). GH_TOKEN, ANTHROPIC_API_KEY, cloud credentials and
#     SSH_AUTH_SOCK are NOT passed; if claude authenticates through an API key variable,
#     name it in GRID_AUTOHANDOFF_KEEP_ENV.
DENY=("Edit" "Bash(git:*)")
for h in "$HOME" "$HOME_REAL"; do
  for s in .ssh .claude .config .gnupg .aws; do
    case "$h" in *[\*\?\[\]\{\}\(\)\!]*|*$'\n'*) ;; *) DENY+=("Edit(/$h/$s/**)") ;; esac
  done
  for s in .bashrc .bash_profile .bash_login .profile .zshrc .zshenv .zprofile .zlogin .gitconfig; do
    case "$h" in *[\*\?\[\]\{\}\(\)\!]*|*$'\n'*) ;; *) DENY+=("Edit(/$h/$s)") ;; esac
  done
  [ "$HOME_REAL" = "$HOME" ] && break
done
DENY+=("Edit(**/.git/**)")

CHILD_ENV=()
# KEEP_ENV: NAME or PREFIX*; entries that are not plain identifiers are ignored (the value
# is used in an indirect expansion, which must never see anything else).
IFS=, read -r -a KEEP_PATS <<< "${GRID_AUTOHANDOFF_KEEP_ENV:-}"
for pat in "${KEEP_PATS[@]}"; do
  [[ "$pat" =~ ^[A-Za-z_][A-Za-z0-9_]*\*?$ ]] || continue
  case "$pat" in
    *'*')
      pfx="${pat%\*}"
      while IFS= read -r nm; do
        [[ "$nm" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
        case "$nm" in "$pfx"*) CHILD_ENV+=("$nm=${!nm}") ;; esac
      done < <(compgen -e) ;;
    *) [ -n "${!pat+x}" ] && CHILD_ENV+=("$pat=${!pat}") ;;
  esac
done
for nm in LANG LC_ALL TMPDIR CLAUDE_CONFIG_DIR CLAUDE_CODE_OAUTH_TOKEN; do
  [ -n "${!nm+x}" ] && CHILD_ENV+=("$nm=${!nm}")
done
# Last, so nothing above can override them (later assignments win under env).
CHILD_ENV+=("PATH=$PATH" "HOME=$HOME" "GRID_AUTOHANDOFF_CHILD=1")
PERL_BIN="$(command -v perl || printf perl)"

env -i "${CHILD_ENV[@]}" "$PERL_BIN" -e 'alarm shift; exec @ARGV or exit 127' "$TIMEOUT" \
  "${GRID_CLAUDE:-claude}" -p "$PROMPT" \
  --model sonnet --max-turns 25 --max-budget-usd "$MAX_USD" \
  --permission-mode default --setting-sources user --strict-mcp-config \
  --tools "Read,Write,Bash" \
  --allowedTools "Read" "${RULES[@]}" "Bash(hostname:*)" "Bash(realpath:*)" "Bash(readlink:*)" "Bash(ls:*)" "Bash(date:*)" \
  --disallowedTools "${DENY[@]}" \
  --add-dir "$DIGEST_DIR" --add-dir "$FALLBACK" \
  --append-system-prompt-file "$HERE/auto-handoff-system.md" \
  < /dev/null > "$OUT" 2>&1
rc=$?

# Child output into the log, truncated to 4000 bytes and prefixed so it never reads
# as a decision line.
if [ -s "$OUT" ]; then
  { head -c 4000 "$OUT" | sed 's/^/child| /'; echo; } >> "$LOG" 2>/dev/null
fi
case "$rc" in
  0) ;;
  142) finish_error timeout ;;
  *) finish_error "claude-exit-$rc" ;;
esac

# ---- 7: verify what the child wrote -------------------------------------------------
# 7a. .git first, then the files outside every repo: any difference in the watched state
#     fails closed. Nothing is ever moved or deleted: the operator may be using the repo
#     right now. The snapshot is compared by content (checksum / link target), so a file
#     rewritten with identical bytes is not a change.
CHANGED=()
# state_diff <before-file> <after-text-from-stdin>: the paths whose state line differs.
state_diff() {
  diff "$1" - 2>/dev/null | awk -F'\t' '/^[<>] /{sub(/^[<>] /, "", $1); print $1}' | sort -u
}
i=0
for d in "${GITDIRS[@]}"; do
  while IFS= read -r p; do [ -n "$p" ] && CHANGED+=("$p"); done < <(git_state "$d" | state_diff "$SNAP_DIR/git$i.state")
  i=$((i + 1))
done
while IFS= read -r p; do [ -n "$p" ] && CHANGED+=("$p"); done < <(home_watch | state_lines | state_diff "$SNAP_DIR/home.state")
if [ "${#CHANGED[@]}" -gt 0 ]; then
  DISP=(); for p in "${CHANGED[@]}"; do DISP+=("$(disp "$p")"); done
  finish_error unexpected-file "paths=$(join_csv "${DISP[@]}")"
fi

# 7b. what changed under the roots DURING the child run: entries in the after-snapshot that
#     are not in the before-snapshot (new, or a different mtime or size). Symlinks are
#     looked at, never followed (find -P), so a link cannot hide or redirect a write; a
#     symlink named like a handoff file is reported whatever its age, because a
#     pre-planted one would make the child write through it. No -maxdepth: a depth cap
#     lets a deep write go unseen.
NEW=()      # real paths, de-duplicated (the same file can be reached by two roots)
NEW_DISP=()
SYMS=()     # changed or new symlinks, and handoff-named ones of any age
while IFS=$'\t' read -r f ty _mt _sz; do
  [ -n "$f" ] || continue
  r="$(rp "$f")" || continue
  dup=0
  for x in "${NEW[@]}" "${SYMS[@]}"; do [ "$x" = "$r" ] && dup=1; done
  [ "$dup" = 1 ] && continue
  if [ "$ty" = L ]; then SYMS+=("$r")
  else NEW+=("$r"); NEW_DISP+=("$(disp "$f")"); fi
done < <({ fs_snapshot > "$SNAP_DIR/fs.after"; comm -13 "$SNAP_DIR/fs.before" "$SNAP_DIR/fs.after"
           awk -F'\t' '$2 == "L" && ($1 ~ /-handoff\.md$/ || $1 ~ /-context\.md$/)' "$SNAP_DIR/fs.after"; })
if [ "${#SYMS[@]}" -gt 0 ]; then
  DISP=(); for p in "${SYMS[@]}"; do DISP+=("$(disp "$p")"); done
  finish_error unexpected-file "paths=$(join_csv "${DISP[@]}")"
fi

HANDOFFS=()   # indexes into NEW
n=0
for r in "${NEW[@]}"; do
  case "$(basename "$r")" in *-handoff.md) HANDOFFS+=("$n") ;; esac
  n=$((n + 1))
done
if [ "${#HANDOFFS[@]}" -eq 0 ]; then finish_error no-handoff-file; fi

# EXPECTED: one <p>-handoff.md and at most one <p>-context.md with the same <p>, in one
# directory that is the target dir or the fallback dir. Everything else is UNEXPECTED.
HF=""; CTX=""
if [ "${#HANDOFFS[@]}" -eq 1 ]; then
  h="${NEW[${HANDOFFS[0]}]}"
  hdir="$(dirname "$h")"
  if { [ -n "$TARGET_REAL" ] && [ "$hdir" = "$TARGET_REAL" ]; } || [ "$hdir" = "$FALLBACK_REAL" ]; then
    HF="$h"
    prefix="$(basename "$h")"; prefix="${prefix%-handoff.md}"
    for r in "${NEW[@]}"; do
      [ "$r" = "$hdir/$prefix-context.md" ] && CTX="$r"
    done
  fi
fi
UNEXP=()
n=0
for r in "${NEW[@]}"; do
  if [ "$r" != "$HF" ] && { [ -z "$CTX" ] || [ "$r" != "$CTX" ]; }; then UNEXP+=("${NEW_DISP[$n]}"); fi
  n=$((n + 1))
done
if [ "${#UNEXP[@]}" -gt 0 ]; then
  # Detect only: nothing is moved or deleted, every unexpected path is named.
  finish_error unexpected-file "paths=$(join_csv "${UNEXP[@]}")"
fi
PAIR=("$HF"); [ -n "$CTX" ] && PAIR+=("$CTX")

# ---- 8: secret scan (always, whatever the project profile or kill switches say) ----
HITS=()
for f in "${PAIR[@]}"; do
  while IFS= read -r l; do
    [ -n "$l" ] || continue
    # "<path>:<line>: <name> (abcd...)" -> "<file>:<line>:<name>"; never the value.
    l="${l% (*}"; l="${l##*/}"; HITS+=("${l// /}")
  done < <(secret_scan_file "$f")
done
if [ "${#HITS[@]}" -gt 0 ]; then
  # Machine-local quarantine, outside every repo: a later `git add -A` cannot sweep a
  # secret in. The operator reviews and deletes the files.
  QDIR="$QUARANTINE/$SID"
  mkdir -p "$QDIR" && mv -- "${PAIR[@]}" "$QDIR/"
  finish_error secret "secret=$(join_csv "${HITS[@]}") quarantine=$QDIR"
fi

# ---- 9: commit the pair, by explicit path, in the repo that holds the real files ----
R="$(dirname "$HF")"
T="$(git -C "$R" rev-parse --show-toplevel 2>/dev/null)"
if [ -z "$T" ]; then
  # Not inside any git repo: leave the files on disk (the skill's own rule).
  T=""; COMMIT="none"
else
  T="$(rp "$T")"
  RELS=()
  for f in "${PAIR[@]}"; do RELS+=("${f#"$T"/}"); done
  prefix="$(basename "$HF")"; prefix="${prefix%-handoff.md}"
  # add then commit with the same pathspec: only these files, never the operator's
  # other staged work.
  if cout="$(git -C "$T" add -- "${RELS[@]}" 2>&1 \
        && git -C "$T" commit -q -m "docs: auto-handoff $prefix" -- "${RELS[@]}" 2>&1)"; then
    COMMIT="$(git -C "$T" rev-parse --short HEAD 2>/dev/null)"
  else
    # Leave the files on disk; unstage them so the next commit does not pick them up.
    git -C "$T" reset -q -- "${RELS[@]}" >/dev/null 2>&1
    printf 'child| commit failed: %s\n' "$(printf '%s' "$cout" | head -c 400 | tr '\n' ' ')" >> "$LOG" 2>/dev/null
    finish_error commit-failed
  fi
fi

# ---- 10: push, only the private repo and only our own commit -----------------------
PUSH=""
if [ "$COMMIT" != "none" ]; then
  if [ "$T" != "$PRIVATE_REAL" ]; then
    PUSH="no-not-private"
  elif ! git -C "$T" rev-parse --abbrev-ref --symbolic-full-name '@{u}' >/dev/null 2>&1; then
    PUSH="no-upstream"
  elif [ "$(git -C "$T" rev-list --count '@{u}..HEAD' 2>/dev/null)" != "1" ]; then
    # A push sends every unpushed commit; only a handoff-only push is safe unattended.
    PUSH="no-other-commits"
  elif git -C "$T" push -q >/dev/null 2>&1; then
    PUSH="yes"
  else
    PUSH="failed"
  fi
fi

# ---- 11: marker, log, record -------------------------------------------------------
log 'done' ok "turns=$TURNS commit=$COMMIT${PUSH:+ push=$PUSH}"
record ok "commit=$COMMIT${PUSH:+ push=$PUSH}"
exit 0
