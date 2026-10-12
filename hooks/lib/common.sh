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
#   waved through. Two limits, because cost follows token count as much as size:
#     GRID_GUARD_MAX_CMD     bytes, default 20000
#     GRID_GUARD_MAX_TOKENS  blanks and separators (; & | ( ) `), default 2500
#   Measured on a busy box, a token costs about 0.5 ms to tokenize and each separator
#   about 1 ms more, so the defaults keep the cost of an ordinary command near 2 s of CPU
#   (heredoc count and substitution depth are capped separately in the tokenizer). This is
#   a bound chosen from measurements, not a proof. Both are counted on the text with quotes
#   and backslashes removed (the way the shell reads it), so quoting `git` cannot dodge the
#   check. Exits 2 when over a limit
#   and the command mentions git (any case) or HUSKY; anything else passes. The caller's
#   LC_ALL=C makes ${#} count bytes.
grid_check_cmd_cap() {
  local max="${GRID_GUARD_MAX_CMD:-20000}" maxt="${GRID_GUARD_MAX_TOKENS:-2500}" st t
  [[ "$max" =~ ^[0-9]+$ ]] || max=20000
  [[ "$maxt" =~ ^[0-9]+$ ]] || maxt=2500
  st="${2//$'\\\n'/}"; st="${st//[\"\'\\]/}"
  case "$st" in
    *[gG][iI][tT]*|*[hH][uU][sS][kK][yY]*) ;;
    *) return 0 ;;
  esac
  t="${st//[^[:space:];&|()\`]/}"
  if [ "${#st}" -le "$max" ] && [ "${#t}" -le "$maxt" ]; then return 0; fi
  echo "BLOCKED by the-grid hook $1: command too long to inspect (${#st} bytes, ${#t} tokens; limits $max and $maxt). Write the content to a file with the Write tool and refer to the file in the command." >&2
  exit 2
}

# grid_check_balanced <hook-name> <command>
#   Call right after grid_git_segments. Two conditions mean the tokenizer may have lost
#   track of where later words start, so a git call after them could be invisible:
#   a quote or substitution still open at the end (GIT_UNBALANCED), and input the
#   tokenizer refuses to model (GIT_FAIL: a heredoc delimiter with a backslash or stray
#   quote, more than 8 heredocs, substitutions nested deeper than 16). Both fail closed
#   (exit 2), but only for a command that mentions git (any case, quotes removed): a
#   command that never names git passes, as it does at the fast path.
grid_check_balanced() {
  [ "${GIT_UNBALANCED:-0}" = 1 ] || [ -n "${GIT_FAIL:-}" ] || return 0
  local st="${2//$'\\\n'/}"
  st="${st//[\"\'\\]/}"
  case "$st" in
    *[gG][iI][tT]*|*[hH][uU][sS][kK][yY]*) ;;
    *) return 0 ;;
  esac
  if [ -n "${GIT_FAIL:-}" ]; then
    echo "BLOCKED by the-grid hook $1: command too complex to inspect ($GIT_FAIL). Simplify the command, or write the content to a file with the Write tool." >&2
  else
    echo "BLOCKED by the-grid hook $1: a quote or substitution in this command is not closed, so the command cannot be inspected. Simplify the command: close the quote, or write the content to a file with the Write tool." >&2
  fi
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
#   GIT_CD[i]       directories entered by cd/pushd earlier in the command, in order,
#                   each preceded by the unit separator ($'\037'); a directory that
#                   cannot be known statically ($VAR, cd -) is the single word ?
#   GIT_C[i]        the same for git's own -C <dir> options (relative to the cd chain)
#   GIT_GITDIR[i]   the last --git-dir value ("" when none)
#   GIT_WORKTREE[i] the last --work-tree value ("" when none)
#   GIT_VIOLATIONS  reasons found outside any one subcommand: -c core.hooksPath=,
#                   GIT_CONFIG_* / HUSKY=0 assignments
# ---------------------------------------------------------------------------

# _grid_tokenize <command>
#   One left-to-right pass (never two regex passes: they break on
#   "don't --no-verify"). Fills T_RAW[] / T_MASK[] / T_FLAG[] / T_SEP[] in step. T_SEP[i]=1
#   marks a separator (unquoted ; && || | & ( ) ` or newline) instead of a word. An
#   unquoted word-initial # starts a comment that runs to the end of the line.
#   Outside quotes: whitespace splits words, ' or " opens a span, a backslash keeps
#   itself and the next character in the word (so \git survives to be normalised
#   and \; or \" never split or open a span); backslash-newline is deleted. Inside ":
#   backslash escapes the next character and ' is literal. Inside ': everything is
#   literal. Inside $'..' a backslash escapes the next character (so \' does not end it).
#
#   Quote state must never drift, because a drifted state hides every LATER git call:
#     - a heredoc body is not code for quote tracking: its lines are tokenized one at a
#       time with the quote state reset at each newline (so `it's` in a body cannot open
#       a span that swallows the next command). Whether the lines are READ as code is
#       decided when the body starts (the end of the line holding <<): data only when
#       nothing on that line is a shell or an interpreter, the delimiter is a plain word
#       and a known data sink (cat, tee, read, git commit -F, gh --body-file) is on the
#       line; anything else is code (the default). << is not a heredoc inside (( )),
#       after a digit, ) or ] (arithmetic shift), or as <<< or <<-<space|digit>. A
#       delimiter with a backslash or stray quote, more than 8 heredocs, or substitutions
#       nested deeper than 16 set GIT_FAIL and the guards fail closed;
#     - $(..) and `..` inside double quotes are code with their own quotes, tracked on a
#       stack, so `"$(echo '"')"` closes correctly and `"$(git commit -n)"` is seen;
#     - when a quote or substitution is still open at the end, GIT_UNBALANCED is set and
#       the guards fail closed.
_grid_tokenize() {
  local s="$1" n i=0 c nx pv q=0 run buf wl base=0 abs start j dl
  # Windowed scanning (WP-019): each step costs a bounded amount. A long command used to take longer than the 5 s hook
  # timeout, and a timed-out hook does not block. Two causes, both fixed here:
  #   1. ${s:$i:k} costs O(i) in bash (it copies the whole string first), so indexing a
  #      long command per character is quadratic. The text is therefore read through a
  #      sliding window `buf` of at most 2048 bytes, so every index is O(2048). A window
  #      starts one character early so the "previous character" test still works, and is
  #      refilled when fewer than 300 characters remain (the longest look-ahead is a
  #      heredoc delimiter, at most 200 characters).
  #   2. runs of ordinary characters are consumed with one anchored regex (O(256) slice)
  #      instead of one loop iteration each.
  # Ordinary = not a quote, backslash, blank, newline or one of ; & | ( ) ` < (the
  # characters the per-character cases below handle). In a bracket expression a
  # backslash is literal.
  local _TK_ORD=$'^([^\'"\\ \t\n;&|()`<]+)([ \t]?)' _TK_Q1=$'^[^\'\n]+' _TK_Q2=$'^[^"\\$`\n]+'
  local _TK_Q5=$'^[^\'\\\n]+' _TK_CM=$'^[^\n]+' _TK_HD=$'^[ \t]*([^ \t\n;&|()<>]+)'
  local _TK_HDP=$'^[A-Za-z0-9_]+$' _TK_HDQ=$'^([\'"])([A-Za-z0-9_]+)([\'"])$'
  local -a _hdp=() _hdd=() _hdq=() _hdl=() _hdm=()
  local _hd="" _hdt="" _hdb=0 _hdmode=0 _hdskip=0 _hdn=0 _AR=0 ln rest word k2
  T_RAW=(); T_MASK=(); T_FLAG=(); T_SEP=()
  D_RAW=(); D_MASK=(); D_FLAG=(); D_SEP=()
  _CS_Q=(); _CS_K=(); _CS_D=(); _CS_WR=(); _CS_WM=(); _CS_WF=(); _CS_WI=(); _CS_N=0
  _LN_SH=0; _LN_SINK=0; _LN_GIT=0; _LN_FILE=0; _LN_GH=0
  _TK_RAW=""; _TK_MASK=""; _TK_FLAG=""; _TK_IN=0; _TK_DLR=0; _TK_DEFER=0
  n=${#s}
  buf="${s:0:2048}"; wl=${#buf}
  while :; do
    if [ $((i + 1600)) -gt "$wl" ] && [ $((base + wl)) -lt "$n" ]; then
      abs=$((base + i)); start=$((abs > 0 ? abs - 1 : 0))
      buf="${s:$start:2048}"; wl=${#buf}; base=$start; i=$((abs - start))
    fi
    [ "$i" -lt "$wl" ] || break
    c="${buf:$i:1}"

    # Inside a heredoc body: at the start of a line, the delimiter line ends the body
    # (leading tabs are ignored for <<-); at a newline the quote state is reset.
    # What a body line is depends on who reads it (_hdmode, fixed when << was seen):
    #   0  the heredoc feeds a shell (bash <<EOF): every line is code;
    #   1  quoted delimiter (<<'EOF'): the body is data, every line is skipped;
    #   2  unquoted delimiter: the shell expands $( ) and backticks in the body, so a line
    #      holding one is read as code and every other line is skipped.
    # A data line is skipped without being tokenized, so prose such as a commit message
    # that mentions "git push --force" is not mistaken for a command.
    if [ -n "$_hd" ]; then
      if [ "$_hdb" = 1 ]; then
        _hdb=0; _hdskip=0
        j=$i
        if [ "$_hdt" = '-' ]; then while [ "${buf:$j:1}" = $'\t' ]; do j=$((j + 1)); done; fi
        dl=${#_hd}
        if [ "${buf:$j:$dl}" = "$_hd" ]; then
          nx="${buf:$((j + dl)):1}"
          if [ -z "$nx" ] || [ "$nx" = $'\n' ]; then _hd=""; i=$((j + dl)); continue; fi
        fi
        if [ "$_hdmode" = 1 ]; then
          _hdskip=1
        elif [ "$_hdmode" = 2 ]; then
          # the line as far as the window shows it (a longer line counts as code)
          ln="${buf:$i:1500}"; ln="${ln%%$'\n'*}"
          case "$ln" in *'$('*|*'`'*) ;; *) [ "${#ln}" -lt 1500 ] && _hdskip=1 ;; esac
        fi
      fi
      if [ "$_hdskip" = 1 ]; then
        if [ "$c" = $'\n' ]; then _hdb=1; i=$((i + 1)); continue
        elif [[ "${buf:$i:256}" =~ $_TK_CM ]]; then i=$((i + ${#BASH_REMATCH[0]})); continue; fi
      fi
      if [ "$c" = $'\n' ]; then
        q=0; _grid_tk_word; _grid_tk_sep; _hdb=1; i=$((i + 1)); continue
      fi
    fi

    case "$q" in
      3) # inside a # comment: skipped up to (not including) the newline
        if [ "$c" = $'\n' ]; then
          q=0; continue
        elif [[ "${buf:$i:256}" =~ $_TK_CM ]]; then
          i=$((i + ${#BASH_REMATCH[0]})); continue
        fi ;;
      1) # inside '...': literal until the next '
        if [ "$c" = "'" ]; then
          q=0
        elif [[ "${buf:$i:256}" =~ $_TK_Q1 ]]; then
          run="${BASH_REMATCH[0]}"; _TK_RAW+="$run"; _TK_FLAG+="$run"; i=$((i + ${#run})); continue
        else
          _TK_RAW+="$c"; _TK_FLAG+="$c"
        fi ;;
      5) # inside $'...': like '...' but a backslash escapes the next character
        if [ "$c" = "'" ]; then
          q=0
        elif [ "$c" = '\' ]; then
          i=$((i + 1)); _TK_RAW+="${buf:$i:1}"; _TK_FLAG+="${buf:$i:1}"
        elif [[ "${buf:$i:256}" =~ $_TK_Q5 ]]; then
          run="${BASH_REMATCH[0]}"; _TK_RAW+="$run"; _TK_FLAG+="$run"; i=$((i + ${#run})); continue
        else
          _TK_RAW+="$c"; _TK_FLAG+="$c"
        fi ;;
      2) # inside "...": backslash escapes, ' is literal, $( and ` start code
        if [ "$c" = '"' ]; then
          q=0
        elif [ "$c" = '\' ]; then
          i=$((i + 1))
          # backslash-newline inside double quotes is a line continuation too: deleted
          if [ "${buf:$i:1}" != $'\n' ]; then _TK_RAW+="${buf:$i:1}"; _TK_FLAG+="${buf:$i:1}"; fi
        elif [ "$c" = '$' ] && [ "${buf:$((i + 1)):1}" = '(' ]; then
          _grid_tk_cs_push 2 p || break
          _grid_tk_word; _grid_tk_sep; q=0; i=$((i + 2)); continue
        elif [ "$c" = '`' ]; then
          _grid_tk_cs_push 2 b || break
          _grid_tk_word; _grid_tk_sep; q=0; i=$((i + 1)); continue
        elif [[ "${buf:$i:256}" =~ $_TK_Q2 ]]; then
          run="${BASH_REMATCH[0]}"; _TK_RAW+="$run"; _TK_FLAG+="$run"; i=$((i + ${#run})); continue
        else
          _TK_RAW+="$c"; _TK_FLAG+="$c"
        fi ;;
      *) # outside quotes
        # A # that starts a word is a comment (a # inside a word, like a#b or $#, is not).
        if [ "$c" = '#' ] && [ "$_TK_IN" = 0 ]; then q=3; i=$((i + 1)); continue; fi
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
          "'")
            _TK_IN=1; _TK_MASK+="Q"
            if [ "$_TK_DLR" = 1 ]; then q=5; _TK_FLAG="${_TK_FLAG%?}"; else q=1; fi ;;
          '"') q=2; _TK_IN=1; _TK_MASK+="Q"; [ "$_TK_DLR" = 1 ] && _TK_FLAG="${_TK_FLAG%?}" ;;
          '\')
            nx="${buf:$((i + 1)):1}"
            if [ "$nx" = $'\n' ]; then
              :                        # backslash-newline: a line continuation, deleted (it joins the word)
            else
              # FLAG drops the backslash: the shell passes the next character through
              _TK_RAW+="$c$nx"; _TK_MASK+="$c$nx"; _TK_FLAG+="$nx"; _TK_IN=1
            fi
            i=$((i + 1)) ;;
          ' '|$'\t') _grid_tk_word ;;
          $'\n')
            _grid_tk_word; _grid_tk_sep
            # The first newline after a << marker starts the heredoc body, and now the whole
            # line is known, so the body's mode is decided here (default: code):
            #   data (1 quoted delimiter, 2 unquoted) only when nothing on the line is a
            #   shell or interpreter, the delimiter is a plain word, and a data sink is there.
            if [ "${#_hdp[@]}" -gt 0 ]; then
              while [ "${#_hdm[@]}" -lt "${#_hdp[@]}" ]; do
                k2=${#_hdm[@]}
                if [ "$_LN_SH" = 0 ] && [ "${_hdl[$k2]}" = 1 ] \
                   && { [ "$_LN_SINK" = 1 ] || { [ "$_LN_GIT" = 1 ] && [ "$_LN_FILE" = 1 ]; } \
                        || { [ "$_LN_GH" = 1 ] && [ "$_LN_FILE" = 1 ]; }; }; then
                  if [ "${_hdq[$k2]}" = 1 ]; then _hdm+=(1); else _hdm+=(2); fi
                else
                  _hdm+=(0)
                fi
              done
              _hd="${_hdp[0]}"; _hdt="${_hdd[0]}"; _hdmode="${_hdm[0]}"
              _hdp=("${_hdp[@]:1}"); _hdd=("${_hdd[@]:1}"); _hdq=("${_hdq[@]:1}"); _hdl=("${_hdl[@]:1}"); _hdm=("${_hdm[@]:1}"); _hdb=1
            fi
            _LN_SH=0; _LN_SINK=0; _LN_GIT=0; _LN_FILE=0; _LN_GH=0 ;;
          ';') _grid_tk_word; _grid_tk_sep ;;
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
          # Subshells, command substitution and function bodies: ( and ) end a segment.
          # Inside a $( opened within double quotes the matching ) returns to the quotes.
          '(')
            _grid_tk_word; _grid_tk_sep
            if [ "${buf:$((i + 1)):1}" = '(' ]; then
              _AR=$((_AR + 1)); i=$((i + 1))             # (( opens arithmetic: << inside is a shift
            elif [ "$_CS_N" -gt 0 ] && [ "${_CS_K[$((_CS_N - 1))]}" = p ]; then
              _CS_D[$((_CS_N - 1))]=$((_CS_D[$((_CS_N - 1))] + 1))
            fi ;;
          ')')
            _grid_tk_word; _grid_tk_sep
            if [ "$_AR" -gt 0 ] && [ "${buf:$((i + 1)):1}" = ')' ]; then
              _AR=$((_AR - 1)); i=$((i + 1))
            elif [ "$_CS_N" -gt 0 ] && [ "${_CS_K[$((_CS_N - 1))]}" = p ]; then
              if [ "${_CS_D[$((_CS_N - 1))]}" -gt 0 ]; then
                _CS_D[$((_CS_N - 1))]=$((_CS_D[$((_CS_N - 1))] - 1))
              else
                _grid_tk_cs_pop; q="$_CS_RESTORE_Q"
              fi
            fi ;;
          # An unquoted backtick opens or closes a command substitution: like ( and ).
          '`')
            _grid_tk_word; _grid_tk_sep
            if [ "$_CS_N" -gt 0 ] && [ "${_CS_K[$((_CS_N - 1))]}" = b ]; then
              _grid_tk_cs_pop; q="$_CS_RESTORE_Q"
            fi ;;
          # A << marker names a heredoc delimiter; the body starts after the next newline.
          # Conservative: it is NOT a heredoc (so the text stays code) inside (( )), right
          # after a digit, ) or ] (an arithmetic shift), as <<< (here-string), or as <<-
          # followed by a blank or a digit. The < itself is an ordinary word character.
          '<')
            pv=""; [ "$i" -gt 0 ] && pv="${buf:$((i - 1)):1}"
            if [ "${buf:$((i + 1)):1}" = '<' ] && [ "${buf:$((i + 2)):1}" != '<' ] && [ "$pv" != '<' ] \
               && [ "$_AR" = 0 ]; then
              case "$pv" in [0-9]|')'|']') ;; *)
                rest="${buf:$((i + 2)):300}"
                nx=0; [ "${rest:0:1}" = '-' ] && nx=1
                case "${rest:$nx:1}" in
                  ' '|$'\t'|[0-9]) [ "$nx" = 1 ] && rest="" ;;
                esac
                if [[ "$rest" =~ $_TK_HD ]]; then
                  word="${BASH_REMATCH[1]}"
                  # a leading - was the <<- marker: take it off the word
                  [ "$nx" = 1 ] && [ "${rest:0:1}" = '-' ] && word="${word#-}"
                  _hdn=$((_hdn + 1))
                  if [ "$_hdn" -gt 8 ]; then GIT_FAIL="too many heredocs"; break; fi
                  if [[ "$word" =~ $_TK_HDP ]]; then
                    _hdp+=("$word"); _hdq+=(0); _hdl+=(1)
                  elif [[ "$word" =~ $_TK_HDQ ]] && [ "${BASH_REMATCH[1]}" = "${BASH_REMATCH[3]}" ]; then
                    _hdp+=("${BASH_REMATCH[2]}"); _hdq+=(1); _hdl+=(1)
                  elif [[ "$word" == *[\\\'\"]* ]]; then
                    # a delimiter the guard cannot match exactly (a backslash, a stray quote)
                    GIT_FAIL="unsupported heredoc delimiter"
                    _hdp+=("$word"); _hdq+=(0); _hdl+=(0)
                  else
                    _hdp+=("$word"); _hdq+=(0); _hdl+=(0)
                  fi
                  if [ "$nx" = 1 ]; then _hdd+=('-'); else _hdd+=(''); fi
                fi ;;
              esac
            fi
            _TK_RAW+="$c"; _TK_MASK+="$c"; _TK_FLAG+="$c"; _TK_IN=1 ;;
          *) _TK_RAW+="$c"; _TK_MASK+="$c"; _TK_FLAG+="$c"; _TK_IN=1 ;;
        esac ;;
    esac
    # a $ is only "right before a quote" for the very next character
    case "$c" in '$') ;; *) _TK_DLR=0 ;; esac
    i=$((i + 1))
  done
  _grid_tk_word
  # An open quote or substitution at the end hides everything after it: tell the guards.
  case "$q" in 1|2|5) GIT_UNBALANCED=1 ;; esac
  [ "$_CS_N" -eq 0 ] || GIT_UNBALANCED=1
  # The commands found inside "$( )" and "` `" come after the outer command, each in its
  # own segments, so the outer command keeps all of its own words.
  _TK_DEFER=0
  if [ "${#D_RAW[@]}" -gt 0 ]; then
    T_RAW+=("" "${D_RAW[@]}"); T_MASK+=("" "${D_MASK[@]}"); T_FLAG+=("" "${D_FLAG[@]}"); T_SEP+=(1 "${D_SEP[@]}")
  fi
}

# _grid_base <word>: sets _GB to the part after the last /, or to "" for a word of 4 KB
# or more. No command name is that long, and ${w##*/} on a long word is quadratic.
_grid_base() {
  if [ "${#1}" -lt 4096 ]; then _GB="${1##*/}"; else _GB=""; fi
}

# _grid_tk_cs_push <q to return to> <kind p|b>
#   A command substitution starts inside double quotes. The word being built (the quoted
#   string) is saved, the substitution's own words are collected apart (_TK_DEFER), and the
#   stack remembers what to return to when it ends. The stack is a set of arrays plus a
#   length (_CS_N): a push or pop touches one slot and copies nothing. Returns 1 (and sets
#   GIT_FAIL) at depth 16: deeper nesting is refused, not tracked.
_grid_tk_cs_push() {
  if [ "$_CS_N" -ge 16 ]; then GIT_FAIL="substitutions nested too deeply"; return 1; fi
  _CS_Q[$_CS_N]="$1"; _CS_K[$_CS_N]="$2"; _CS_D[$_CS_N]=0
  _CS_WR[$_CS_N]="$_TK_RAW"; _CS_WM[$_CS_N]="$_TK_MASK"; _CS_WF[$_CS_N]="$_TK_FLAG"; _CS_WI[$_CS_N]="$_TK_IN"
  _CS_N=$((_CS_N + 1))
  _TK_RAW=""; _TK_MASK=""; _TK_FLAG=""; _TK_IN=0; _TK_DEFER=1
  D_RAW+=(""); D_MASK+=(""); D_FLAG+=(""); D_SEP+=(1)
}

# _grid_tk_cs_pop: the substitution ended; sets _CS_RESTORE_Q and restores the saved word.
_grid_tk_cs_pop() {
  local t=$((_CS_N - 1))
  _CS_RESTORE_Q="${_CS_Q[$t]}"
  _TK_RAW="${_CS_WR[$t]}"; _TK_MASK="${_CS_WM[$t]}"; _TK_FLAG="${_CS_WF[$t]}"; _TK_IN="${_CS_WI[$t]}"
  _CS_N=$t
  [ "$_CS_N" -gt 0 ] || _TK_DEFER=0
}

# _grid_tk_word: close the word being built (if any) and push it.
# A word made only of an empty quoted span ("") is a real, empty word.
_grid_tk_word() {
  if [ "$_TK_IN" = 1 ]; then
    # Running flags for the current line (reset at each newline), read when a heredoc body
    # starts: a shell or interpreter on the line, a data sink, git/gh with a file option.
    # Command names are short, so a long word is skipped.
    if [ "${#_TK_FLAG}" -lt 64 ]; then
      case "${_TK_FLAG##*/}" in
        sh|bash|zsh|dash|ksh|ash|busybox|eval|source|.|xargs|env|sudo|ssh|exec|-c|python|python[0-9]*|perl|ruby|node|php|lua) _LN_SH=1 ;;
        cat|tee|read) _LN_SINK=1 ;;
        git) _LN_GIT=1 ;;
        gh) _LN_GH=1 ;;
        -F|--file|--body-file|--notes-file) _LN_FILE=1 ;;
      esac
    fi
    if [ "$_TK_DEFER" = 1 ]; then
      D_RAW+=("$_TK_RAW"); D_MASK+=("$_TK_MASK"); D_FLAG+=("$_TK_FLAG"); D_SEP+=(0)
    else
      T_RAW+=("$_TK_RAW"); T_MASK+=("$_TK_MASK"); T_FLAG+=("$_TK_FLAG"); T_SEP+=(0)
    fi
  fi
  _TK_RAW=""; _TK_MASK=""; _TK_FLAG=""; _TK_IN=0; _TK_DLR=0
}

# _grid_tk_sep: push a segment separator.
_grid_tk_sep() {
  if [ "$_TK_DEFER" = 1 ]; then
    D_RAW+=(""); D_MASK+=(""); D_FLAG+=(""); D_SEP+=(1)
  else
    T_RAW+=(""); T_MASK+=(""); T_FLAG+=(""); T_SEP+=(1)
  fi
}

# _grid_is_hookspath <text>
#   True when <text> names a config key that can switch git hooks off: core.hooksPath, or
#   include.path / includeIf.<condition>.path (an included file can set core.hooksPath).
#   Matched case-insensitively (git config keys are case-insensitive) without forking tr
#   or needing bash 4. <text> may carry =value.
_grid_is_hookspath() {
  case "$1" in
    [cC][oO][rR][eE].[hH][oO][oO][kK][sS][pP][aA][tT][hH]|[cC][oO][rR][eE].[hH][oO][oO][kK][sS][pP][aA][tT][hH]=*) return 0 ;;
    [iI][nN][cC][lL][uU][dD][eE].[pP][aA][tT][hH]|[iI][nN][cC][lL][uU][dD][eE].[pP][aA][tT][hH]=*) return 0 ;;
    [iI][nN][cC][lL][uU][dD][eE][iI][fF].*.[pP][aA][tT][hH]|[iI][nN][cC][lL][uU][dD][eE][iI][fF].*.[pP][aA][tT][hH]=*) return 0 ;;
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

# _grid_record_git <index of the git word>
#   Record one git call. Runs in _grid_segment's scope (reads its r, m, f, n). Skips
#   git's global options to find the subcommand: -C <dir> and -c k=v take a value;
#   --git-dir / --work-tree / --namespace take one when given as two words; any other
#   leading dash word is a lone flag (--no-pager, -p, ...). Words are read through the
#   FLAG form so a quoted or escaped option cannot hide the subcommand.
#   --config-env=<key>=<ENVVAR> is -c with the value taken from the environment, so a
#   hooksPath key is the same override.
_grid_record_git() {
  local gj=$(($1 + 1)) gk gw gv gc="" gd="" gt=""
  while [ "$gj" -lt "$n" ]; do
    gw="${f[$gj]}"
    case "$gw" in
      -C) gc+=$'\037'"${f[$((gj + 1))]:-}"; gj=$((gj + 2)) ;;
      -c|--config-env)
        gv="${f[$((gj + 1))]:-}"
        if _grid_is_hookspath "$gv"; then
          GIT_VIOLATIONS+=("uses $gw with a hooks or include setting (can disable the repo's git hooks)")
        fi
        gj=$((gj + 2)) ;;
      --config-env=*)
        if _grid_is_hookspath "${gw#--config-env=}"; then
          GIT_VIOLATIONS+=("uses --config-env with a hooks or include setting (can disable the repo's git hooks)")
        fi
        gj=$((gj + 1)) ;;
      --git-dir) gd="${f[$((gj + 1))]:-}"; gj=$((gj + 2)) ;;
      --work-tree) gt="${f[$((gj + 1))]:-}"; gj=$((gj + 2)) ;;
      --git-dir=*) gd="${gw#--git-dir=}"; gj=$((gj + 1)) ;;
      --work-tree=*) gt="${gw#--work-tree=}"; gj=$((gj + 1)) ;;
      --namespace) gj=$((gj + 2)) ;;
      -*) gj=$((gj + 1)) ;;
      *) break ;;
    esac
  done
  [ "$gj" -lt "$n" ] || return 0

  GIT_SUB+=("${f[$gj]}")
  GIT_CD+=("$_GRID_CD"); GIT_C+=("$gc"); GIT_GITDIR+=("$gd"); GIT_WORKTREE+=("$gt")
  GIT_START+=("${#GIT_RAW[@]}")
  GIT_LEN+=($((n - gj - 1)))
  for ((gk = gj + 1; gk < n; gk++)); do
    GIT_RAW+=("${r[$gk]}"); GIT_MASK+=("${m[$gk]}"); GIT_FLAG+=("${f[$gk]}")
  done
}

# _grid_segment <depth> <n> <n RAW words> <n MASKED words> <n FLAG words>
#   Check one segment (the words between two separators): the assignment check, the
#   hook-file write check, then every git call in it.
#
#   A git call is ANY word of the segment that is `git` (any letter case, any path
#   prefix: Git, GIT, /usr/bin/git). Looking at every word, not only the first, means no
#   list of wrappers or shell keywords has to be kept: timeout, nohup, setsid, env -u X,
#   find -exec, ssh, `if ...; then git ...`, `! git`, `>/dev/null git` all reach git.
#   The accepted cost is false blocks such as `echo git commit -n`.
#   Shell wrappers (bash/sh/zsh/dash/ksh/busybox -c, eval, env -S) are re-scanned once,
#   at depth 1, because their payload is one quoted word.
_grid_segment() {
  local depth="$1" n="$2"
  shift 2
  local -a r=("${@:1:$n}") m=("${@:$((n + 1)):$n}") f=("${@:$((2 * n + 1)):$n}")
  local k j b v joined hasgit=0 redir=0 cmdw=0 sedc=0 inplace=0 pathhit=0
  # Always a violation, whatever the value: these switch hooks off or move git's config.
  local re_assign='^(GIT_CONFIG_COUNT|GIT_CONFIG_PARAMETERS|GIT_CONFIG_KEY_[0-9]+|GIT_CONFIG_GLOBAL|GIT_CONFIG_SYSTEM|GIT_CONFIG_NOSYSTEM|GIT_DIR|GIT_WORK_TREE|GIT_EXEC_PATH|GIT_TEMPLATE_DIR|HUSKY_SKIP_HOOKS|LEFTHOOK_EXCLUDE|PRE_COMMIT_ALLOW_NO_CONFIG)='
  local re_redir='^(&|[0-9]*)>>?([^&]|$)'

  # Assignment check on every word whose NAME is unquoted (matched on the MASKED form,
  # so `echo "HUSKY=0"` is not a hit while GIT_CONFIG_PARAMETERS="'...'" is: its value is
  # quoted, its name is not). Applies whatever the command is, so `export HUSKY=0` and
  # `env GIT_CONFIG_COUNT=1 ...` are caught too. HUSKY=0 and LEFTHOOK=0 are hits only
  # for that value; a bare SKIP=... is deliberately NOT matched (too common, too noisy).
  for ((k = 0; k < n; k++)); do
    # Cheap glob pre-test first: a regex per word made a 50 KB command slow (WP-019).
    case "${m[$k]}" in GIT_*|HUSKY*|LEFTHOOK*|PRE_COMMIT_*) ;; *) continue ;; esac
    if [[ "${m[$k]}" =~ $re_assign ]]; then
      GIT_VIOLATIONS+=("sets ${m[$k]%%=*} (a hook-disabling git or hook-manager override)")
    elif [[ "${m[$k]}" == HUSKY=* && "${r[$k]}" == "HUSKY=0" ]]; then
      GIT_VIOLATIONS+=("sets HUSKY=0 (disables husky git hooks)")
    elif [[ "${m[$k]}" == LEFTHOOK=* && "${r[$k]}" == "LEFTHOOK=0" ]]; then
      GIT_VIOLATIONS+=("sets LEFTHOOK=0 (disables lefthook git hooks)")
    fi
  done

  # Hook-file write check: a segment that names .git/config, .git/hooks or .githooks and
  # writes there (a > or >> redirect, tee, truncate, chmod, rm, mv, or sed -i) can switch
  # the hooks off without git being involved. When the segment is itself a git call, rm
  # and mv are git subcommands (git rm .githooks/x is a tracked-file change), so only a
  # redirect counts there.
  for ((k = 0; k < n; k++)); do
    case "${f[$k]}" in *.git/config*|*.git/hooks*|*.githooks*) pathhit=1; break ;; esac
  done
  if [ "$pathhit" = 1 ]; then
    for ((k = 0; k < n; k++)); do
      _grid_base "${f[$k]}"; b="$_GB"
      [[ "${r[$k]}" =~ $re_redir ]] && redir=1
      case "$b" in
        [gG][iI][tT]) hasgit=1 ;;
        tee|truncate|chmod|rm|mv|cp|ln|install|dd|unlink|-delete) cmdw=1 ;;   # ignored when the segment is a git call
        sed|perl) sedc=1 ;;
        -i*|-[a-hj-zA-Z]*i*|--in-place*) inplace=1 ;;
      esac
    done
    [ "$sedc" = 1 ] && [ "$inplace" = 1 ] && cmdw=1
    if [ "$redir" = 1 ] || { [ "$cmdw" = 1 ] && [ "$hasgit" = 0 ]; }; then
      GIT_VIOLATIONS+=("writes to .git/config, .git/hooks or .githooks (can switch git hooks off)")
    fi
  fi

  # Keep a running directory for `cd <dir>` / `pushd <dir>` segments, so a later git
  # call is attributed to the repo it will really run in. A destination that cannot be
  # known statically becomes ? (the scan then falls back to the payload cwd). ~ and ~/x
  # expand to $HOME. Options (-P, -L, --) are skipped.
  _grid_base "${f[0]}"
  case "$_GB" in
    cd|pushd)
      for ((k = 1; k < n; k++)); do
        case "${f[$k]}" in
          --) ;;
          -[!-]*) ;;
          *) v="${f[$k]}"
             case "$v" in
               -) v="?" ;;
               \~) v="$HOME" ;;
               \~/*) v="$HOME/${v#\~/}" ;;
               \~*|*'$'*|*'`'*) v="?" ;;
             esac
             _GRID_CD+=$'\037'"$v"
             break ;;
        esac
      done ;;
  esac

  # Find every git call and every re-scannable wrapper in the segment.
  for ((j = 0; j < n; j++)); do
    _grid_base "${f[$j]}"; b="$_GB"
    case "$b" in
      [gG][iI][tT]) _grid_record_git "$j" ;;
      bash|sh|zsh|dash|ksh|busybox)
        # `-c <arg>`, also -lc / -ec / any short cluster ending in c: re-run <arg> once.
        [ "$depth" -eq 0 ] || continue
        for ((k = j + 1; k < n - 1; k++)); do
          if [[ "${r[$k]}" =~ ^-[a-zA-Z]*c$ ]]; then
            _grid_scan "${r[$((k + 1))]}" 1
            break
          fi
        done ;;
      eval)
        # The remaining RAW words joined by spaces are re-run once.
        [ "$depth" -eq 0 ] || continue
        joined=""
        for ((k = j + 1; k < n; k++)); do joined+="${r[$k]} "; done
        _grid_scan "$joined" 1 ;;
      env)
        # env -S "<command line>" (also -S<text>, --split-string[=]<text>): the value is a
        # command line, re-run once.
        [ "$depth" -eq 0 ] || continue
        for ((k = j + 1; k < n; k++)); do
          case "${r[$k]}" in
            -S|--split-string) [ "$((k + 1))" -lt "$n" ] && _grid_scan "${r[$((k + 1))]}" 1; break ;;
            --split-string=*) _grid_scan "${r[$k]#--split-string=}" 1; break ;;
            -S?*) _grid_scan "${r[$k]#-S}" 1; break ;;
          esac
        done ;;
    esac
  done
}

# grid_git_segments <command>: see the header above for the result globals.
# SC2034 is disabled because the GIT_* results are read by the scripts that
# source this file, not here.
# shellcheck disable=SC2034
grid_git_segments() {
  GIT_SUB=(); GIT_START=(); GIT_LEN=(); GIT_RAW=(); GIT_MASK=(); GIT_FLAG=(); GIT_VIOLATIONS=()
  GIT_CD=(); GIT_C=(); GIT_GITDIR=(); GIT_WORKTREE=(); _GRID_CD=""; GIT_UNBALANCED=0; GIT_FAIL=""
  _grid_scan "$1" 0
}
