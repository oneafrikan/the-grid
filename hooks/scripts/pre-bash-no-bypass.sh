#!/usr/bin/env bash
# hooks/scripts/pre-bash-no-bypass.sh — PreToolUse(Bash) guard, launched by hooks/run.sh.
#
# Blocks (exit 2, reason on stderr) a Bash command that would bypass git's safety
# nets: --no-verify / commit -n, hook-disabling config, or a force-push. The exact
# rules and their false-positive regression tables are in
# openspec/changes/hook-profiles/design.md ("Guard rules").
#
# Exit 0 on: stdin that is not JSON, a tool other than Bash, or no command (Claude
# Code always sends JSON; bricking every Bash call on garbage would be worse).
# Exit 2 when jq is missing (fail closed, see grid_require_jq).
#
# A mistake-catcher for an agent, not a security boundary.

LC_ALL=C; export LC_ALL
set -f   # no globbing: the alias-value word split below must not expand * or ?
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
# shellcheck source=../lib/common.sh
. "$HERE/lib/common.sh"

grid_require_jq closed

payload="$(cat)"
# Not a JSON object -> let the call through.
if ! printf '%s' "$payload" | jq -e 'type == "object"' >/dev/null 2>&1; then
  echo "pre-bash-no-bypass: stdin is not a JSON object, skipping" >&2
  exit 0
fi
tool="$(printf '%s' "$payload" | jq -r '.tool_name // empty')"
[ "$tool" = "Bash" ] || exit 0
command="$(printf '%s' "$payload" | jq -r '.tool_input.command // empty')"
[ -n "$command" ] || exit 0

# Fast path: every rule needs one of these substrings somewhere in the text.
# `git` covers all git rules (including \git, /usr/bin/git); the assignment rules
# need GIT_CONFIG or HUSKY. Anything else cannot match, so skip the tokenizer.
case "$command" in
  *git*|*GIT_CONFIG*|*HUSKY*) ;;
  *) exit 0 ;;
esac

grid_check_cmd_cap pre-bash-no-bypass "$command"

grid_git_segments "$command"

reasons=()
for v in "${GIT_VIOLATIONS[@]}"; do reasons+=("$v"); done

# Per git segment checks, on the MASKED words (quoted text never counts as a flag)
# except config values, which are read from the RAW words.
re_short_n='^-[^-mFCctS]*n'       # a short cluster with n before any value-taking letter
re_push_f='^-[^-o]*f'             # a short push cluster containing f (-f, -fu, -uf)
for ((i = 0; i < ${#GIT_SUB[@]}; i++)); do
  sub="${GIT_SUB[$i]}"; start="${GIT_START[$i]}"; len="${GIT_LEN[$i]}"
  for ((k = start; k < start + len; k++)); do
    w="${GIT_MASK[$k]}"
    # --no-verify on any subcommand (commit, push, merge, ...)
    if [ "$w" = "--no-verify" ]; then
      reasons+=("git $sub --no-verify skips git hooks")
    fi
    case "$sub" in
      commit)
        if [[ "$w" =~ $re_short_n ]]; then
          reasons+=("git commit $w includes -n, which is --no-verify")
        fi ;;
      push)
        if [ "$w" = "--force" ] || [ "$w" = "--mirror" ] || [[ "$w" =~ $re_push_f ]] || [[ "$w" == +* ]]; then
          reasons+=("git push $w is a forced push (use --force-with-lease)")
        fi ;;
    esac
  done

  if [ "$sub" = "config" ]; then
    # Collect positional words (key, then value), skipping options and the values
    # of value-taking options. Any read flag means the call is a read.
    pos=(); is_read=0; skip=0
    for ((k = start; k < start + len; k++)); do
      w="${GIT_RAW[$k]}"
      if [ "$skip" = 1 ]; then skip=0; continue; fi
      case "$w" in
        --get|--get-all|--get-regexp|--list|-l|get|--unset|--unset-all) is_read=1 ;;
        -f|--file|--blob|--type|--default|--comment) skip=1 ;;
        -*) ;;
        *) pos+=("$w") ;;
      esac
    done
    # A write has a key AND a value; a lone key is a read.
    if [ "$is_read" = 0 ] && [ "${#pos[@]}" -ge 2 ]; then
      if _grid_is_hookspath "${pos[0]}"; then
        reasons+=("git config writes core.hooksPath (disables git hooks)")
      fi
      case "${pos[0]}" in
        [aA][lL][iI][aA][sS].*)
          # An alias whose RAW value hides --no-verify or a -n cluster.
          alias_value="${pos[1]}"
          bad=0
          case "$alias_value" in *--no-verify*) bad=1 ;; esac
          for aw in $alias_value; do
            [[ "$aw" =~ $re_short_n ]] && bad=1
          done
          [ "$bad" = 1 ] && reasons+=("git config alias ${pos[0]} hides --no-verify")
          ;;
      esac
    fi
  fi
done

if [ "${#reasons[@]}" -gt 0 ]; then
  {
    echo "BLOCKED by the-grid hook pre-bash-no-bypass:"
    for r in "${reasons[@]}"; do echo "  - $r"; done
    echo "Do not bypass git hooks or force-push; fix the underlying problem."
    echo "Human override: launch claude with GRID_DISABLED_HOOKS=pre-bash-no-bypass"
  } >&2
  exit 2
fi
exit 0
