---
paths:
  - "**/*.sh"
  - "**/*.bash"
---
# Bash safety

## Shell options
- `set -u` makes expanding an unset variable an error, and a non-interactive shell exits.
- In a bash script, `set -o pipefail` makes a pipeline report the rightmost non-zero status; by default only the last command counts.
- Check return values explicitly; `set -e` does not exit for commands in `&&`/`||` lists, `if` conditions or `while` conditions.
- Replace `cmd1 && cmd2 || cmd3` with `if ... fi`; `cmd3` also runs when `cmd2` fails.

## Destructive commands
- Write `cd "$dir" || exit` (`|| return` in a function); a failed `cd` otherwise leaves the script working in the wrong directory.
- Write `rm -rf "${dir:?}/"*`; with an empty `dir` the unguarded form deletes from `/`.
- Quote a `trap` command in single quotes, not double; single quotes defer expansion until the trap fires.

## Re-runnable scripts
- Use `mkdir -p`; an existing directory is ignored without error.
- Use `rm -f`; a missing file neither prints a diagnostic nor changes the exit status.
