---
paths:
  - "**/*.sh"
  - "**/*.bash"
  - "**/*.bats"
---
# Bash style

- Quote expansions (`"$var"`, `"$(cmd)"`) unless careful unquoted expansion is required or the value is a shell-internal integer; unquoted values word-split and glob.
- Forward arguments with `"$@"`, not `$*`, which merges them into one word.
- In a bash script, store a list of arguments in an array (`args=(-a -b)`, `"${args[@]}"`); a quoted string will not split into words.
- In a bash script, quote the right side of `==` in `[[ ]]` (`[[ $a == "$b" ]]`); unquoted, it is treated as a glob.
- In a bash script, use `(( ))` for numeric tests; `>` inside `[ ]` is an output redirection.
- Use `IFS= read -r line`; `read` without `-r` mangles backslashes.
- Print values with `printf '%s\n' "$var"`, not `echo`; POSIX says `echo` is not portable for values that start with `-` or contain escapes.
- Expand wildcards as `./*`, not `*`, because filenames can begin with `-`.
- Loop over files with `for f in ./*.txt`, never `for f in $(ls)`, which splits on whitespace; in bash, start the body with `[[ -e "$f" ]] || break` so an unmatched glob does not run the loop once with the literal pattern.
- In a bash script, feed a `while read` loop with `< <(cmd)` instead of a pipe; a piped loop runs in a subshell and loses its variable changes.
- Declare function variables with `local`, and assign command output in a separate statement (`local x`, then `x=$(cmd)`); `local x=$(cmd)` hides the exit status.
