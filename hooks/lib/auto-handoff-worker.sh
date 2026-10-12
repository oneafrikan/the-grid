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
DIGEST_DIR=""; SNAP_DIR=""; STAMP=""
cleanup() {
  [ -n "$DIGEST_DIR" ] && rm -rf "$DIGEST_DIR"
  [ -n "$SNAP_DIR" ] && rm -rf "$SNAP_DIR"
  [ -n "$STAMP" ] && rm -f "$STAMP"
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
if [ -z "$TRANSCRIPT" ] || [ -z "$CWD" ] || [ ! -d "$CWD" ]; then finish_skip bad-payload; fi
CWD_REAL="$(rp "$CWD")" || finish_skip bad-payload
if [ ! -f "$TRANSCRIPT" ] || [ ! -r "$TRANSCRIPT" ]; then finish_skip no-transcript; fi

# Human-turn count (always computed: the marker stores it, the log shows it).
TURNS="$(prefilter | jq -n "$JQ_DEFS"'[inputs | select(human)] | length' 2>/dev/null)"
[[ "$TURNS" =~ ^[0-9]+$ ]] || TURNS=0

if [ "$FORCE" != 1 ]; then
  # ---- 2: has a handoff already run in this session? -------------------------------
  # Three signals, anywhere in the session:
  #   a) a user/system line whose TEXT holds <command-name>/handoff</command-name>
  #      (or /<plugin>:handoff); tool_result blocks never count, because the same tag
  #      appears inside tool output whenever a transcript is cat-ed
  #   b) an assistant Skill tool_use whose input.skill is handoff or <x>:handoff
  #   c) an assistant Write/Edit tool_use whose file_path ends -handoff.md
  if prefilter | jq -e -n "$JQ_DEFS"'
      any(inputs;
        ((.type == "user" or .type == "system")
           and any((.message.content?, .content?) | texts; type == "string" and test("<command-name>/([^<>:/]+:)?handoff</command-name>")))
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
HOME_REAL="$(rp "$HOME" 2>/dev/null)" || HOME_REAL="$HOME"
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
# A changed .git/config or .git/hooks means the write-only boundary failed. Copy both
# now (never into a directory the child can see); compare after.
GITDIRS=()
g="$(git -C "$CWD" rev-parse --absolute-git-dir 2>/dev/null)"
if [ -n "$g" ]; then
  GITDIRS+=("$g")
  # In a linked worktree config and hooks live in the common dir: watch it too.
  common="$(cd "$CWD" && c="$(git rev-parse --git-common-dir 2>/dev/null)" && cd "$c" 2>/dev/null && pwd -P)"
  [ -n "$common" ] && [ "$common" != "$g" ] && GITDIRS+=("$common")
fi
i=0
for d in "${GITDIRS[@]}"; do
  mkdir -p "$SNAP_DIR/git$i/hooks"
  [ -f "$d/config" ] && cp "$d/config" "$SNAP_DIR/git$i/config"
  [ -d "$d/hooks" ] && cp -R "$d/hooks/." "$SNAP_DIR/git$i/hooks/" 2>/dev/null
  i=$((i + 1))
done

# Stamp file, backdated 2 s: a coarse-granularity filesystem must not make a file
# written in the same second as the stamp look older than it.
STAMP="$(mktemp)"
perl -e 'my $t = time - 2; utime $t, $t, $ARGV[0]' "$STAMP"

TARGET_TEXT="${TARGET:-none (use the fallback directory)}"
PROMPT="/handoff Source conversation is the digest file $DIGEST, not this session. Target directory: $TARGET_TEXT. Fallback directory: $FALLBACK."

log spawn ok "turns=$TURNS${END_REASON:+ end=${END_REASON//[^A-Za-z0-9_-]/}}${TARGET_WHY:+ target-refused=$TARGET_WHY}"
cd "$CWD" || finish_skip bad-payload
OUT="$SNAP_DIR/child.out"
# GRID_AUTOHANDOFF_CHILD=1 is the recursion guard (the child's own SessionEnd hook
# checks it first). The alarm survives exec, so the child is killed at TIMEOUT and
# the shell sees 142 (128 + SIGALRM). exec failing (no such binary) is exit 127.
GRID_AUTOHANDOFF_CHILD=1 perl -e 'alarm shift; exec @ARGV or exit 127' "$TIMEOUT" \
  "${GRID_CLAUDE:-claude}" -p "$PROMPT" \
  --model sonnet --max-turns 25 --max-budget-usd "$MAX_USD" \
  --tools "Read,Write,Bash" \
  --allowedTools "Read" "${RULES[@]}" "Bash(hostname:*)" "Bash(realpath:*)" "Bash(readlink:*)" "Bash(ls:*)" "Bash(date:*)" \
  --disallowedTools "Edit" "Bash(git:*)" \
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
# 7a. .git first: any difference in config or hooks fails closed. Nothing under .git/
#     is ever moved or deleted, the operator may be using the repo right now.
CHANGED=()
i=0
for d in "${GITDIRS[@]}"; do
  s="$SNAP_DIR/git$i"
  if [ -f "$s/config" ]; then
    cmp -s "$s/config" "$d/config" 2>/dev/null || CHANGED+=("$d/config")
  elif [ -e "$d/config" ]; then
    CHANGED+=("$d/config")
  fi
  if [ -d "$d/hooks" ]; then
    # diff -rq lines: "Only in <dir>: <name>" / "Files <a> and <b> differ"
    while IFS= read -r l; do
      case "$l" in
        "Only in "*) rest="${l#Only in }"; p="${rest%%: *}/${rest#*: }" ;;
        "Files "*" differ") rest="${l#Files * and }"; p="${rest% differ}" ;;
        *) p="$l" ;;
      esac
      # report snapshot-side paths (a removed file) at their live location
      CHANGED+=("${p/#$s/$d}")
    done < <(diff -rq "$s/hooks" "$d/hooks" 2>/dev/null)
  elif [ -n "$(ls -A "$s/hooks" 2>/dev/null)" ]; then
    CHANGED+=("$d/hooks")
  fi
  i=$((i + 1))
done
if [ "${#CHANGED[@]}" -gt 0 ]; then
  DISP=(); for p in "${CHANGED[@]}"; do DISP+=("$(disp "$p")"); done
  finish_error unexpected-file "paths=$(join_csv "${DISP[@]}")"
fi

# 7b. every NEW regular file under cwd, the fallback dir and (when it lies outside cwd)
#     the target dir. No -maxdepth: a depth cap lets a deep write go unseen. .git/ is
#     pruned whole; our own temp dirs are pruned in case TMPDIR sits under cwd.
ROOTS=("$CWD" "$FALLBACK")
if [ -n "$TARGET_REAL" ]; then
  case "$TARGET_REAL/" in
    "$CWD_REAL"/*) ;;
    *) ROOTS+=("$TARGET_REAL") ;;
  esac
fi
NEW=()      # real paths, de-duplicated (the same file can be reached by two roots)
NEW_DISP=()
while IFS= read -r f; do
  [ -n "$f" ] || continue
  r="$(rp "$f")" || continue
  dup=0
  for x in "${NEW[@]}"; do [ "$x" = "$r" ] && dup=1; done
  [ "$dup" = 1 ] && continue
  NEW+=("$r"); NEW_DISP+=("$(disp "$f")")
done < <(find -L "${ROOTS[@]}" \( -name .git -o -path "$DIGEST_DIR" -o -path "$SNAP_DIR" \) -prune \
              -o -type f -newer "$STAMP" -print 2>/dev/null)

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
mkdir -p "$STATE" 2>/dev/null && printf '%s\n' "$TURNS" > "$STATE/$SID" 2>/dev/null
log 'done' ok "turns=$TURNS commit=$COMMIT${PUSH:+ push=$PUSH}"
record ok "commit=$COMMIT${PUSH:+ push=$PUSH}"
exit 0
