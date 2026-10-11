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
#   no-frontmatter    SKILL.md does not start with a `---` block
#   name-mismatch     frontmatter `name` differs from the dir name
#   name-invalid      dir name fails ^[a-z0-9]+(-[a-z0-9]+)*$ or is over 64 chars
#   description-long  description is over 1024 chars (YAML-folded)
#   claude-specific   a file mentions ~/.claude, $HOME/.claude, .claude/ or CLAUDE_
#
# These are the Agent Skills spec limits (agentskills.io) plus the one thing that
# is certain to break elsewhere: a hard-coded Claude path.

SKILL_FRONTMATTER_PY="${SKILL_FRONTMATTER_PY:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/skill_frontmatter.py}"

skill_portable() {
  local dir="${1%/}" name fm fm_name fm_len
  name="$(basename "$dir")"

  # python3 -I: isolated mode, so nothing in the cwd or env can shadow the stdlib.
  if ! fm="$(python3 -I "$SKILL_FRONTMATTER_PY" --len "$dir/SKILL.md" 2>/dev/null)"; then
    echo "no-frontmatter"; return 1
  fi
  fm_name="${fm%%$'\t'*}"; fm_len="${fm#*$'\t'}"

  if [ "$fm_name" != "$name" ]; then echo "name-mismatch"; return 1; fi
  if [ "${#name}" -gt 64 ] || ! [[ "$name" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]]; then
    echo "name-invalid"; return 1
  fi
  if [ "$fm_len" -gt 1024 ]; then echo "description-long"; return 1; fi
  # -I skips binary files; -r follows the (command-line) dir even if it is a symlink.
  # The '~' is a literal in a regex, not a home dir (SC2088).
  # shellcheck disable=SC2088
  if grep -rqIE '~/\.claude|\$HOME/\.claude|\.claude/|CLAUDE_' "$dir" 2>/dev/null; then
    echo "claude-specific"; return 1
  fi
  return 0
}
