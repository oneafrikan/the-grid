---
paths:
  - "**/*.sh"
  - "**/*.bash"
---
# Bash safety

## Shell options
- Add `set -u` so expanding an unset variable is an error and a non-interactive shell exits.
- Add `set -o pipefail` so a pipeline reports the rightmost non-zero status; by default only the last command counts.
- Check return values explicitly instead of relying on `set -e`; it does not exit for commands in `&&`/`||` lists, `if` conditions or `while` conditions.
- Replace `cmd1 && cmd2 || cmd3` with `if ... fi`; `cmd3` also runs when `cmd2` fails.

## Destructive commands
- Write `cd "$dir" || exit`; a failed `cd` otherwise leaves the script working in the wrong directory.
- Write `rm -rf "${dir:?}/"*`; with an empty `dir` the unguarded form deletes from `/`.
- Clean up temporary files with `trap 'rm -rf "$tmp"' EXIT`; single quotes defer expansion until the trap fires.

## Re-runnable scripts
- Use `mkdir -p`; an existing directory is ignored without error.
- Use `rm -f`; a missing file neither prints a diagnostic nor changes the exit status.
- Use `ln -sf`; it replaces an existing destination instead of failing.
