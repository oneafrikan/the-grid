#!/usr/bin/env bash
# hooks/lib/common.sh — helpers sourced by every hook script (never executed).
#
#   grid_require_jq <closed|open>   jq guard; exits the calling hook when jq is absent
#   grid_log <file> <message>       append one line to a log file, creating its dir 0700
#   grid_git_segments <command>     split a Bash command into git segments (see below)
#
# Bash only (3.2-compatible: no associative arrays, no ${var,,}, no mapfile),
# so the hooks run on a stock macOS shell too. No `set -u`: empty-array
# expansions are unsafe under it on bash 3.2/4.0.
#
# The guards built on grid_git_segments are a mistake-catcher for an agent, NOT a
# security boundary (see hooks/README.md for the known gaps).

# grid_require_jq <fail-mode>
#   jq is needed by every hook script that reads a payload. The fail mode comes
#   from the catalogue entry ("fail"):
#     closed  a guard: exit 2 with an install hint (PreToolUse blocks only on 2,
#             so a missing jq must not turn a guard into a silent no-op)
#     open    a background hook: note on stderr and exit 0
#   Returns 0 when jq is on PATH. Otherwise it EXITS the calling script.
grid_require_jq() {
  command -v jq >/dev/null 2>&1 && return 0
  case "${1:-closed}" in
    open)
      echo "the-grid hook: jq not found, hook skipped (install jq to enable it)" >&2
      exit 0 ;;
    *)
      # Fail closed (D36): the guard cannot tell a git call from any other, so it blocks
      # every Bash call until jq is installed. Name both ways out: only a human can
      # restart claude with the switch, so the message says what to do, not just why.
      echo "the-grid hook: jq not found, so this guard cannot inspect the command and blocks every Bash call until jq is installed. Fix: install jq, or restart claude with GRID_HOOKS=off to disable the-grid hooks." >&2
      exit 2 ;;
  esac
}

# grid_check_cmd_cap <hook-name> <command>
#   Input cap for the guards (WP-019). A timed-out PreToolUse hook does not block, so
#   a command too large to tokenize inside the hook timeout must be refused, not
#   waved through. GRID_GUARD_MAX_CMD (bytes, default 100000) is the limit. Exits 2
#   when over the limit and the command mentions git; the caller's LC_ALL=C makes ${#}
#   count bytes. The default is 100000, not 200000: many-small-words input costs about
#   25 ms per KB to tokenize on a loaded 2020s box, and the whole hook must stay well
#   inside its 5 s timeout.
grid_check_cmd_cap() {
  local max="${GRID_GUARD_MAX_CMD:-100000}"
  [[ "$max" =~ ^[0-9]+$ ]] || max=100000
  [ "${#2}" -gt "$max" ] || return 0
  # Only a command that could matter to a guard (it mentions git, in any case, or
  # HUSKY, which the assignment rule reads) is refused; anything else passes.
  case "$2" in
    *[gG][iI][tT]*|*[hH][uU][sS][kK][yY]*) ;;
    *) return 0 ;;
  esac
  echo "BLOCKED by the-grid hook $1: command too long to inspect (${#2} bytes, limit $max). Write the content to a file with the Write tool and refer to the file in the command." >&2
  exit 2
}

# grid_log <file> <message>
#   Append one line to <file>. The directory is created 0700 (umask in a subshell
#   so the caller's umask is untouched) because logs may name sessions and paths.
grid_log() {
  local file="$1" msg="$2" dir
  dir="$(dirname "$file")"
  ( umask 077; mkdir -p "$dir" ) 2>/dev/null || return 0
  printf '%s\n' "$msg" >> "$file" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# grid_git_segments — the shell-command tokenizer shared by both guards.
#
# Rules are the "Guard rules" section of openspec/changes/hook-profiles/design.md.
# Call it directly (NOT inside $(...), the results are globals):
#
#   grid_git_segments "$command"
#
# Results (all reset on every call):
#   GIT_SUB[i]      subcommand of git segment i (commit, push, config, ...)
#   GIT_START[i]    offset of its first word in GIT_RAW / GIT_MASK / GIT_FLAG
#   GIT_LEN[i]      number of words after the subcommand
#   GIT_RAW[]       words after the subcommand, quotes removed (content kept):
#                   used for config values and pathspecs
#   GIT_MASK[]      the same words with every quoted span replaced by the single
#                   token Q (no longer used by the guards for flag checks)
#   GIT_FLAG[]      the same words as the SHELL would pass them to git: quotes and
#                   unquoted backslashes removed, and a $ right before a quote span
#                   dropped ($'--no-verify'). Used for every flag check, so quoting
#                   or escaping part of a flag cannot hide it. The guards skip the
#                   value word of an option such as -m, so a message that merely
#                   MENTIONS --no-verify never matches.
#   GIT_VIOLATIONS  reasons found outside any one subcommand: -c core.hooksPath=,
#                   GIT_CONFIG_* / HUSKY=0 assignments
# ---------------------------------------------------------------------------

# _grid_tokenize <command>
#   One left-to-right pass (never two regex passes: they break on
#   "don't --no-verify"). Fills T_RAW[] / T_MASK[] / T_FLAG[] / T_SEP[] in step. T_SEP[i]=1
#   marks a separator (unquoted ; && || | & or newline) instead of a word.
#   Outside quotes: whitespace splits words, ' or " opens a span, a backslash keeps
#   itself and the next character in the word (so \git survives to be normalised
#   and \; or \" never split or open a span). Inside ": backslash escapes the next
#   character and ' is literal. Inside ': everything is literal.
_grid_tokenize() {
  local s="$1" n i=0 c nx pv q=0 run buf wl base=0 abs start
  # Linear-time scanning (WP-019). A long command used to take longer than the 5 s hook
  # timeout, and a timed-out hook does not block. Two causes, both fixed here:
  #   1. ${s:$i:k} costs O(i) in bash (it copies the whole string first), so indexing a
  #      long command per character is quadratic. The text is therefore read through a
  #      sliding window `buf` of at most 2048 bytes, so every index is O(2048). A window
  #      starts one character early so the "previous character" test still works, and is
  #      refilled when fewer than 4 characters remain (the longest look-ahead is 1).
  #   2. runs of ordinary characters are consumed with one anchored regex (O(256) slice)
  #      instead of one loop iteration each.
  # Ordinary = not a quote, backslash, blank, newline or one of ; & | (the characters the
  # per-character cases below handle). In a bracket expression a backslash is literal.
  local _TK_ORD=$'^([^\'"\\ \t\n;&|]+)([ \t]?)' _TK_Q1=$'^[^\']+' _TK_Q2=$'^[^"\\]+'
  T_RAW=(); T_MASK=(); T_FLAG=(); T_SEP=()
  _TK_RAW=""; _TK_MASK=""; _TK_FLAG=""; _TK_IN=0; _TK_DLR=0
  n=${#s}
  buf="${s:0:2048}"; wl=${#buf}
  while :; do
    if [ $((i + 4)) -gt "$wl" ] && [ $((base + wl)) -lt "$n" ]; then
      abs=$((base + i)); start=$((abs > 0 ? abs - 1 : 0))
      buf="${s:$start:2048}"; wl=${#buf}; base=$start; i=$((abs - start))
    fi
    [ "$i" -lt "$wl" ] || break
    c="${buf:$i:1}"
    case "$q" in
      1) # inside '...': literal until the next '
        if [ "$c" = "'" ]; then
          q=0
        elif [[ "${buf:$i:256}" =~ $_TK_Q1 ]]; then
          run="${BASH_REMATCH[0]}"; _TK_RAW+="$run"; _TK_FLAG+="$run"; i=$((i + ${#run})); continue
        else
          _TK_RAW+="$c"; _TK_FLAG+="$c"
        fi ;;
      2) # inside "...": backslash escapes, ' is literal
        if [ "$c" = '"' ]; then
          q=0
        elif [ "$c" = '\' ]; then
          i=$((i + 1)); _TK_RAW+="${buf:$i:1}"; _TK_FLAG+="${buf:$i:1}"
        elif [[ "${buf:$i:256}" =~ $_TK_Q2 ]]; then
          run="${BASH_REMATCH[0]}"; _TK_RAW+="$run"; _TK_FLAG+="$run"; i=$((i + ${#run})); continue
        else
          _TK_RAW+="$c"; _TK_FLAG+="$c"
        fi ;;
      *) # outside quotes
        if [[ "${buf:$i:256}" =~ $_TK_ORD ]]; then
          run="${BASH_REMATCH[1]}"
          _TK_RAW+="$run"; _TK_MASK+="$run"; _TK_FLAG+="$run"; _TK_IN=1
          _TK_DLR=0; [[ "$run" == *'$' ]] && _TK_DLR=1   # a $ right before a quote: $'..' / $".."
          # A run followed by a blank ends the word: take the blank in the same step
          # (half the iterations for ordinary "word word word" text).
          [ -n "${BASH_REMATCH[2]}" ] && _grid_tk_word
          i=$((i + ${#BASH_REMATCH[0]}))
          continue
        fi
        case "$c" in
          "'") q=1; _TK_IN=1; _TK_MASK+="Q"; [ "$_TK_DLR" = 1 ] && _TK_FLAG="${_TK_FLAG%?}" ;;
          '"') q=2; _TK_IN=1; _TK_MASK+="Q"; [ "$_TK_DLR" = 1 ] && _TK_FLAG="${_TK_FLAG%?}" ;;
          '\')
            nx="${buf:$((i + 1)):1}"
            if [ "$nx" = $'\n' ]; then
              _grid_tk_word            # backslash-newline: a line continuation, acts as a space
            else
              # FLAG drops the backslash: the shell passes the next character through
              _TK_RAW+="$c$nx"; _TK_MASK+="$c$nx"; _TK_FLAG+="$nx"; _TK_IN=1
            fi
            i=$((i + 1)) ;;
          ' '|$'\t') _grid_tk_word ;;
          $'\n'|';') _grid_tk_word; _grid_tk_sep ;;
          '&')
            nx="${buf:$((i + 1)):1}"
            pv=""; [ "$i" -gt 0 ] && pv="${buf:$((i - 1)):1}"
            if [ "$nx" = '&' ]; then
              _grid_tk_word; _grid_tk_sep; i=$((i + 1))
            elif [ "$pv" = '>' ] || [ "$pv" = '<' ] || [ "$nx" = '>' ]; then
              # redirection such as 2>&1 or &>file: part of the word, not a separator
              _TK_RAW+="$c"; _TK_MASK+="$c"; _TK_FLAG+="$c"; _TK_IN=1
            else
              _grid_tk_word; _grid_tk_sep
            fi ;;
          '|')
            nx="${buf:$((i + 1)):1}"
            _grid_tk_word; _grid_tk_sep
            [ "$nx" = '|' ] && i=$((i + 1)) ;;
          *) _TK_RAW+="$c"; _TK_MASK+="$c"; _TK_FLAG+="$c"; _TK_IN=1 ;;
        esac ;;
    esac
    # a $ is only "right before a quote" for the very next character
    case "$c" in '$') ;; *) _TK_DLR=0 ;; esac
    i=$((i + 1))
  done
  _grid_tk_word
}

# _grid_tk_word: close the word being built (if any) and push it.
# A word made only of an empty quoted span ("") is a real, empty word.
_grid_tk_word() {
  if [ "$_TK_IN" = 1 ]; then
    T_RAW+=("$_TK_RAW"); T_MASK+=("$_TK_MASK"); T_FLAG+=("$_TK_FLAG"); T_SEP+=(0)
  fi
  _TK_RAW=""; _TK_MASK=""; _TK_FLAG=""; _TK_IN=0; _TK_DLR=0
}

# _grid_tk_sep: push a segment separator.
_grid_tk_sep() {
  T_RAW+=(""); T_MASK+=(""); T_FLAG+=(""); T_SEP+=(1)
}

# _grid_is_hookspath <text>
#   True when <text> starts with core.hooksPath, matched case-insensitively
#   (git config keys are case-insensitive) without forking tr or needing bash 4.
_grid_is_hookspath() {
  case "$1" in
    [cC][oO][rR][eE].[hH][oO][oO][kK][sS][pP][aA][tT][hH]|[cC][oO][rR][eE].[hH][oO][oO][kK][sS][pP][aA][tT][hH]=*) return 0 ;;
  esac
  return 1
}

# _grid_scan <command> <depth>
#   Tokenize, split into segments on the separators, and hand each segment to
#   _grid_segment. depth is 0 for the real command and 1 for text re-run out of a
#   bash -c / eval wrapper (which is not unwrapped a second time).
_grid_scan() {
  local cmd="$1" depth="$2" i n
  _grid_tokenize "$cmd"
  # Copy the token arrays: the recursion re-tokenizes and overwrites the T_ globals.
  local -a raw=("${T_RAW[@]}") mask=("${T_MASK[@]}") flag=("${T_FLAG[@]}") sep=("${T_SEP[@]}")
  local -a sraw=() smask=() sflag=()
  n=${#raw[@]}
  for ((i = 0; i <= n; i++)); do
    if [ "$i" -eq "$n" ] || [ "${sep[$i]}" = 1 ]; then
      if [ "${#sraw[@]}" -gt 0 ]; then
        _grid_segment "$depth" "${#sraw[@]}" "${sraw[@]}" "${smask[@]}" "${sflag[@]}"
      fi
      sraw=(); smask=(); sflag=()
    else
      sraw+=("${raw[$i]}"); smask+=("${mask[$i]}"); sflag+=("${flag[$i]}")
    fi
  done
}

# _grid_segment <depth> <n> <n RAW words> <n MASKED words> <n FLAG words>
#   Design steps 3 to 5 for one segment: assignment check, one level of wrapper
#   unwrapping, then record the segment if it is a git call.
_grid_segment() {
  local depth="$1" n="$2"
  shift 2
  local -a r=("${@:1:$n}") m=("${@:$((n + 1)):$n}") f=("${@:$((2 * n + 1)):$n}")
  local k first j w v joined opt skip_next
  local re_assign='^(GIT_CONFIG_COUNT|GIT_CONFIG_PARAMETERS|GIT_CONFIG_KEY_[0-9]+)='
  local re_name='^[A-Za-z_][A-Za-z0-9_]*='

  # Step 4: assignment check on every word whose NAME is unquoted (matched on the
  # MASKED form, so `echo "HUSKY=0"` is not a hit while GIT_CONFIG_PARAMETERS="'...'"
  # is: its value is quoted, its name is not). Applies whatever the command is, so
  # `export HUSKY=0` and `env GIT_CONFIG_COUNT=1 ...` are caught too.
  for ((k = 0; k < n; k++)); do
    # Cheap glob pre-test first: a regex per word made a 50 KB command slow (WP-019).
    case "${m[$k]}" in GIT_CONFIG_*|HUSKY=*) ;; *) continue ;; esac
    if [[ "${m[$k]}" =~ $re_assign ]]; then
      GIT_VIOLATIONS+=("sets ${m[$k]%%=*} (a hook-disabling git config override)")
    elif [[ "${m[$k]}" == HUSKY=* && "${r[$k]}" == "HUSKY=0" ]]; then
      GIT_VIOLATIONS+=("sets HUSKY=0 (disables husky git hooks)")
    fi
  done

  # Step 3: drop leading NAME=value words, then normalise the first word. The FLAG
  # form already has quotes and backslashes removed the way the shell does (so g""it,
  # g\it and \git all read git); then take the basename (/usr/bin/git -> git).
  k=0
  while [ "$k" -lt "$n" ] && [[ "${r[$k]}" =~ $re_name ]]; do k=$((k + 1)); done
  [ "$k" -lt "$n" ] || return 0
  first="${f[$k]}"; first="${first##*/}"

  case "$first" in
    bash|sh|zsh)
      # `-c <arg>`, also -lc / -ec / any short cluster ending in c: re-run <arg> once.
      [ "$depth" -eq 0 ] || return 0
      for ((j = k + 1; j < n - 1; j++)); do
        if [[ "${r[$j]}" =~ ^-[a-zA-Z]*c$ ]]; then
          _grid_scan "${r[$((j + 1))]}" 1
          return 0
        fi
      done
      return 0 ;;
    eval)
      # The remaining RAW words joined by spaces are re-run once.
      [ "$depth" -eq 0 ] || return 0
      joined=""
      for ((j = k + 1; j < n; j++)); do joined+="${r[$j]} "; done
      _grid_scan "$joined" 1
      return 0 ;;
    exec|env|command|xargs|nice|time|sudo)
      [ "$depth" -eq 0 ] || return 0
      opt="$first"
      k=$((k + 1))
      # Drop the wrapper's own options and NAME=value words. A value-taking option
      # also consumes the next word (sudo -u root, nice -n 5, xargs -n 1 ...).
      while [ "$k" -lt "$n" ]; do
        w="${f[$k]}"
        if [[ "$w" == -* ]]; then
          skip_next=0
          case "$opt:$w" in
            sudo:-u|sudo:-g|sudo:-h|sudo:-C|nice:-n|xargs:-n|xargs:-I|xargs:-L|xargs:-P|xargs:-d|xargs:-s|xargs:-E) skip_next=1 ;;
          esac
          k=$((k + 1 + skip_next))
        elif [[ "$w" =~ $re_name ]]; then
          k=$((k + 1))
        else
          break
        fi
      done
      [ "$k" -lt "$n" ] || return 0
      first="${f[$k]}"; first="${first##*/}" ;;
  esac

  # Step 5: only git segments are recorded.
  [ "$first" = git ] || return 0

  # Skip git's global options to find the subcommand: -C <dir> and -c k=v take a
  # value; --git-dir / --work-tree / --namespace take one when given as two words;
  # any other leading dash word is a lone flag (--no-pager, -p, ...). Read through the
  # FLAG form so a quoted or escaped option cannot hide the subcommand.
  # --config-env=<key>=<ENVVAR> is -c with the value taken from the environment, so a
  # hooksPath key is the same override.
  j=$((k + 1))
  while [ "$j" -lt "$n" ]; do
    w="${f[$j]}"
    case "$w" in
      -C) j=$((j + 2)) ;;
      -c|--config-env)
        v="${f[$((j + 1))]:-}"
        if _grid_is_hookspath "$v"; then
          GIT_VIOLATIONS+=("uses $w core.hooksPath=... (overrides the repo's git hooks)")
        fi
        j=$((j + 2)) ;;
      --config-env=*)
        if _grid_is_hookspath "${w#--config-env=}"; then
          GIT_VIOLATIONS+=("uses --config-env=core.hooksPath=... (overrides the repo's git hooks)")
        fi
        j=$((j + 1)) ;;
      --git-dir|--work-tree|--namespace) j=$((j + 2)) ;;
      -*) j=$((j + 1)) ;;
      *) break ;;
    esac
  done
  [ "$j" -lt "$n" ] || return 0

  GIT_SUB+=("${f[$j]}")
  GIT_START+=("${#GIT_RAW[@]}")
  GIT_LEN+=($((n - j - 1)))
  for ((k = j + 1; k < n; k++)); do
    GIT_RAW+=("${r[$k]}"); GIT_MASK+=("${m[$k]}"); GIT_FLAG+=("${f[$k]}")
  done
}

# grid_git_segments <command>: see the header above for the result globals.
# SC2034 is disabled because the GIT_* results are read by the scripts that
# source this file, not here.
# shellcheck disable=SC2034
grid_git_segments() {
  GIT_SUB=(); GIT_START=(); GIT_LEN=(); GIT_RAW=(); GIT_MASK=(); GIT_FLAG=(); GIT_VIOLATIONS=()
  _grid_scan "$1" 0
}
