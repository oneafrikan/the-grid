# bash

Conventions for Bash scripts: quoting and syntax, safety (shell options, destructive commands,
re-runnable scripts) and portability to older Bash and non-GNU userland. Written for scripts
that start with `#!/bin/bash`; POSIX `sh`-only scripts are not the target.

## Scope

- `style.md` loads on `**/*.sh`, `**/*.bash` and `**/*.bats`; `safety.md` and `portability.md`
  load on `**/*.sh` and `**/*.bash`.
- Extensionless scripts with a shebang are not matched by the path globs, because path
  globs cannot see a shebang. Rules do not load when such a script is read or edited.
- `portability.md` bullets are conditional ("when a script must run on bash 3.2 ..."). The
  bash 3.2 floor is the version stock macOS has shipped as `/bin/bash`; that fact comes from
  the change brief, and none of the cited sources states it.

## Sources

| Rule file | Source |
|---|---|
| style.md | https://google.github.io/styleguide/shellguide.html https://www.shellcheck.net/wiki/SC2086 https://www.shellcheck.net/wiki/SC2053 https://www.shellcheck.net/wiki/SC2065 https://www.shellcheck.net/wiki/SC2162 https://www.shellcheck.net/wiki/SC2045 https://pubs.opengroup.org/onlinepubs/9799919799/utilities/echo.html |
| safety.md | https://www.gnu.org/software/bash/manual/bash.html https://google.github.io/styleguide/shellguide.html https://www.shellcheck.net/wiki/SC2015 https://www.shellcheck.net/wiki/SC2164 https://www.shellcheck.net/wiki/SC2115 https://www.shellcheck.net/wiki/SC2064 https://pubs.opengroup.org/onlinepubs/9799919799/utilities/mkdir.html https://pubs.opengroup.org/onlinepubs/9799919799/utilities/rm.html https://pubs.opengroup.org/onlinepubs/9799919799/utilities/ln.html |
| portability.md | https://cgit.git.savannah.gnu.org/cgit/bash.git/plain/NEWS https://pubs.opengroup.org/onlinepubs/9799919799/utilities/readlink.html https://pubs.opengroup.org/onlinepubs/9799919799/utilities/sed.html https://pubs.opengroup.org/onlinepubs/9799919799/utilities/command.html |
