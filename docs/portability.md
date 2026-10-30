# Portability: Linux and macOS

Both platforms are supported. The Linux gate (GNU userland, bash 4/5, `.github/workflows/tests.yml`) is authoritative. macOS (`/bin/bash` 3.2.57, BSD userland, python 3.9, case-insensitive APFS) is expected near-green. A regression on either side is a bug.

- Work done on one platform must follow these rules so the other does not break.
- Applies to `tests/`, `scripts/`, `hooks/`, and any python they call.
- Why it exists: PR #301 took the suite on macOS from 194 failures to 1; every item below was a real failure.

## Use these helpers

| Helper | Where | Use |
|---|---|---|
| `file_mode PATH` | `tests/helpers/portable.bash` | octal mode on GNU and BSD: `[ "$(file_mode "$f")" = 600 ]` |
| `sed_i ARGS... FILE` | `tests/helpers/portable.bash` | in-place edit (`-i.bak`, backup removed): `sed_i 's/a/b/' "$f"` (FILE last) |
| `mktemp_canon [ARGS]` | `tests/helpers/setup.bash` (loaded by `common_setup`) | canonical temp dir (`/private/var`, not `/var`): `d=$(mktemp_canon)` |
| `ensure_timeout` | `tests/helpers/setup.bash` | called by `common_setup`; puts an executable `timeout` on PATH when the box has none |

- Load the portable helpers per file: `load helpers/portable` (next to the existing `load helpers/setup`).
- Do not define your own `timeout` in a test. Product scripts call `exec timeout` / `env -i timeout`, which bypass shell functions: it must be an executable on PATH. `ensure_timeout` is a no-op where a real `timeout` or `gtimeout` exists.

## Avoid

| Construct | Why it breaks | Use instead |
|---|---|---|
| `coproc` | bash 4+ only | background process + `mkfifo`; see `test_knowledge_sweep.bats` |
| `grep -P` | BSD grep has no PCRE | `grep -E` with `[^[:alnum:]_-]` boundaries (no `\Q..\E`: escape the value or use `-F`) |
| `stat -c %a` / `%s` | GNU only | `file_mode`; size: `wc -c < f \| tr -d ' '` |
| `${lines[-1]}`, negative array subscripts | bash 4.2+ | `${lines[$((${#lines[@]}-1))]}` |
| bare `mktemp` / `mktemp -d` where TMPDIR matters | BSD ignores `TMPDIR` without a template | `mktemp -d "${TMPDIR:-/tmp}/name.XXXXXX"` |
| `timeout` as a shell function | `exec timeout`, `env -i timeout` skip functions; macOS has no GNU `timeout` | executable on PATH (`ensure_timeout`) |
| `sed -i 's/a/b/' f` | BSD needs a suffix argument | `sed_i` |
| `find -printf` | GNU only | `find ... -exec stat`, or a `while read` loop |
| `paste -sd, ` with no file | BSD needs `-` for stdin | `paste -sd, -` |
| `head -c 0` | BSD: "illegal byte count" | guard: `[ "$n" -gt 0 ] \|\| return 0` |
| `wc -l` output compared as a bare number | BSD pads with spaces | `$(wc -l < f \| tr -d ' ')` |
| `${s//pattern/}` in a loop on a large string | quadratic on bash 3.2 (25 to 70 s on 14 KB; a timed-out hook does not block) | slice into 256-byte chunks; see `_grid_unquote` in `hooks/lib/common.sh` |
| `${c//$'\\\n'/}` | does not match backslash-newline on bash 3.2 (guard failed open) | `${c//\\$'\n'/}` |
| `EPOCHREALTIME` | absent in 3.2; falls back to `SECONDS*1e6` (0 in a fresh shell) | do not assume microsecond clocks; tests use `SECRET_DEADLINE_US=0` not `1` |
| quoted inline JSON in `"$(...)"` | 3.2 splits it at commas | build the JSON in python (`file_payload` in `test_instincts_capture.bats`) |
| `local IFS=:` plus `"${a[@]:$n:$k}"` | 3.2 joins the slice into one word | scope IFS to the `read` (`IFS=: read -r -a ...`) |
| `mkdir Logs` beside `LOGS` | APFS is case-insensitive: no-op or overwrite | two-step `mv x x.tmp && mv x.tmp X`; or probe and skip |
| comparing `$BATS_TEST_TMPDIR` / `mktemp -d` to a canonical path | `/var` -> `/private/var` | `pwd -P` or `mktemp_canon` |
| `X \| None` annotations in python | evaluated at def time on 3.9 | `from __future__ import annotations` at the top |
| `match` statements, newer-stdlib calls | python 3.8/3.9 on macOS | `if/elif`; check the docs for the minimum version |
| relying on the `int` digit limit | 3.11+ only; 3.9 parses any length | enforce the limit yourself (`miniyaml.py`) |
| `readlink -f` | worked on macOS 26, not guaranteed on older | `cd "$d" && pwd -P` |
| other GNU-only flags (e.g. `date -d`, `cmp -n` at exact file length) | BSD differs | prefer POSIX options; try the tool on a Mac |

## Running tests

One file, with the repo's bats (a macOS check must use the system bash):

```bash
tests/lib/bats-core/bin/bats tests/test_hooks.bats              # whichever bash is first on PATH
/bin/bash tests/lib/bats-core/bin/bats tests/test_hooks.bats    # macOS: bash 3.2, the target that breaks
```

Full suite takes 10+ minutes: run it in the background. `bash scripts/gate.sh` runs the whole commit gate.

## Check on the other platform before pushing

- Linux dev: run the touched `.bats` files under `/bin/bash` 3.2 if a Mac is reachable. If not, say "UNTESTED on macOS" in the PR. A macOS CI job exists only if the operator has added one (see `docs/handoffs/` while PR #301 is open).
- Mac dev: the full gate runs on Linux in CI; read the CI result before calling a PR done.
- Pre-commit hook caveat: `.githooks/pre-commit` runs the whole gate. It was red on macOS before PR #301 (shellcheck was unavailable there and several tests failed). If it is still red for a cause you can name, `GRID_SKIP_HOOK=1` bypasses it. Say so in the commit message.

## When a test is genuinely platform-specific

- Probe the capability, do not test `uname`: e.g. NBSP in `test_hooks.bats` (macOS libc counts it as `[[:space:]]`, glibc does not), case-folding in `test_rules.bats` (`[ -e README.md ]` after writing `readme.md`).
- Skip with a reason: `skip "case-insensitive file system cannot hold readme.md beside README.md"`.
- Never weaken the assertion for everyone. The other platform must still run the full test.
- Check the skip still fires only where intended (Linux runs it, macOS skips it).
- A skip that hides a product defect gets a GitHub issue (NBSP: #302).
