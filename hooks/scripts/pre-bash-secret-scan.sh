#!/usr/bin/env bash
# hooks/scripts/pre-bash-secret-scan.sh — PreToolUse(Bash) guard, launched by hooks/run.sh.
#
# Blocks (exit 2) a git command that would add a line matching a secret pattern
# (hooks/lib/secret-patterns.sh) or commit a sensitive file, and a `git add` of a
# sensitive file (.env, *.pem, private-key names). Rules: design.md "Guard rules".
#
#   - `git commit` (and the other commit-making subcommands: merge, cherry-pick, revert,
#     am, rebase, commit-tree, or an alias for commit): scans the added lines of
#     `git diff --cached`. When the commit names pathspecs or uses -a/-i/-o/-p (or their
#     long forms, or --pathspec-from-file) it ALSO scans `git diff <HEAD|empty tree>
#     [-- pathspecs]`, because such a commit takes the working-tree content.
#   - The repo scanned is the one the command targets (-C, --git-dir, --work-tree, a
#     preceding cd), and also the payload cwd when a cd moved away from it.
#   - A `git add ... && git commit` in ONE command: the hook runs before the add, so the
#     add's files are not staged yet. The scan lists what the add would stage (git status
#     for its pathspecs) and reads those files from the working tree. Past
#     GRID_SCAN_MAX_FILES or GRID_SCAN_MAX_BYTES it blocks and asks for a separate add.
#   - The command text of a commit is scanned too (it covers the message and a same-command
#     `echo secret >> file && git commit -am`).
#   - Never prints a secret value (file, line, pattern name, first 4 chars only) and
#     never mentions the allow pragma in its message.
#   - Exit 0 on non-JSON stdin, a non-Bash tool, no command, a command with no git commit
#     or add in it, or a target that is not inside a git repository.
#   - Exit 2 when jq is missing (fail closed).
#
# A mistake-catcher for an agent, not a security boundary.

LC_ALL=C; export LC_ALL
set -f   # no globbing: word lists below are split on purpose
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
# shellcheck source=../lib/common.sh
. "$HERE/lib/common.sh"
# shellcheck source=../lib/secret-patterns.sh
. "$HERE/lib/secret-patterns.sh"

grid_require_jq closed

payload="$(cat)"
if ! printf '%s' "$payload" | jq -e 'type == "object"' >/dev/null 2>&1; then
  echo "pre-bash-secret-scan: stdin is not a JSON object, skipping" >&2
  exit 0
fi
tool="$(printf '%s' "$payload" | jq -r '.tool_name // empty')"
[ "$tool" = "Bash" ] || exit 0
command="$(printf '%s' "$payload" | jq -r '.tool_input.command // empty')"
[ -n "$command" ] || exit 0
cwd="$(printf '%s' "$payload" | jq -r '.cwd // empty')"

# Fast path: nothing here can matter unless the text mentions git (a commit can hide
# behind an alias, so `commit` is not required). The test runs on the text with quotes
# and backslashes removed, as the shell would (g""it, g\it are git), case-insensitively;
# a command holding $ or a backtick may build a word the text test cannot see, so it
# always goes to the tokenizer.
stripped="${command//$'\\\n'/}"           # a backslash-newline continuation joins the word
stripped="${stripped//[\"\'\\]/}"
shopt -s nocasematch
case "$stripped" in
  *git*) hit=1 ;;
  *) hit=0 ;;
esac
shopt -u nocasematch
if [ "$hit" = 0 ]; then
  case "$command" in
    *'$'*|*'`'*) ;;
    *) exit 0 ;;
  esac
fi

grid_check_cmd_cap pre-bash-secret-scan "$command"

# Everything below needs a directory to start from.
[ -n "$cwd" ] && [ -d "$cwd" ] || exit 0

grid_git_segments "$command"
grid_check_balanced pre-bash-secret-scan

US=$'\037'
RS=$'\036'

findings=()          # "file:line: name (abcd...)" or "file: sensitive-file"
MAX_FINDINGS=10
# clean_name <text>: a file name made safe to print: control characters (a newline
# would render injected text as a separate line of the block message) become ?, and
# the name is cut at 100 characters.
clean_name() {
  local t="${1//[[:cntrl:]]/?}"
  printf '%s' "${t:0:100}"
}
add_finding() {
  local f
  # The staged diff and the working-tree diff can report the same line twice.
  for f in "${findings[@]}"; do [ "$f" = "$1" ] && return 0; done
  [ "${#findings[@]}" -lt "$MAX_FINDINGS" ] && findings+=("$1")
  return 0
}

# Budgets (see hooks/README.md "Tuning"). A scan that cannot finish inside the 5 s hook
# timeout would let the command through unscanned, so past a budget the hook blocks.
num_or() { if [[ "$1" =~ ^[0-9]+$ ]]; then printf '%s' "$1"; else printf '%s' "$2"; fi; }
MAX_SCAN_LINES="$(num_or "${GRID_SCAN_MAX_LINES:-}" 3000)"
MAX_SCAN_FILES="$(num_or "${GRID_SCAN_MAX_FILES:-}" 500)"
MAX_SCAN_BYTES="$(num_or "${GRID_SCAN_MAX_BYTES:-}" 5242880)"
too_large=0          # more candidate lines than MAX_SCAN_LINES
add_too_big=0        # a chained add would stage more than MAX_SCAN_FILES / MAX_SCAN_BYTES
PREFILTER_RE="$(secret_prefilter_re)"

# set_target <dir US git-dir US work-tree>: fill GITARGS for one target repo and test it.
# Returns 1 when the directory is missing or is not a repository.
GITARGS=()
set_target() {
  local t_dir t_gd t_wt
  IFS="$US" read -r t_dir t_gd t_wt <<< "$1"
  [ -d "$t_dir" ] || return 1
  GITARGS=(-C "$t_dir")
  [ -z "$t_gd" ] || GITARGS+=("--git-dir=$t_gd")
  [ -z "$t_wt" ] || GITARGS+=("--work-tree=$t_wt")
  git "${GITARGS[@]}" rev-parse --git-dir >/dev/null 2>&1
}

# segment_targets <i>: fill TARGETS with the repos segment i points at. The directory is
# the payload cwd, then the cd chain, then git's -C chain. A cd that cannot be known
# (a $VAR) drops the cd-applied target; when a cd was seen the cwd-only target is kept
# too, because a subshell cd does not move the commands after it.
TARGETS=()
segment_targets() {
  local i="$1" d cur cd_ok=1 gd wt
  gd="${GIT_GITDIR[$i]}"; wt="${GIT_WORKTREE[$i]}"
  local -a cds=() cs=()
  IFS="$US" read -r -a cds <<< "${GIT_CD[$i]}"
  IFS="$US" read -r -a cs <<< "${GIT_C[$i]}"
  TARGETS=()
  cur="$cwd"
  for d in "${cs[@]}"; do
    [ -n "$d" ] || continue
    case "$d" in /*) cur="$d" ;; *) cur="$cur/$d" ;; esac
  done
  local plain="$cur"                       # -C chain from the payload cwd, no cd
  cur="$cwd"
  for d in "${cds[@]}" "${cs[@]}"; do
    [ -n "$d" ] || continue
    if [ "$d" = "?" ]; then cd_ok=0; break; fi
    case "$d" in /*) cur="$d" ;; *) cur="$cur/$d" ;; esac
  done
  if [ "$cd_ok" = 1 ]; then TARGETS+=("$cur$US$gd$US$wt"); fi
  if [ "$cd_ok" = 0 ] || [ "$cur" != "$plain" ]; then TARGETS+=("$plain$US$gd$US$wt"); fi
}

# consume_stream: read "file US line US content" records from stdin (the output of the
# producers below, already filtered to candidate lines) and run the exact matcher on
# each. More than MAX_SCAN_LINES candidates sets $too_large and stops.
consume_stream() {
  local file lineno content n=0
  [ "$too_large" = 0 ] || return 0
  while IFS="$US" read -r file lineno content; do
    n=$((n + 1))
    if [ "$n" -gt "$MAX_SCAN_LINES" ]; then too_large=1; return 0; fi
    if _secret_match "$content"; then
      add_finding "$(clean_name "$file"):$lineno: $SECRET_MATCH_NAME (${SECRET_MATCH_TEXT:0:4}...)"
    fi
    # Ten findings fill the list; reading on would only burn the timeout.
    [ "${#findings[@]}" -lt "$MAX_FINDINGS" ] || return 0
  done
}

# scan_diff <git diff args...>
#   Run git diff in the target repo and test every added line. Header/hunk state
#   machine: inside a file header ("diff --git" up to the first "@@") "+++ b/<path>" names
#   the file; "@@ -a,b +c,d @@" sets the new-file line counter to c; each "+" body line is
#   one added line. Binary notices and /dev/null live in the header and are ignored.
#   Explicit prefixes keep the parse independent of diff.noprefix and
#   diff.mnemonicPrefix; quotepath=false keeps non-ASCII names readable.
#
#   --text: without it git prints "Binary files differ" for a file with a NUL byte, a
#   UTF-16 file or a path an attribute marks -diff, and the file is never scanned (a
#   cloned repo can ship the attribute). NUL bytes are then deleted (tr), which also turns
#   UTF-16 text back into ASCII-looking text the patterns can match. Every other control
#   byte except tab and newline is deleted too: 0x1E and 0x1F are this scan's own stream
#   separators, and content must never be able to forge one.
#
#   Speed (WP-019): one awk state machine reads the diff, then one `grep -Ei` with the
#   union of the pattern table keeps only lines some pattern could match, and only those
#   reach the slow per-line bash matcher.
scan_diff() {
  consume_stream < <(git "${GITARGS[@]}" -c core.quotepath=false -c diff.relative=false diff -U0 --no-color --no-ext-diff --no-textconv --text \
                       --src-prefix=a/ --dst-prefix=b/ "$@" 2>/dev/null \
                     | tr -d '\000-\010\013-\037' \
                     | awk -v sep="$US" '
                         /^diff --git / { hdr = 1; f = ""; next }
                         hdr && substr($0, 1, 6) == "+++ b/" {
                           f = substr($0, 7); t = index(f, "\t"); if (t > 0) f = substr(f, 1, t - 1); next }
                         /^@@ -[0-9,]+ \+[0-9]+/ {
                           match($0, /\+[0-9]+/); ln = substr($0, RSTART + 1, RLENGTH - 1) + 0; hdr = 0; next }
                         !hdr && substr($0, 1, 1) == "+" { print f sep ln sep substr($0, 2); ln++ }
                       ' \
                     | grep -Ei -e "$PREFILTER_RE")
}

# check_sensitive_names <git diff args...>
#   Test the names of the files the commit adds or changes (deletions excluded:
#   removing a .env from git is the fix, not the leak) against secret_sensitive_name.
#   NUL-separated (-z) so odd file names cannot confuse the loop.
check_sensitive_names() {
  local name
  while IFS= read -r -d '' name; do
    if secret_sensitive_name "${name##*/}"; then
      add_finding "$(clean_name "$name"): sensitive-file"
    fi
  done < <(git "${GITARGS[@]}" -c core.quotepath=false -c diff.relative=false diff --name-only --no-textconv -z --diff-filter=d "$@" 2>/dev/null)
}

# scan_chained_add <pathspecs, US separated> <update-only 0|1>
#   For `git add <pathspecs> && git commit` in one command: the add has not run when this
#   hook runs, so the index is empty. List what the add would stage (git status for the
#   same pathspecs; untracked files too, unless the add is -u), check each name, and scan
#   each file's content from the working tree (same NUL-stripping and prefilter as
#   scan_diff). Over the file or byte budget it sets $add_too_big instead of scanning.
scan_chained_add() {
  local specs="$1" upd="$2" ent st path top total
  local -a sp=() files=()
  IFS="$US" read -r -a sp <<< "$specs"
  top="$(git "${GITARGS[@]}" rev-parse --show-toplevel 2>/dev/null)" || return 0
  [ -n "$top" ] || return 0
  while IFS= read -r -d '' ent; do
    st="${ent:0:2}"; path="${ent:3}"
    # a rename or copy entry is followed by its source path: read and drop it
    case "$st" in R?|C?|?R|?C) IFS= read -r -d '' ent ;; esac
    case "$st" in *D*) continue ;; esac                       # deleted: nothing to read
    if [ "$upd" = 1 ] && [ "$st" = "??" ]; then continue; fi   # -u never adds untracked files
    files+=("$path")
    if [ "${#files[@]}" -gt "$MAX_SCAN_FILES" ]; then add_too_big=1; return 0; fi
  done < <(if [ "${#sp[@]}" -gt 0 ]; then
             git "${GITARGS[@]}" -c core.quotepath=false status --porcelain=v1 -z -uall -- "${sp[@]}" 2>/dev/null
           else
             git "${GITARGS[@]}" -c core.quotepath=false status --porcelain=v1 -z -uall 2>/dev/null
           fi)
  [ "${#files[@]}" -gt 0 ] || return 0
  for path in "${files[@]}"; do
    if secret_sensitive_name "${path##*/}"; then add_finding "$(clean_name "$path"): sensitive-file"; fi
  done
  total="$(cd "$top" && cat -- "${files[@]}" 2>/dev/null | wc -c)"
  if [ "${total//[[:space:]]/}" -gt "$MAX_SCAN_BYTES" ]; then add_too_big=1; return 0; fi
  consume_stream < <(cd "$top" && {
                       for path in "${files[@]}"; do
                         if [ -f "$path" ] && [ ! -L "$path" ]; then
                           printf '%s%s\n' "$RS" "$path"
                           tr -d '\000-\010\013-\037' < "$path"
                           printf '\n'
                         fi
                       done
                     } | awk -v sep="$US" -v mark="$RS" '
                           substr($0, 1, 1) == mark { f = substr($0, 2); ln = 0; next }
                           { ln++; print f sep ln sep $0 }
                         ' \
                       | grep -Ei -e "$PREFILTER_RE")
}

# alias_verb <sub>: when <sub> is a git alias in the current target repo, print the first
# word of its value (a shell alias, "!...", counts as commit when it mentions commit).
alias_verb() {
  local line key val
  shopt -s nocasematch
  while IFS= read -r line; do
    key="${line%% *}"; val="${line#* }"
    if [[ "$key" == "alias.$1" ]]; then
      case "$val" in
        '!'*) case "$val" in *commit*) printf 'commit' ;; esac ;;
        *) printf '%s' "${val%% *}" ;;
      esac
      break
    fi
  done < <(git "${GITARGS[@]}" config --get-regexp '^alias\.' 2>/dev/null)
  shopt -u nocasematch
}

# Subcommands that never create a commit and are never aliases worth a lookup (the lookup
# costs one git call), so a plain `git status` stays at near-zero cost.
is_plain_sub() {
  case "$1" in
    status|log|diff|show|branch|checkout|switch|fetch|pull|push|remote|config|stash|tag|reset|restore|rm|mv|clone|init|worktree|grep|ls-files|rev-parse|describe|blame|clean|gc|fsck|help|version|bisect|reflog|submodule|apply|archive|bundle|shortlog|whatchanged|var|notes|fast-import) return 0 ;;
  esac
  return 1
}

# Chained adds seen so far in this command, one entry per (add segment, target).
ADD_ENC=(); ADD_SPECS=(); ADD_UPD=()
handled_commit=0     # a commit-making segment was seen (the command text is scanned then)

for ((i = 0; i < ${#GIT_SUB[@]}; i++)); do
  sub="${GIT_SUB[$i]}"; start="${GIT_START[$i]}"; len="${GIT_LEN[$i]}"
  segment_targets "$i"
  targets=()
  for enc in "${TARGETS[@]}"; do
    if set_target "$enc"; then targets+=("$enc"); fi
  done
  # A -C or cd target that does not exist (often a $VAR the hook cannot expand) must not
  # make the segment invisible: fall back to the payload cwd's own repository.
  [ "${#targets[@]}" -gt 0 ] || targets=("$cwd$US$US")
  for enc in "${targets[@]}"; do
    set_target "$enc" || continue
    eff="$sub"
    case "$sub" in
      add|stage|commit|commit-tree|merge|cherry-pick|revert|am|rebase) ;;
      *)
        is_plain_sub "$sub" && continue
        eff="$(alias_verb "$sub")"
        case "$eff" in commit|add|stage) ;; *) continue ;; esac ;;
    esac

    if [ "$eff" = "add" ] || [ "$eff" = "stage" ]; then
      # `git add` of a sensitive file: name check on the literal words. After `--` every
      # word is a path; before it, option words (leading dash) are skipped. The words are
      # also the pathspecs of a later same-command commit (chained add).
      after_dd=0; specs=""; upd=0; whole=0
      for ((k = start; k < start + len; k++)); do
        w="${GIT_FLAG[$k]}"
        if [ "$after_dd" = 0 ] && [ "$w" = "--" ]; then after_dd=1; continue; fi
        if [ "$after_dd" = 0 ] && [[ "$w" == -* ]]; then
          case "$w" in
            -u|--update) upd=1 ;;
            -A|--all|--no-ignore-removal|-p|--patch|-i|--interactive) whole=1 ;;
          esac
          continue
        fi
        if secret_sensitive_name "${w##*/}"; then add_finding "$(clean_name "$w"): sensitive-file"; fi
        specs+="${specs:+$US}$w"
      done
      # -A / -u / -p with no pathspec means the whole tree: status takes no pathspec then
      if [ -n "$specs" ] || [ "$whole" = 1 ] || [ "$upd" = 1 ]; then
        ADD_ENC+=("$enc"); ADD_SPECS+=("$specs"); ADD_UPD+=("$upd")
      fi
    else
      # Not an add: a commit-making subcommand.
      handled_commit=1
      pathspecs=(); incl=0; skip_next=0; after_dd=0
      if [ "$eff" = "commit" ]; then
        # Work out pathspecs and whether the commit reads the working tree (-a, -i, -o, -p).
        # Value-taking options consume the next word; a short cluster is read letter by
        # letter: a, i, o, p set the flag; a value-taking letter (m F C c t) takes either
        # the rest of the word or, when last, the next word.
        for ((k = start; k < start + len; k++)); do
          w="${GIT_FLAG[$k]}"
          if [ "$skip_next" = 1 ]; then skip_next=0; continue; fi
          if [ "$after_dd" = 1 ]; then pathspecs+=("$w"); continue; fi
          case "$w" in
            --) after_dd=1 ;;
            --pathspec-from-file) incl=1; skip_next=1 ;;
            --pathspec-from-file=*|--interactive|--patch) incl=1 ;;
            --author|--date|--cleanup|--fixup|--squash|--trailer|--template|--file|--message|--reuse-message|--reedit-message) skip_next=1 ;;
            --include|--only|--all) incl=1 ;;
            --*) ;;
            -?*)
              rest="${w#-}"
              while [ -n "$rest" ]; do
                letter="${rest:0:1}"; rest="${rest:1}"
                case "$letter" in
                  a|i|o|p) incl=1 ;;
                  m|F|C|c|t) [ -z "$rest" ] && skip_next=1; break ;;   # value follows (or is attached)
                  S) break ;;                                           # -S<keyid>: attached only
                esac
              done ;;
            *) pathspecs+=("$w") ;;
          esac
        done
      fi

      # 0. a same-command add has not run yet: scan what it would stage
      for ((a = 0; a < ${#ADD_ENC[@]}; a++)); do
        if [ "${ADD_ENC[$a]}" = "$enc" ] || set_target "${ADD_ENC[$a]}"; then
          scan_chained_add "${ADD_SPECS[$a]}" "${ADD_UPD[$a]}"
        fi
        set_target "$enc"
      done
      # 1. what is staged. The cheap name check runs BEFORE the diff scan: a staged .env
      #    must be reported even when a large diff then fills the list or the cap.
      check_sensitive_names --cached
      scan_diff --cached
      # 2. what a pathspec / -a / -i / -o / -p commit would take from the working tree
      if [ "${#pathspecs[@]}" -gt 0 ] || [ "$incl" = 1 ]; then
        if git "${GITARGS[@]}" rev-parse --verify -q HEAD >/dev/null 2>&1; then
          base=HEAD
        else
          base=4b825dc642cb6eb9a060e54bf8d69288fbee4904   # the empty tree: no HEAD yet
        fi
        if [ "${#pathspecs[@]}" -gt 0 ]; then
          check_sensitive_names "$base" -- "${pathspecs[@]}"
          scan_diff "$base" -- "${pathspecs[@]}"
        else
          check_sensitive_names "$base"
          scan_diff "$base"
        fi
      fi
    fi
  done
  # Not a repository at all (every target failed): the unscanned segment is not ours.
done

# 3. the command text of a commit: the message, and a same-command write such as
#    `echo key=... >> file && git commit -am x` that is not on disk yet.
if [ "$handled_commit" = 1 ] && _secret_match "$command"; then
  add_finding "commit command text: $SECRET_MATCH_NAME (${SECRET_MATCH_TEXT:0:4}...)"
fi

if [ "${#findings[@]}" -gt 0 ] || [ "$too_large" = 1 ] || [ "$add_too_big" = 1 ]; then
  {
    echo "BLOCKED by the-grid hook pre-bash-secret-scan: possible secret in this commit (values not shown):"
    for f in "${findings[@]}"; do echo "  $f"; done
    if [ "$too_large" = 1 ]; then
      echo "  diff too large to scan (more than $MAX_SCAN_LINES candidate lines): split the commit into smaller ones."
    fi
    if [ "$add_too_big" = 1 ]; then
      echo "  the add in this command would stage more than $MAX_SCAN_FILES files or $MAX_SCAN_BYTES bytes: stage in a separate call so the scan can see it."
    fi
    echo "Remove the secret (or unstage the file), then retry."
    echo "Human override: launch claude with GRID_DISABLED_HOOKS=pre-bash-secret-scan"
  } >&2
  exit 2
fi
exit 0
