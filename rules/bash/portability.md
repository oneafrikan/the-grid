---
paths:
  - "**/*.sh"
  - "**/*.bash"
---
# Bash portability

## When a script must run on bash 3.2
- Avoid `mapfile` and `readarray`; both arrived in bash 4.0.
- Avoid `declare -A`; associative arrays arrived in bash 4.0.
- Avoid `${var^^}` and `${var,,}`; case-modifying expansions arrived in bash 4.0.
- Avoid `[[ -v var ]]`; the `-v` test arrived in bash 4.2.
- Avoid `printf '%(%Y-%m-%d)T'`; the `%(fmt)T` specifier arrived in bash 4.2.

## When a script must run without GNU userland
- Avoid `readlink -f`; POSIX specifies `readlink` with only the `-n` option.
- Avoid `sed -i`; POSIX `sed` has no in-place option.
- Test for a tool with `command -v tool`; POSIX defines its output and a non-zero exit status when the name is not found.
