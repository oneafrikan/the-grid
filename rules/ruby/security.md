---
paths:
  - "**/*.rb"
---
# Ruby security

- When the project uses Active Record, pass values to `where` as `?` placeholders or hash conditions; interpolating `params` into the SQL string is an SQL injection.
- Pass the command and each argument to `system` separately (`system("/bin/echo", arg)`); a single interpolated string goes through the shell, so user input can inject commands.
- Do not call `Marshal.load` on data from outside the application; it can deserialize almost any loaded class, which can lead to remote code execution.
- Parse YAML from outside the application with `YAML.safe_load`, not `YAML.unsafe_load`; the docs say `unsafe_load` must not be used on untrusted documents.
