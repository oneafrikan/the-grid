# hooks/

Claude Code hooks that ship with the-grid. Shell scripts, zero model calls, one
launcher, one catalogue.

> **Status.** Built so far: the launcher, the catalogue, the two guard hooks, the
> auto-handoff hook with its worker (below), and the project emitter. To opt a project
> in, set `hooks: {profile: standard}` in its `.grid/project.yaml` and run
> `agent-factory/.venv/bin/python agent-factory/deploy_hooks.py <project>`
> (`--list` shows every hook's cost; `--check` reports drift). `scripts/wire.sh` wires
> auto-handoff into the user settings (`deploy_hooks.py --user`, see below).

**These guards are a mistake-catcher, not a security boundary.** They stop an agent
from tripping over the common ways of skipping git's safety nets. A determined process
can still get around them (see "Known gaps").

## Project profiles

A project picks one profile; each profile includes everything below it. Guard hooks
only.

| Profile | Adds | Model calls | Tokens |
|---|---|---|---|
| `off` | nothing | no | 0 |
| `minimal` | `pre-bash-no-bypass` | no | 0 (about 60 tokens of stderr only when it blocks) |
| `standard` | `pre-bash-secret-scan` | no | 0 (a short file:line list only when it blocks) |
| `strict` | nothing yet (same set as `standard`) | no | 0 |

## Hooks and their cost

| Hook | Event / matcher | Fails | What it does | Cost |
|---|---|---|---|---|
| `pre-bash-no-bypass` | PreToolUse / Bash | closed | Blocks `--no-verify` (any git subcommand), `git commit -n`, `-c core.hooksPath=`, `git config` writes of `core.hooksPath` or of an alias hiding `--no-verify`/`-n`, the `GIT_CONFIG_COUNT` / `GIT_CONFIG_PARAMETERS` / `GIT_CONFIG_KEY_*` / `HUSKY=0` assignments, and force pushes (`--force`, `--mirror`, `+refspec`, `-f` clusters). `--force-with-lease` is allowed. | 0 tokens; about 50 ms per Bash call (measured on one Linux box); about 60 tokens only when it blocks |
| `pre-bash-secret-scan` | PreToolUse / Bash | closed | On `git commit`: scans the added lines of the staged diff (and of the working tree when the commit names paths or uses `-a`/`-i`/`-o`) for secret patterns, and blocks sensitive file names. On `git add`: blocks sensitive file names. | 0 tokens; about 60 ms per Bash call (measured on one Linux box), more only for a `git commit` or `git add` that scans a diff; a short file:line list only when it blocks |
| `instincts-capture-tool` | PostToolUse / Bash, Edit, Write, MultiEdit, NotebookEdit | open | Opt-in (`learning: on`). Appends one scrubbed line (tool, summarised input) to a local file. | 0 tokens; about 30 ms per tool call; prints nothing |
| `instincts-capture-failure` | PostToolUseFailure / same tools | open | Opt-in. Same, for a failed tool call, with an error flag. | 0 tokens; about 30 ms per failed call; prints nothing |
| `instincts-capture-prompt` | UserPromptSubmit | open | Opt-in. Appends one scrubbed, truncated line per prompt to a local file. | 0 tokens; about 30 ms per prompt; prints nothing |
| `instincts-inject` | SessionStart | open | Opt-in. Prints the project's learned habit hints into the session. | 0 tokens to run; about 100 to 300 tokens of hints when instincts exist, nothing otherwise |
| `auto-handoff` | SessionEnd | open | Writes a handoff with the real `/handoff` skill when a session of 5+ human turns did not run one. Machine-level, not a project profile. | One Sonnet run per qualifying session; capped by `--max-budget-usd 1.00`, `--max-turns 25` and a 900 s wall clock |

The machine-readable version of this table is `catalogue.json` (the only place scope,
profile and cost are defined). Every entry has a non-empty `cost`.

**Opt-in hooks (`instincts-*`).** These four are in no profile. A project turns them on
with a top-level `learning: on` in its `.grid/project.yaml` (the YAML `true` works too),
and `deploy_hooks.py` then emits them under every profile, including `off`. Setting the
flag back to off and re-running removes exactly those four entries. In the catalogue they
carry `"opt_in": "learning"` in place of `min_profile`, and `--list` shows `opt-in:learning`
in the profile column. What is captured, where it goes and how to forget it:
`docs/instincts.md`.

## How it fits together

```
settings.json  ->  bash ".../hooks/run.sh" <id>   ->   hooks/scripts/<id>.sh
                     (id check, kill switches)          (sources hooks/lib/*.sh)
```

- `run.sh <id>` rejects an id that is not `[a-z0-9-]+` (exit 2), honours the kill
  switches, then rejects a well-formed id that has no `scripts/<id>.sh` (exit 2), then
  runs the script with stdin passed through. The kill switches come before the
  script check, so a stale settings entry for a removed hook can still be switched
  off. It needs no `jq`, so it behaves on a machine without it.
- `lib/common.sh` holds the `jq` guard, the log helper and the shell-command tokenizer
  (`grid_git_segments`) both guards use.
- `lib/secret-patterns.sh` holds the one secret-pattern table.

## Calling a hook

```json
{ "hooks": { "PreToolUse": [ { "matcher": "Bash", "hooks": [
  { "type": "command", "timeout": 5,
    "command": "bash \"${GRID_DIR:-$HOME/.the-grid}/hooks/run.sh\" pre-bash-no-bypass" } ] } ] } }
```

## Environment variables

Both are read by `run.sh` from the environment of the shell that launched `claude`;
no re-emit is needed.

| Variable | Effect |
|---|---|
| `GRID_HOOKS=off` | every the-grid hook exits 0 immediately |
| `GRID_DISABLED_HOOKS=id,id` | the named hooks exit 0 (for example `GRID_DISABLED_HOOKS=pre-bash-secret-scan`) |

A blocked command names the matching `GRID_DISABLED_HOOKS=<id>` line in its message.
That is the human override; there is deliberately no in-command override an agent could
add to its own command.

Tuning (read by the two guards; defaults are fine for normal use):

| Variable | Default | Effect |
|---|---|---|
| `GRID_GUARD_MAX_CMD` | 20000 | bytes, counted on the text with quotes removed; a command over this size that mentions git is blocked ("command too long to inspect"), because a guard that cannot finish inside its 5 s timeout silently stops guarding |
| `GRID_GUARD_MAX_TOKENS` | 2500 | blanks and separators in the command (cost follows token count as much as size); the same block when over |
| `GRID_GUARD_MAX_GIT_CALLS` | 40 | secret scan only: git calls that need a repository check (plain ones such as `git status` are free); more than this blocks with the same message |
| `GRID_SCAN_MAX_LINES` | 1000 | secret scan only: more candidate lines (lines some pattern could match) than this blocks with "diff too large to scan; split the commit" |
| `GRID_SCAN_MAX_FILES` | 500 | secret scan only: a `git add ... && git commit` in one command that would stage more files than this blocks with "stage in a separate call so the scan can see it" |
| `GRID_SCAN_MAX_BYTES` | 5242880 | secret scan only: the same block when the files the add would stage hold more bytes than this |

## Timeouts

Claude Code treats a hook that times out as non-blocking, so a slow guard is an
absent guard. Both guards therefore keep their work bounded: the tokenizer is linear in
the command size, an oversized or token-dense command is refused instead of scanned, the
secret scan refuses a diff it cannot read inside its budget, and a candidate line over
256 KB blocks as `oversize-line`. Both catalogue entries carry
`"on_failure": "block"`, which `deploy_hooks.py` emits as `"onFailure": "block"` in the
generated handler so Claude Code itself blocks when the guard fails or times out.
Claude Code 2.1.295 or later is a hard requirement for that guarantee: an older version
ignores the field (a timed-out guard then lets the command through) or rejects the
settings entry. Settings written to a project's shared file (`settings.json`) carry the
field for every teammate, including one without the-grid installed: for them a missing
`run.sh` (exit 127) blocks every Bash call until the entry is removed or `GRID_HOOKS=off`
is set, so prefer the local settings target for a team that does not all use the-grid.

## Auto-handoff (SessionEnd, machine-level)

What it does: when a session ends, a detached worker checks whether the session was
worth a handoff and, if so, runs the real `/handoff` skill headless (`claude -p`) over a
compact digest of the transcript, then commits the two handoff files itself. It is a
machine-level hook, on by default wherever it is wired, and independent of project
profiles. The hook returns in well under a second; the worker runs in its own session.

**Wiring.** `scripts/wire.sh` adds one generated SessionEnd entry to
`${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json` (`deploy_hooks.py --user`; absolute
path to this checkout's `hooks/run.sh`), leaving every hand-written hook and key alone.
Running `wire.sh` again changes nothing; `wire.sh --check` reports a missing entry and
exits 1. A symlinked settings file or config dir is refused (a warning from `wire.sh`).

**Opting out.** Per machine: put `-hook:auto-handoff` in the machine's manifest overlay
(re-enable with `hook:auto-handoff`). Per session: start `claude` with
`GRID_DISABLED_HOOKS=auto-handoff` (or `GRID_HOOKS=off` for every hook).

**When it runs.** It skips, and logs why, when:

- the transcript is unreadable (`no-transcript`);
- a handoff already ran in the session (`already-ran`: the `/handoff` command, a `Skill`
  call for `handoff`, or a written `*-handoff.md` file);
- the session has fewer than `GRID_AUTOHANDOFF_MIN_TURNS` human turns (`short-session`);
- the same session was already handed off and gained fewer than that many turns since
  (`no-new-turns`).

Only real human turns count: tool results, meta lines, attachments and subagent
(sidechain) lines do not.

**Cost.** One Sonnet run per qualifying session. Bounds: `--max-budget-usd`
(`GRID_AUTOHANDOFF_MAX_USD`, default 1.00; it may not bind on a subscription plan),
`--max-turns 25`, and a wall-clock alarm (`GRID_AUTOHANDOFF_TIMEOUT`, default 900 s).
Every run is in the log and in the run record (`scripts/run-record.sh`, role
`auto-handoff`).

**The child can only write.** It runs in the session's directory with
`--tools Read,Write,Bash`, in default permission mode (no `--permission-mode` flag).
Write access is path-scoped allow rules, `Edit(//<abs dir>/**)`, for the handoff target
directory and the fallback directory only; `Edit` itself and `Bash(git:*)` are denied,
and Bash is limited to `hostname`, `realpath`, `readlink`, `ls` and `date`. A system
prompt (`lib/auto-handoff-system.md`) tells it to write only the two files and run no
git. The target directory is resolved the way the handoff skill resolves it: the first
matching row of `~/.the-grid-private/handoff-locations.md`, else an existing `logs`
directory of the session's directory in any casing. If it does not exist the child
writes to the fallback directory instead.

**What the worker does after the child.** It never trusts the model's side effects:

1. A changed `.git/config` or `.git/hooks/` (snapshotted before, compared after) is
   `unexpected-file`: no commit, changed paths logged, nothing moved.
2. Every new file under the session's directory (any depth, `.git/` excluded), the
   fallback directory and the target directory is collected. Exactly one
   `<p>-handoff.md` and at most one `<p>-context.md` with the same prefix, in the target
   or fallback directory, are expected. Anything else is `unexpected-file` (no commit,
   every path logged, nothing moved or deleted); no handoff file at all is
   `no-handoff-file`.
3. Both files are scanned with the secret table (`lib/secret-patterns.sh`), whatever the
   project profile says. A hit is `secret`: both files move to
   `${GRID_STATE_DIR:-$HOME/.grid}/handoff-quarantine/<session>/` (outside every repo),
   nothing is committed, and only names and line numbers are logged. Review and delete
   them.
4. The pair is committed by explicit path in the repository that holds the real files, so
   the operator's other staged work is not swept in. Outside any repository the files
   stay on disk (`commit=none`). A failed commit is `commit-failed`.
5. It pushes only when that repository is the private repo
   (`${GRID_PRIVATE_DIR:-$HOME/.the-grid-private}`), its branch has an upstream, and the
   handoff commit is the only unpushed one. A plain `git push`, nothing else.

**Fallback directory.**
`${GRID_HANDOFF_FALLBACK_DIR:-${GRID_PRIVATE_DIR:-$HOME/.the-grid-private}/handoffs}/<basename of the session directory>/`.
The worker creates it first.

**Environment knobs** (all optional):

| Variable | Default | Meaning |
|---|---|---|
| `GRID_AUTOHANDOFF_MIN_TURNS` | 5 | human turns needed (and needed again to hand off a resumed session) |
| `GRID_AUTOHANDOFF_MAX_BYTES` | 300000 | digest size cap (the middle is elided past it) |
| `GRID_AUTOHANDOFF_TIMEOUT` | 900 | seconds before the child is killed (`reason=timeout`) |
| `GRID_AUTOHANDOFF_MAX_USD` | 1.00 | `--max-budget-usd` for the child |
| `GRID_AUTOHANDOFF_FORCE` | unset | `1` skips the already-ran, short-session and marker checks (parity runs, tests) |
| `GRID_HANDOFF_FALLBACK_DIR` | see above | where a handoff lands when the target directory is missing or denied |
| `GRID_PRIVATE_DIR` | `~/.the-grid-private` | the one repo the worker may push |
| `GRID_CLAUDE` | `claude` | the binary the worker runs (tests point it at a stub) |
| `GRID_HOOK_LOG_DIR` | `~/.grid/hook-logs` | log directory (mode 0700) |
| `GRID_HOOK_STATE_DIR` | `~/.grid/hook-state` | per-session marker directory |
| `GRID_STATE_DIR` | `~/.grid` | root of the secret quarantine |

`GRID_AUTOHANDOFF_CHILD` is internal: the worker sets it for the child so the child's own
SessionEnd hook does nothing.

**Reading the log.** `${GRID_HOOK_LOG_DIR:-$HOME/.grid/hook-logs}/auto-handoff.log`, one
line per decision:

```
ts=<UTC time> session=<id> action=<skip|spawn|done|error> reason=<token> [turns=N] [commit=<none|sha>] [push=<token>] [paths=...]
```

- `action=skip`: `bad-payload`, `no-transcript`, `already-ran`, `short-session`,
  `no-new-turns`.
- `action=spawn reason=ok`: the child started (`end=` is the SessionEnd reason).
- `action=done reason=ok`: the files were written and checked; `commit=` is `none` or the
  short sha.
- `action=error`: `timeout`, `claude-exit-<n>` (127 means the binary could not be run),
  `no-handoff-file`, `unexpected-file` (see `paths=`), `secret`, `commit-failed`,
  `digest-failed`.
- `push=`: `yes`; `no-not-private` (not the private repo); `no-upstream`;
  `no-other-commits` (an earlier unpushed commit exists, so nothing was sent); `failed`
  (the commit stays local).
- Lines starting `child|` are the child's own output, cut to 4000 bytes.

**Claude Code facts this is built on** (Claude Code **2.1.296**, captured 2026-10-11,
`tests/fixtures/hooks/README.md`; re-check after an upgrade):

- `SessionEnd` fires under `-p`, and headless `/handoff` works with
  `--tools Read,Write,Bash`; no further tool is needed.
- Accepted flags: `--allowedTools`, `--disallowedTools`, `--tools`, `--add-dir`,
  `--append-system-prompt-file`, `--max-budget-usd` and `--max-turns`. `--max-turns` is
  missing from `claude --help`; that it is accepted was observed, and the limit when
  reached was not tested.
- `Write(...)` allow rules are not enforced and `acceptEdits` ignores allow rules, while
  `Edit(//<abs>/**)` rules in default mode are enforced (a write outside the allowed
  directories is denied). That is why the child runs in default mode with `Edit` rules.
- A compound Bash call (a `;` or `&&` chain) is denied, so the child is told to run single
  commands.

## Exit codes (Claude Code's rule)

- Only exit **2** blocks a `PreToolUse` call; the stderr text is shown to the agent.
- Any other non-zero exit, including **127** ("command not found", for example a
  missing `run.sh`), is normally a visible, non-blocking error. The two guards are emitted
  with `"onFailure": "block"` (Claude Code 2.1.295 or later), which turns a failure to
  start, a timeout and any exit other than 0 into a block. So a missing `run.sh` now blocks
  every Bash call: the guard fails closed instead of silently turning off. The way out is
  `GRID_HOOKS=off` (or removing the entry); see "Timeouts" for the shared-settings
  consequence.
- The one failure inside our control that would otherwise turn a guard into a silent
  no-op is a missing `jq`, so the guards exit 2 when `jq` is absent. That blocks every
  Bash call (not only git) until `jq` is installed, or until `claude` is restarted with
  `GRID_HOOKS=off`; the message says so.
- Both guards exit 0 on input that is not JSON, a tool other than Bash, or no command.

## Adding a hook

1. Write `hooks/scripts/<id>.sh` (`<id>` is lowercase letters, digits and hyphens). Source
   `lib/common.sh`, call `grid_require_jq closed` (a guard) or `open` (a background hook),
   and comment the script.
2. Add one entry to `catalogue.json`: `id`, `scope` (`project` or `user`), `event`,
   `matcher` (omit for events without one), `min_profile` or `"opt_in": "learning"` (project
   hooks only, exactly one of them; `opt_in` hooks are emitted by the project flag, not a profile), `fail`
   (`closed` or `open`), `timeout`, `model_cost`, a non-empty `cost`, and `description`.
   A guard also sets `"on_failure": "block"` (see "Timeouts").
3. Add tests to `tests/test_hooks.bats`. The suite fails if a catalogue id has no script,
   a script has no catalogue entry, or a `cost` is empty.
4. The gate runs `shellcheck -S warning` over `hooks/*.sh`, `hooks/lib/*.sh` and
   `hooks/scripts/*.sh`. Keep the scripts to bash, `jq` and POSIX tools.

Nothing under `hooks/` may use network tools or URLs: the vetting audit
(`python3 scripts/audit.py --root . hooks`) treats a hook that talks to the network as a
high-severity finding.

## Known gaps

The guards do not inspect:

- shell aliases and functions (a function body is read where it is defined, not where it
  is called),
- scripts that call git,
- variables expanded at run time (`$CMD`),
- `git -c alias.x=...` one-shot aliases,
- a bash/sh/eval payload nested more than one level deep (`bash -c "bash -c '...'"`),
- ANSI-C escape decoding (`$'\x2d\x2dno-verify'`) and names spliced from `${x}`,
- other shell expansions that build a word: brace expansion (`{git,commit,-n}`,
  `--no-{verify,x}`), pathname globs in a command word (`/usr/bin/g?t commit -n`), and
  `${x}` / `$((..))` results,
- a heredoc fed to something that is not named as a shell (`ssh host <<EOF`, a script that
  reads stdin): the body is data to the guard,
- `cp`, `ln -sf`, `dd`, `install`, `unlink` and `find -delete` are read as writers, but a
  hook file changed by a program the guard does not know (a script, `git` itself via
  `core.hooksPath`) is not,
- writes made with the Write, Edit or MultiEdit tools (a hook script or `.git/config`
  edited that way is out of scope; only Bash commands are read).

Where a git call is looked for: every word of a command segment that is `git` (any letter
case, any path prefix) starts a git call, so `if ...; then git ...; fi`, `( git ... )`,
`{ git ...; }`, `! git`, `timeout 5 git ...`, `nohup`, `setsid`, `env -u X`, `find -exec`,
`>/dev/null git ...`, `$(git ...)` and backticks are all read, including `$( )` and
backticks inside double quotes (`echo "$(git push --force)"`); the commands inside such a
substitution are checked as their own segments, after the outer command.
`bash|sh|zsh|dash|ksh|busybox -c`, `eval` and `env -S` payloads are re-read once.
Parentheses end a segment and a word-initial `#` starts a comment, so `git commit # -n` is
just `git commit`. A backslash-newline joins a word (`git commit --no-\<newline>verify` is
`--no-verify`).

Quote state is tracked so that one quote cannot hide a later command: a heredoc body is
data, not code, for quote tracking; `$'..'` strings end at an unescaped `'`; `$( )` inside
double quotes has its own quotes. A heredoc body is read as code only when the heredoc
feeds a shell (`bash <<EOF`) or when a body line holds `$(` or a backtick under an unquoted
delimiter (the shell would run it); other body lines are skipped, so a commit message that
says "git push --force" does not block. If a quote or substitution is still open at the
end of the command, the guard blocks with "a quote or substitution in this command is not
closed": it cannot tell where later commands start, so it fails closed.

Accepted false blocks (a mistake-catcher errs towards blocking):

- any word that is `git` starts a git call, so `echo git commit -n` blocks,
- `HUSKY=0 npm ci` and `echo HUSKY=0` block (the assignment is the signal, not the command),
- `git config core.hooksPath <dir>` blocks even when the directory is a legitimate hooks dir,
- an unclosed quote or substitution blocks (see above), even in a command that is only an
  unfinished one-liner.

Hook-disabling routes that are blocked: `-c` / `--config-env` with a hooksPath key,
`GIT_CONFIG_*`, `GIT_DIR`, `GIT_WORK_TREE`, `GIT_EXEC_PATH` and `GIT_TEMPLATE_DIR`
assignments, `HUSKY=0`, `HUSKY_SKIP_HOOKS`, `LEFTHOOK=0`, `LEFTHOOK_EXCLUDE`,
`PRE_COMMIT_ALLOW_NO_CONFIG`, `git config --unset[-all]` / `unset` of hooksPath, `git
config set` of hooksPath, `include.path` and `includeIf.*.path` set through `-c`,
`--config-env` or `git config` (an included file can set hooksPath), and a redirect, `tee`,
`truncate`, `chmod`, `rm`, `mv`, `cp`, `ln`, `install`, `dd`, `unlink`, `find -delete` or
`sed -i` / `perl -pi` that names `.git/config`, `.git/hooks` or `.githooks`. A bare `SKIP=...` is not
matched. Anyone who must edit those files by shell uses the kill switch above.

How flag words are read: quotes and backslashes are removed the way the shell removes
them, so `"--no-verify"`, `\--no-verify` and `--no-ver""ify` are all `--no-verify`. The
value word of an option such as `-m`, `--message` or `--author` is skipped, which keeps a
commit message that only mentions a flag from blocking. A flag-looking word that is the
value of an option the guard does not list (`git log --grep "--no-verify"`) is blocked:
a known, accepted false positive. git accepts any unique prefix of a long option, so
`--no-verify` is blocked from 7 characters (`--no-ve`) and `git push --mirror` from 4
(`--mi`); `--force` has no valid abbreviation.

The secret scan covers the patterns in `lib/secret-patterns.sh` and nothing else: no
entropy scoring, no token split over several lines, and an unquoted assigned value that
is made only of letters is not flagged (an assignment value counts when it is quoted and
16+ characters, or unquoted, 16+ characters, with a digit and no parentheses; a value
that starts with `$`, `<` or `{` is a template and is skipped). A match is passed over
when the matched token itself holds a placeholder word such as `example` or `changeme`;
a placeholder word elsewhere on the line does not exempt a real token. What it reads for
a command:

- the repository the command targets: `-C <dir>`, `--git-dir`, `--work-tree` and a
  preceding `cd <dir>` are followed (a `cd` that cannot be known, such as `cd $VAR`, falls
  back to the payload's `cwd`; the `cwd` repo is also scanned after any `cd`),
- the staged diff for `git commit`, `commit-tree`, `merge`, `cherry-pick`, `revert`, `am`,
  `rebase` and a git alias for `commit`; the working-tree diff too for `-a`, `-i`, `-o`,
  `-p`, `--interactive`, `--pathspec-from-file` or named pathspecs,
- files git calls binary (a NUL byte, UTF-16, a path an attribute marks `-diff`): the diff
  is read with `--text` and NUL bytes are dropped, so UTF-16 text is matched as text,
- a `git add ... && git commit` in one command: the add has not run when the hook runs, so
  the files the add would stage are listed (`git status` for its pathspecs) and read from
  the working tree. `git add -f` of an ignored file is not listed (the literal name is still
  checked),
- the text of a commit command, which covers the message and a same-command
  `echo key=... >> file && git commit -am x`.

Not covered: `git commit -F <file>` (the message file), a secret split across lines or
encoded, and anything git does not show as an added line. Names in the block message are
cut at 100 characters and control characters are shown as `?`, so a hostile file name
cannot inject text into the agent's view.

## Other harnesses

The scripts read the Claude Code `PreToolUse` payload (`tool_name`, `tool_input.command`,
`cwd`) on stdin. That is the only seam; another harness would need an adapter that
produces the same JSON. Nothing here is built for one (see the `multi-harness` change).
