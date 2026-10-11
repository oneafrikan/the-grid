#!/usr/bin/env bash
#
# harness.sh — shared by wire.sh (source it, don't run it).
#
# Reads the harness registry (scripts/lib/harnesses.txt) and resolves its paths.
# Every helper is bash 3.2-safe (macOS ships 3.2): no associative arrays, no
# mapfile, no ${x,,}, and no tilde in a ${v/#...} pattern (3.2 mishandles it).
#
#   harness_names               registry names, one per line, in file order
#   harness_field <name> <col>  one column of <name>'s row; <col> is one of
#                               skills_dir agents_dir compose_target rules_file
#                               rules_harness. Prints nothing for an unknown name.
#   harness_valid <name>        exit 0 when <name> is a registry row
#   harness_path <value>        expand a registry path value (see below)
#
# HARNESS_REGISTRY overrides the registry file (tests); the default sits next to
# this file, so a mock GRID_DIR never needs its own copy.

HARNESS_REGISTRY="${HARNESS_REGISTRY:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/harnesses.txt}"

# Registry rows with comments and blank lines removed. A plain awk (default field
# split) is used on purpose: the file may be edited with spaces or tabs.
_harness_rows() {
  awk '{ sub(/#.*/, "") } NF { print }' "$HARNESS_REGISTRY"
}

harness_names() {
  _harness_rows | awk '{ print $1 }'
}

harness_field() {
  local name="$1" col="$2" idx
  case "$col" in
    skills_dir) idx=2 ;; agents_dir) idx=3 ;; compose_target) idx=4 ;;
    rules_file) idx=5 ;; rules_harness) idx=6 ;;
    *) echo "harness_field: unknown column '$col'" >&2; return 2 ;;
  esac
  _harness_rows | awk -v n="$name" -v i="$idx" '$1 == n { print $i; exit }'
}

# A registry row always has a skills_dir ('-' at minimum), so a non-empty field
# means the row exists. (No `names | grep -q` pipe: under pipefail an early-exiting
# grep can SIGPIPE the writer and turn a match into a failure.)
harness_valid() {
  [ -n "$(harness_field "$1" skills_dir)" ]
}

# Expand one registry path value to a real path.
#   -                 echoed unchanged (the harness has none of that thing)
#   ~/.config/<rest>  ${XDG_CONFIG_HOME:-<home>/.config}/<rest>, but ONLY when both
#                     GRID_DRY_HOME and GRID_HARNESS_HOME are unset: OpenCode follows
#                     XDG, and the override must never let a test escape its sandbox
#   ~/<rest>          <base>/<rest>, <base> = ${GRID_DRY_HOME:-${GRID_HARNESS_HOME:-$HOME}}
#                     (GRID_DRY_HOME wins: it redirects every home-derived target)
# CODEX_HOME and PI_CODING_AGENT_DIR are deliberately not honoured; edit the row.
# An empty base is an error (exit 1), never a path under "/".
harness_path() {
  local v="$1" base
  base="${GRID_DRY_HOME:-${GRID_HARNESS_HOME:-${HOME:-}}}"
  # The quoted "~/..." patterns below match the LITERAL tilde of a registry value; they
  # are meant not to expand (SC2088), and quoting is what makes bash 3.2 treat them so.
  # shellcheck disable=SC2088
  case "$v" in
    -) printf '%s\n' "$v"; return 0 ;;
    "~/.config/"*)
      if [ -z "${GRID_DRY_HOME:-}" ] && [ -z "${GRID_HARNESS_HOME:-}" ] && [ -n "${XDG_CONFIG_HOME:-}" ]; then
        printf '%s/%s\n' "$XDG_CONFIG_HOME" "${v#"~/.config/"}"
        return 0
      fi ;;
  esac
  # shellcheck disable=SC2088
  case "$v" in
    "~/"*)
      if [ -z "$base" ]; then
        echo "harness_path: no home directory to expand '$v' against" >&2
        return 1
      fi
      printf '%s/%s\n' "$base" "${v#"~/"}" ;;
    *) printf '%s\n' "$v" ;;   # already absolute (or a future non-home value)
  esac
}
