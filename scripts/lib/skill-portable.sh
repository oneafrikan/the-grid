#!/usr/bin/env bash
#
# skill-portable.sh — shared by wire.sh (source it, don't run it).
#
# skill_portable <skill_dir> decides whether a skill may be linked into a
# NON-Claude harness's skills dir. It prints nothing and returns 0 when the skill
# passes; otherwise it prints ONE reason and returns 1. The link name is the dir's
# basename (what wire_skill links it as). Requires python3 (frontmatter reader).
#
# Reasons, checked in this order (the first hit wins):
#   no-frontmatter      SKILL.md does not start with a `---` block
#   python-failed       python3 ran but died (neither "frontmatter read" nor "no block")
#   name-invalid        dir name holds a control character (checked first: a trailing
#                       newline would otherwise surface as name-mismatch)
#   name-mismatch       frontmatter `name` differs from the dir name
#   name-invalid        dir name fails ^[a-z0-9]+(-[a-z0-9]+)*$ or is over 64 chars
#   description-missing the description is empty or absent
#   description-long    description is over 1024 chars (YAML-folded)
#   claude-only-guard   frontmatter carries a Claude-only guard key (disable-model-invocation,
#                       allowed-tools, hooks, context): another harness would drop the guard
#   claude-specific     a file mentions .claude (not .claude-foo), .the-grid, .grid/,
#                       CLAUDE_ or CLAUDE.md
#   symlink-escape      a symlink inside the skill dir resolves outside it
#
# These are the Agent Skills spec limits (agentskills.io) plus what is certain to break
# elsewhere: a hard-coded Claude path. This is a COMPATIBILITY check, not a security
# control: the protection for the shared dir is the audit (wire.sh step 0: home paths,
# symlink escapes), not this filter.

SKILL_FRONTMATTER_PY="${SKILL_FRONTMATTER_PY:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/skill_frontmatter.py}"

skill_portable() {
  local dir="${1%/}" name fm fm_name fm_len rc guard
  # Parameter expansion, not $(basename): command substitution strips a trailing newline, so a
  # dir named "trail<LF>" used to look like "trail" and pass.
  name="${dir##*/}"

  # A control character in the name is never valid; checked before the frontmatter read so
  # it is reported as name-invalid, not as a mismatch with the (single-line) frontmatter name.
  case "$name" in *[[:cntrl:]]*) echo "name-invalid"; return 1 ;; esac

  # python3 -I: isolated mode, so nothing in the cwd or env can shadow the stdlib.
  # Exit 0 = read, 1 = no frontmatter block; anything else means python itself failed.
  rc=0
  fm="$(python3 -I "$SKILL_FRONTMATTER_PY" --len "$dir/SKILL.md" 2>/dev/null)" || rc=$?
  if [ "$rc" -eq 1 ]; then echo "no-frontmatter"; return 1; fi
  if [ "$rc" -ne 0 ]; then echo "python-failed"; return 1; fi
  fm_name="${fm%%$'\t'*}"; fm_len="${fm#*$'\t'}"

  if [ "$fm_name" != "$name" ]; then echo "name-mismatch"; return 1; fi
  if [ "${#name}" -gt 64 ] || ! [[ "$name" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]]; then
    echo "name-invalid"; return 1
  fi
  if [ "$fm_len" -eq 0 ]; then echo "description-missing"; return 1; fi
  if [ "$fm_len" -gt 1024 ]; then echo "description-long"; return 1; fi
  # Claude-only guard keys: another harness would silently drop the guard.
  guard="$(python3 -I "$SKILL_FRONTMATTER_PY" --claude-only "$dir/SKILL.md" 2>/dev/null)" || guard=""
  if [ -n "$guard" ]; then echo "claude-only-guard"; return 1; fi
  # -I skips binary files (not read as instructions); -r follows the (command-line) dir even if
  # it is a symlink; .git and node_modules are never skill content. `.claude` counts unless it
  # is the start of a longer name (.claude-plugin).
  if grep -rqIE --exclude-dir=.git --exclude-dir=node_modules \
       '\.claude([^A-Za-z0-9_-]|$)|\.the-grid|\.grid/|CLAUDE_|CLAUDE\.md' "$dir" 2>/dev/null; then
    echo "claude-specific"; return 1
  fi
  # A symlink that resolves outside the skill dir (python resolves it with realpath). Most skills
  # hold no symlink at all, so a cheap find decides whether to pay for the interpreter start.
  if [ -n "$(find -H "$dir" -type l -print -quit 2>/dev/null)" ] &&
     ! python3 -I "$SKILL_FRONTMATTER_PY" --escaping-links "$dir" >/dev/null 2>&1; then
    echo "symlink-escape"; return 1
  fi
  return 0
}
