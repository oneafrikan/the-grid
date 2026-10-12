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
#   GIT_START[i]    offset of its first word in GIT_RAW / GIT_MASK
#   GIT_LEN[i]      number of words after the subcommand
#   GIT_RAW[]       words after the subcommand, quotes removed (content kept):
#                   used for config values and pathspecs
#   GIT_MASK[]      the same words with every quoted span replaced by the single
#                   token Q: used for flag checks, so a quoted commit message that
#                   merely MENTIONS --no-verify never matches
#   GIT_VIOLATIONS  reasons found outside any one subcommand: -c core.hooksPath=,
#                   GIT_CONFIG_* / HUSKY=0 assignments
# ---------------------------------------------------------------------------

# _grid_tokenize <command>
#   One left-to-right pass (never two regex passes: they break on
#   "don't --no-verify"). Fills T_RAW[] / T_MASK[] / T_SEP[] in step. T_SEP[i]=1
#   marks a separator (unquoted ; && || | & or newline) instead of a word.
#   Outside quotes: whitespace splits words, ' or " opens a span, a backslash keeps
#   itself and the next character in the word (so \git survives to be normalised
#   and \; or \" never split or open a span). Inside ": backslash escapes the next
#   character and ' is literal. Inside ': everything is literal.
_grid_tokenize() {
  local s="$1" n i=0 c nx pv q=0
  T_RAW=(); T_MASK=(); T_SEP=()
  _TK_RAW=""; _TK_MASK=""; _TK_IN=0
  n=${#s}
  while [ "$i" -lt "$n" ]; do
    c="${s:$i:1}"
    case "$q" in
      1) # inside '...': literal until the next '
        if [ "$c" = "'" ]; then q=0; else _TK_RAW+="$c"; fi ;;
      2) # inside "...": backslash escapes, ' is literal
        if [ "$c" = '"' ]; then
          q=0
        elif [ "$c" = '\' ]; then
          i=$((i + 1)); _TK_RAW+="${s:$i:1}"
        else
          _TK_RAW+="$c"
        fi ;;
      *) # outside quotes
        case "$c" in
          "'") q=1; _TK_IN=1; _TK_MASK+="Q" ;;
          '"') q=2; _TK_IN=1; _TK_MASK+="Q" ;;
          '\')
            nx="${s:$((i + 1)):1}"
            if [ "$nx" = $'\n' ]; then
              _grid_tk_word            # backslash-newline: a line continuation, acts as a space
            else
              _TK_RAW+="$c$nx"; _TK_MASK+="$c$nx"; _TK_IN=1
            fi
            i=$((i + 1)) ;;
          ' '|$'\t') _grid_tk_word ;;
          $'\n'|';') _grid_tk_word; _grid_tk_sep ;;
          '&')
            nx="${s:$((i + 1)):1}"
            pv=""; [ "$i" -gt 0 ] && pv="${s:$((i - 1)):1}"
            if [ "$nx" = '&' ]; then
              _grid_tk_word; _grid_tk_sep; i=$((i + 1))
            elif [ "$pv" = '>' ] || [ "$pv" = '<' ] || [ "$nx" = '>' ]; then
              # redirection such as 2>&1 or &>file: part of the word, not a separator
              _TK_RAW+="$c"; _TK_MASK+="$c"; _TK_IN=1
            else
              _grid_tk_word; _grid_tk_sep
            fi ;;
          '|')
            nx="${s:$((i + 1)):1}"
            _grid_tk_word; _grid_tk_sep
            [ "$nx" = '|' ] && i=$((i + 1)) ;;
          *) _TK_RAW+="$c"; _TK_MASK+="$c"; _TK_IN=1 ;;
        esac ;;
    esac
    i=$((i + 1))
  done
  _grid_tk_word
}

# _grid_tk_word: close the word being built (if any) and push it.
# A word made only of an empty quoted span ("") is a real, empty word.
_grid_tk_word() {
  if [ "$_TK_IN" = 1 ]; then
    T_RAW+=("$_TK_RAW"); T_MASK+=("$_TK_MASK"); T_SEP+=(0)
  fi
  _TK_RAW=""; _TK_MASK=""; _TK_IN=0
}

# _grid_tk_sep: push a segment separator.
_grid_tk_sep() {
  T_RAW+=(""); T_MASK+=(""); T_SEP+=(1)
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
  local -a raw=("${T_RAW[@]}") mask=("${T_MASK[@]}") sep=("${T_SEP[@]}")
  local -a sraw=() smask=()
  n=${#raw[@]}
  for ((i = 0; i <= n; i++)); do
    if [ "$i" -eq "$n" ] || [ "${sep[$i]}" = 1 ]; then
      if [ "${#sraw[@]}" -gt 0 ]; then
        _grid_segment "$depth" "${#sraw[@]}" "${sraw[@]}" "${smask[@]}"
      fi
      sraw=(); smask=()
    else
      sraw+=("${raw[$i]}"); smask+=("${mask[$i]}")
    fi
  done
}

# _grid_segment <depth> <n> <n RAW words> <n MASKED words>
#   Design steps 3 to 5 for one segment: assignment check, one level of wrapper
#   unwrapping, then record the segment if it is a git call.
_grid_segment() {
  local depth="$1" n="$2"
  shift 2
  local -a r=("${@:1:$n}") m=("${@:$((n + 1)):$n}")
  local k first j w v joined opt skip_next
  local re_assign='^(GIT_CONFIG_COUNT|GIT_CONFIG_PARAMETERS|GIT_CONFIG_KEY_[0-9]+)='
  local re_name='^[A-Za-z_][A-Za-z0-9_]*='

  # Step 4: assignment check on every word whose NAME is unquoted (matched on the
  # MASKED form, so `echo "HUSKY=0"` is not a hit while GIT_CONFIG_PARAMETERS="'...'"
  # is: its value is quoted, its name is not). Applies whatever the command is, so
  # `export HUSKY=0` and `env GIT_CONFIG_COUNT=1 ...` are caught too.
  for ((k = 0; k < n; k++)); do
    if [[ "${m[$k]}" =~ $re_assign ]]; then
      GIT_VIOLATIONS+=("sets ${m[$k]%%=*} (a hook-disabling git config override)")
    elif [[ "${m[$k]}" == HUSKY=* && "${r[$k]}" == "HUSKY=0" ]]; then
      GIT_VIOLATIONS+=("sets HUSKY=0 (disables husky git hooks)")
    fi
  done

  # Step 3: drop leading NAME=value words, then normalise the first word:
  # strip one leading backslash, then take the basename (\git, /usr/bin/git -> git).
  k=0
  while [ "$k" -lt "$n" ] && [[ "${r[$k]}" =~ $re_name ]]; do k=$((k + 1)); done
  [ "$k" -lt "$n" ] || return 0
  first="${r[$k]#\\}"; first="${first##*/}"

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
        w="${r[$k]}"
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
      first="${r[$k]#\\}"; first="${first##*/}" ;;
  esac

  # Step 5: only git segments are recorded.
  [ "$first" = git ] || return 0

  # Skip git's global options to find the subcommand: -C <dir> and -c k=v take a
  # value; --git-dir / --work-tree / --namespace take one when given as two words;
  # any other leading dash word is a lone flag (--no-pager, -p, ...).
  j=$((k + 1))
  while [ "$j" -lt "$n" ]; do
    w="${r[$j]}"
    case "$w" in
      -C) j=$((j + 2)) ;;
      -c)
        v="${r[$((j + 1))]:-}"
        if _grid_is_hookspath "$v"; then
          GIT_VIOLATIONS+=("uses -c core.hooksPath=... (overrides the repo's git hooks)")
        fi
        j=$((j + 2)) ;;
      --git-dir|--work-tree|--namespace) j=$((j + 2)) ;;
      -*) j=$((j + 1)) ;;
      *) break ;;
    esac
  done
  [ "$j" -lt "$n" ] || return 0

  GIT_SUB+=("${r[$j]}")
  GIT_START+=("${#GIT_RAW[@]}")
  GIT_LEN+=($((n - j - 1)))
  for ((k = j + 1; k < n; k++)); do
    GIT_RAW+=("${r[$k]}"); GIT_MASK+=("${m[$k]}")
  done
}

# grid_git_segments <command>: see the header above for the result globals.
# SC2034 is disabled because the GIT_* results are read by the scripts that
# source this file, not here.
# shellcheck disable=SC2034
grid_git_segments() {
  GIT_SUB=(); GIT_START=(); GIT_LEN=(); GIT_RAW=(); GIT_MASK=(); GIT_VIOLATIONS=()
  _grid_scan "$1" 0
}
