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
#   harness_registry_rows_check validate every registry row's shape and paths; exit 1 + message
#   harness_path <value>        expand a registry path value (see below)
#   harness_registry_check      exit 2 when two rows share a rules_file
#   harness_rules_action <file> <active 0|1> <csv> [<raw>]
#                               what rules delivery should do for one instruction file
#   harness_rules_emit <rules_harness> <csv> <file> [--check]
#                               run `rules.py emit` for one instruction file
#
# HARNESS_REGISTRY overrides the registry file (tests), but ONLY together with
# GRID_ALLOW_REGISTRY=1 (the same convention as the test-only GRID_ALLOW_FILE=1): the
# registry decides where links are written, so a stray or planted variable alone must not
# redirect them. The default sits next to this file, so a mock GRID_DIR never needs its own copy.

_HARNESS_REGISTRY_DEFAULT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/harnesses.txt"
if [ "${GRID_ALLOW_REGISTRY:-}" = 1 ]; then
  HARNESS_REGISTRY="${HARNESS_REGISTRY:-$_HARNESS_REGISTRY_DEFAULT}"
else
  HARNESS_REGISTRY="$_HARNESS_REGISTRY_DEFAULT"
fi

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

# harness_registry_rows_check: every row must have exactly 6 columns, and skills_dir, agents_dir
# and rules_file must each be '-', an absolute path or '~/...' with no '..' component. wire.sh
# calls it before any write, so a malformed or hostile row exits 2 instead of steering a link
# (a short row used to reach harness_path with an empty value, a relative one landed under the
# cwd). Prints "harness registry: row '<name>': <problem>" to stderr and returns 1 on the first.
harness_registry_rows_check() {
  local name skills agents _target rules rharness extra col val
  while read -r name skills agents _target rules rharness extra; do
    if [ -z "$rharness" ] || [ -n "$extra" ]; then
      echo "harness registry: row '$name': expected 6 columns" >&2; return 1
    fi
    for col in "skills_dir:$skills" "agents_dir:$agents" "rules_file:$rules"; do
      val="${col#*:}"
      # The quoted "~/" is a LITERAL tilde of a registry value (SC2088 is the point).
      # shellcheck disable=SC2088
      case "$val" in
        -) ;;
        /*|"~/"*)
          case "/$val/" in
            */../*) echo "harness registry: row '$name': ${col%%:*} '$val' has a '..' component" >&2; return 1 ;;
          esac ;;
        *) echo "harness registry: row '$name': ${col%%:*} '$val' must be '-', absolute or ~/..." >&2; return 1 ;;
      esac
    done
  done < <(_harness_rows)
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
# An empty base is an error (exit 1), never a path under "/". A value with a '..'
# component is an error too, and XDG_CONFIG_HOME is honoured only when it is an absolute path
# (the XDG spec says a relative one must be ignored; it would land under the cwd).
harness_path() {
  local v="$1" base xdg="${XDG_CONFIG_HOME:-}"
  base="${GRID_DRY_HOME:-${GRID_HARNESS_HOME:-${HOME:-}}}"
  case "/$v/" in
    */../*) echo "harness_path: '$v' has a '..' component" >&2; return 1 ;;
  esac
  case "$xdg" in /*) ;; *) xdg="" ;; esac
  # The quoted "~/..." patterns below match the LITERAL tilde of a registry value; they
  # are meant not to expand (SC2088), and quoting is what makes bash 3.2 treat them so.
  # shellcheck disable=SC2088
  case "$v" in
    -) printf '%s\n' "$v"; return 0 ;;
    "~/.config/"*)
      if [ -z "${GRID_DRY_HOME:-}" ] && [ -z "${GRID_HARNESS_HOME:-}" ] && [ -n "$xdg" ]; then
        printf '%s/%s\n' "$xdg" "${v#"~/.config/"}"
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

# Rules delivery (multi-harness group 7). The decision is kept here, apart from the
# wire.sh step that acts on it, so the real run and `wire.sh --check` cannot disagree.
#
# The exact BEGIN line of the managed block. It must equal rules.py BLOCK_BEGIN (a test
# pins that): removal is only attempted for a file holding this COMPLETE line, so a user
# note that merely mentions the marker never triggers a call.
HARNESS_BLOCK_BEGIN='<!-- BEGIN the-grid rules (generated by scripts/rules.py; edits inside are overwritten) -->'

# harness_registry_check: exit 2 (message on stderr) when two registry rows name the same
# rules_file. One instruction file must belong to one harness: delivery decides per file
# from the first row, so a shared file would silently follow whichever row came first.
harness_registry_check() {
  _harness_rows | awk '
    $5 != "-" {
      if ($5 in seen) { print "harness registry: rules_file " $5 " is used by harnesses " seen[$5] " and " $1 > "/dev/stderr"; bad = 1 }
      else seen[$5] = $1
    }
    END { exit bad ? 2 : 0 }'
}

# harness_rules_action <file> <active 0|1> <csv> [<raw registry value>]   prints one word:
#   emit                        deliver <csv> (active harness, packs wired, regular file)
#   remove                      take a previous block out (everything else that holds one)
#   skip:rules-file-absent      active + packs wired, but the operator has not created the file
#   skip:rules-file-symlink     active + packs wired, but the file is a symlink (never written through)
#   skip:rules-file-not-regular active + packs wired, but the path is a dir or special file
#   skip:rules-file-not-allowed active + packs wired, but the registry row is not a ~/-relative
#                               AGENTS.md / GEMINI.md / CLAUDE.md (never a shell rc or other file)
#   none                        nothing to do
# The grid never creates an instruction file: the operator opts in by creating a regular
# file (even an empty one). Removal is only ever attempted when the exact BEGIN line is
# already in the file, so an operator's empty opt-in file with no block is never touched
# (rules.py itself keeps a file that removal leaves empty, truncated to 0 bytes).
# <raw> is optional; callers that pass it get the not-allowed check.
harness_rules_action() {
  local file="$1" active="$2" csv="$3" raw="${4:-}" allowed=1
  if [ -n "$raw" ]; then
    # shellcheck disable=SC2088
    case "$raw" in "~/"*) ;; *) allowed=0 ;; esac
    case "${raw##*/}" in AGENTS.md|GEMINI.md|CLAUDE.md) ;; *) allowed=0 ;; esac
  fi
  if [ "$active" = 1 ] && [ -n "$csv" ]; then
    if [ "$allowed" = 0 ]; then echo "skip:rules-file-not-allowed"
    elif [ -L "$file" ]; then echo "skip:rules-file-symlink"
    elif [ -f "$file" ]; then echo "emit"
    elif [ -e "$file" ]; then echo "skip:rules-file-not-regular"
    else echo "skip:rules-file-absent"
    fi
    return 0
  fi
  # -f and not -L: a symlinked file is never edited, not even to remove a block. -x anchors
  # the match to the whole line and -F keeps it literal; the second -e is the CRLF form.
  if [ "$allowed" = 1 ] && [ -f "$file" ] && [ ! -L "$file" ] \
     && grep -qxF -e "$HARNESS_BLOCK_BEGIN" -e "$HARNESS_BLOCK_BEGIN"$'\r' -- "$file" 2>/dev/null; then
    echo "remove"
  else
    echo "none"
  fi
}

# harness_skip_text <reason>: the operator-facing wording for a `skip:<reason>` action.
harness_skip_text() {
  case "$1" in
    rules-file-absent) echo "file does not exist (create it to opt in)" ;;
    rules-file-symlink) echo "file is a symlink (never written through)" ;;
    rules-file-not-regular) echo "path is not a regular file" ;;
    rules-file-not-allowed) echo "registry row is not an instruction file the grid may write" ;;
    *) echo "$1" ;;
  esac
}

# harness_rules_emit <rules_harness> <csv> <file> [--check]: the one place rules.py is
# called. rules.py sits next to lib/ (scripts/rules.py); --root points it at the grid whose
# rules/ it renders (GRID_DIR, set by wire.sh). An empty <csv> is the empty selection, which
# removes a previous block. rules.py exits 0 done / no drift, 1 drift (--check only), 2 refused,
# 3 block over the cap (nothing written); the caller reads the code, so it passes through.
harness_rules_emit() {
  python3 "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/rules.py" emit \
    --root "$GRID_DIR" --harness "$1" --packs "$2" --out "$3" ${4:+"$4"}
}
