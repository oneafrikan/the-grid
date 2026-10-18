# hooks/

Claude Code hooks that ship with the-grid. Shell scripts, one launcher, one
catalogue. The guard and instincts hooks make no model calls; auto-handoff starts one
headless run per qualifying session (below).

> **Status.** Built: the launcher, the catalogue, the two guard hooks, the
> auto-handoff hook with its worker (below), the four instincts hooks (capture and
> inject; opt-in per project with `learning: on`, see [docs/instincts.md](../docs/instincts.md)),
> and the project emitter. To opt a project
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
| `instincts-capture-tool` | PostToolUse / Bash, Edit, Write, MultiEdit, NotebookEdit | open | Opt-in (`learning: on`). Appends one scrubbed line (tool, summarised input) to a local file. | 0 tokens; about 70 ms per tool call; prints nothing |
| `instincts-capture-failure` | PostToolUseFailure / same tools | open | Opt-in. Same, for a failed tool call, with an error flag. | 0 tokens; about 70 ms per failed call; prints nothing |
| `instincts-capture-prompt` | UserPromptSubmit | open | Opt-in. Appends one scrubbed, truncated line per prompt to a local file. | 0 tokens; about 70 ms per prompt; prints nothing |
| `instincts-inject` | SessionStart | open | Opt-in. Prints the project's learned habit hints into the session. | 0 tokens to run; about 100 to 300 tokens of hints when instincts exist, nothing otherwise |
| `auto-handoff` | SessionEnd | open | Writes a handoff with the real `/handoff` skill when a session of 5+ human turns did not run one. Machine-level, not a project profile. | One Sonnet run per qualifying session; capped by `--max-budget-usd 1.00`, `--max-turns 25` and a 900 s wall clock |

The machine-readable version of this table is `catalogue.json` (the only place scope,
profile and cost are defined). Every entry has a non-empty `cost`.

**What "closed" covers.** A `closed` guard blocks when it runs: a missing `jq` makes it
exit 2 with an install hint, which Claude Code treats as a block. It does not cover a
missing launcher. If `hooks/run.sh` is gone (a moved or deleted checkout, a wrong
`GRID_DIR`) the emitted command exits 127, which Claude Code does not treat as
blocking, so the guard is off until the path is fixed (the failure shows as a hook
error in the session). A launcher that blocks on its own absence is deferred.

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

Both are read by `run.sh` from the environment of the shell that launched `claude`
(the environment the hook runs in), not from any file; no re-emit is needed. Anything
that can set those variables for the hook process can switch a guard off, which is
what a kill switch is; whether a project's own `.claude/settings.json` `env` block
reaches hook subprocesses has not been verified.

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
| `GRID_GUARD_MAX_CMD` | 20000 | bytes, counted on the text with quotes removed; a command over this size that mentions git (or holds a `$` or a backtick, or names `LEFTHOOK`, `HUSKY` or `PRE_COMMIT`: the guards tokenize those too) is blocked ("command too long to inspect"), because a guard that cannot finish inside its 5 s timeout silently stops guarding |
| `GRID_GUARD_MAX_TOKENS` | 2500 | blanks and separators in the command (cost follows token count as much as size); the same block when over |
| `GRID_GUARD_MAX_GIT_CALLS` | 40 | secret scan only: git calls that need a repository check (plain ones such as `git status` are free); more than this blocks with the same message |
| `GRID_SCAN_MAX_LINES` | 1000 | secret scan only: more candidate lines (lines some pattern could match) than this blocks with "diff too large to scan; split the commit" |
| `GRID_SCAN_MAX_MATCH_BYTES` | 1048576 | secret scan only: total bytes the exact matcher may read in one scan; past this the scan stops with a finding named `oversize-scan` |
| `GRID_SCAN_MAX_SECONDS` | 3 | secret scan only: wall-clock budget of the diff scan, checked between lines and inside a line; past it the scan stops with a finding named `scan-budget`. The text of the commit command has a separate 2 s budget |
| `GRID_SCAN_MAX_FILES` | 500 | secret scan only: a `git add ... && git commit` in one command that would stage more files than this blocks with "stage in a separate call so the scan can see it" |
| `GRID_SCAN_MAX_BYTES` | 5242880 | secret scan only: the same block when the files the add would stage hold more bytes than this (the hook reads at most this many bytes plus one to find out) |

## Timeouts

Claude Code treats a hook that times out as non-blocking, so a slow guard is an
absent guard. Both guards therefore bound their work with caps rather than rely on the
tokenizer being fast on every input: a command over the byte or token cap, or with
substitutions nested deeper than 16, is refused instead of tokenized (the cost at the caps is about 1 to 2 s of CPU on a busy machine, not zero);
the secret scan stops at its line cap, its 1 MB matcher-input cap (`oversize-scan`) or a 3 s
wall-clock budget (`scan-budget`). The budget is checked before every pattern row and every
`key =` candidate, so one hostile or dense line cannot run past it; a single regex call
cannot be interrupted, so the scan can overshoot by the cost of one row on one piece (under
0.1 s on the worst lines tried, 20 to 40 ms measured). Ten crafted 258 KB lines took 4.1 s
in the hook before the budget was checked inside a line and 3.3 s after; it is the budget,
not the speed of the matcher, that keeps the hook inside its timeout, and a loaded machine
reaches the budget sooner and blocks with `scan-budget` instead of timing out. The text of
the commit command has a separate 2 s budget. A candidate line over 262144 characters (bytes
in the C locale) blocks as `oversize-line`. A line over 6,000 characters is matched in overlapping pieces; a
run of letters, digits and `_` that holds a key word (`secret`, `token`, ...) and is too
long to keep whole in a piece (over 4096 characters past a cut) is also `oversize-line`. A
key word followed by a long run of filler (identifier characters or backslashes) and then
`=` and a value can be longer than the overlap of two pieces: when a piece ends inside such
an assignment, the next piece starts at the key word instead of 4096 characters on, and an
assignment that fills a whole piece is `oversize-line`. A line with more than 200
`key =` candidates (`secret`, `token`, `password`, ...) is `key-dense-line`, because a scan
that cannot finish must block, not pass. These
are bounds, not a proof: an unusual input can still cost more than measured. Both catalogue entries carry
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
path to this checkout's `hooks/run.sh`), leaving every hand-written hook and key alone
(values and key order are kept, but the first write reformats the whole file as
2-space-indented JSON: tabs, `\uXXXX` escapes and spellings like `1e5` are normalised).
A settings file it cannot rewrite faithfully (duplicate keys, `NaN`/`Infinity`, empty,
read-only, not a regular file, larger than 1 MiB) is refused with a warning and left untouched; delete an
empty file or write `{}` to it.
Running `wire.sh` again changes nothing; `wire.sh --check` reports a missing entry and
exits 1. A symlinked settings file or config dir is refused (a warning from `wire.sh`),
and `wire.sh --check` skips it with a notice instead of reporting drift forever.
Numbers with more than 17 significant digits lose precision in the reformat (they pass
through a float).

**Opting out.** Per machine: put `-hook:auto-handoff` in the machine's manifest overlay
(re-enable with `hook:auto-handoff`). Per session: start `claude` with
`GRID_DISABLED_HOOKS=auto-handoff` (or `GRID_HOOKS=off` for every hook).

**Turning it on safely (preflight).** Some facts about the real `claude` cannot be seen
from the stub-based tests, so one script checks them live and only then flips the switch.
Three checks gate it; a fourth, `b1-rule-form`, is advisory:

```bash
bash scripts/auto-handoff-preflight.sh --dry-run     # print the commands, call nothing
bash scripts/auto-handoff-preflight.sh               # --check: run the checks, read-only
bash scripts/auto-handoff-preflight.sh --enable      # the 3 gating checks must pass in the same run, then enable
bash scripts/auto-handoff-preflight.sh --disable     # undo (no live check needed)
```

It prints its spend cap first: five `claude` calls, each `--max-budget-usd 0.10` on haiku,
so at most USD 0.50 (a subscription plan may not enforce the cap). Every call, `claude
--help` included, runs under `timeout` (`GRID_PREFLIGHT_TIMEOUT`, default 180 s); without
`timeout` the checks still run with a warning but `--enable` refuses. Ctrl-C or SIGTERM
stops only the probe the script started and removes its scratch dir. One line per check,
then a verdict; exit 0 only if all three gating checks pass. Each probe prints the flags it
ran with.

| Gating check | What it asserts |
|---|---|
| `env-propagation` | Whether a project `.claude/settings.json` `env` block reaches hook subprocesses (reported as `PROPAGATES` or `DOES-NOT-PROPAGATE`). `PROPAGATES` does not fail the check but prints a warning: a cloned repo could then set `GRID_HOOKS`, `GRID_PRIVATE_DIR`, `GRID_CLAUDE` or `GRID_AUTOHANDOFF_KEEP_ENV` for the hook, so run auto-handoff only in repos you trust, and `--enable` then needs `--accept-env-risk`. The answer comes from the SessionEnd hook (the event auto-handoff uses), waited for up to `GRID_PREFLIGHT_HOOK_WAIT` seconds (default 10); if it never fires the result is `INCONCLUSIVE`, which fails. This probe runs with `--permission-mode default --strict-mcp-config` but not `--setting-sources user`: its whole point is to load the project's `settings.json`. |
| `wp016-parity` | `claude --help` names `--permission-mode`, `--setting-sources`, `--strict-mcp-config`, and one tiny capped call with them succeeds. |
| `env-i-auth` | The worker's invocation authenticates under `env -i`. If claude works normally but not under `env -i`, the check fails and prints the remedy: `export GRID_AUTOHANDOFF_KEEP_ENV=ANTHROPIC_API_KEY` in the shell that starts claude. |

**Advisory: `b1-rule-form`.** It runs two capped probes (inside the five-call cap, with the
worker's three flags) and prints what a model did against the worker's write rules: an
`Edit(//abs/**)` allow, a write outside it, the `Edit(**/.git/**)` deny, and a `Bash(ls:*)`
allow with a `>` redirect. It is labelled `ADVISORY` and never counts toward the verdict, the
exit code or `--enable`; a bad or inconclusive result prints a warning, nothing more. Why:
it is a heuristic. It depends on what a model chooses to attempt and on a `stream-json`
shape that has not been verified against the real CLI (it looks for one write-capable
`tool_use` block on the exact path, parsed with `python3`), so a clean line is not a
guarantee and a bad one can be noise. Read it yourself. The real backstop is the worker's own
post-run detection (H-02, see Confinement below): it is fail-closed (it aborts without
committing if a watched path changed or an unexpected file appears) and commits only the
handoff files. It never reverts anything, and it cannot see writes outside the directories
and files it watches.

It also reports, without failing: the hook's manifest state (baseline, `machines/<host>.txt`
and `machines/<host>.local.txt`), a symlinked watched dotfile (`~/.gitconfig`, `~/.zshrc`,
`~/.bashrc`, `~/.config/git/config`, `~/.ssh/config`), a writable `~/.bash_aliases`, and the
`permissions` defaults in your user settings (a count and the shape of each allow rule,
`Bash(***)`: the text inside the parentheses is never printed, because an "always allow"
rule can embed a token).

`--enable` removes the `-hook:auto-handoff` line from `machines/<host>.txt` (a copy of the
file goes to `${GRID_STATE_DIR:-~/.grid}/preflight-backups/` first; the new file is written
to a temp file in `machines/` and renamed over it) and runs `scripts/wire.sh`; it never
writes under `~/.claude` itself. Lines are read the way `wire.sh` reads them (comment cut,
all whitespace dropped, an unterminated last line ignored). It refuses, changing nothing, if:
a gating check failed (b1-rule-form never counts); env `PROPAGATES` without `--accept-env-risk`; a watched dotfile is a symlink
or `~/.bash_aliases` is writable without `--accept-dotfile-risk` (H-02); there is no
`timeout`; the overlay is a symlink or not writable; or the baseline or the `.local` overlay
also says `-hook:auto-handoff` (it does not edit those). A failed write or backup is an error
and a non-zero exit, never "enabled". A second run changes no file; `wire.sh` is rerun because
it is idempotent and a manifest that says ON does not prove the entry is wired. `--disable`
appends `-hook:auto-handoff` again and rewires; the dotfile conditions do not block it. A
manifest line over 64 KB is refused before any claude call, and an edit run first removes a
`machines/<host>.txt.preflight.*` temp file left by a run that was killed with SIGKILL. The
probes call the model, so they cannot run in CI: the tests use a stub (`GRID_PREFLIGHT_CLAUDE`).

**When it runs.** It skips, and logs why, when:

- the transcript is unreadable (`no-transcript`);
- a handoff already ran in the session (`already-ran`: the `/handoff` command, a `Skill`
  call for `handoff`, or a written `*-handoff.md` file);
- the session has fewer than `GRID_AUTOHANDOFF_MIN_TURNS` human turns (`short-session`);
- the same session was already handed off and gained fewer than that many turns since
  (`no-new-turns`).

Only real human turns count: tool results, meta lines, attachments and subagent
(sidechain) lines do not. Only a message that STARTS with the `/handoff` command tag
counts as having run it; the tag quoted mid-sentence does not.

**One run at a time.** A worker takes a per-session lock (`<state dir>/handoff/<id>.lock`,
taken over when older than the timeout plus 5 minutes, released on every exit) and a
per-directory lock, so repeated SessionEnd payloads for one session spawn one model run
and two sessions in one directory take turns. The turn marker is written before the
child runs, so a failed run is not repeated until the session gains `MIN_TURNS` more
turns. What the child changed is judged by a before/after snapshot of the scanned
directories, so a file you edited just before the session ended is not blamed on it; a
build or editor writing into the directory *during* the run still is (`unexpected-file`).
The child runs in its own process group and the whole group is killed at the timeout.

Known limit: the locks serialise sessions that share a directory or a repo, and a waiter
gives up after `GRID_AUTOHANDOFF_WAIT` seconds (`cwd-busy`, or `repo-busy` once its child
has run, leaving the pair on disk uncommitted) with no retry. Three or more sessions that
end together on one shared target can therefore lose a handoff; the hook's outer alarm
allows for four such waits. `~/.local/bin` is watched by names, types, link targets and
sizes only (a same-size rewrite there is not seen, and a self-update of the claude link
during a run is reported as `unexpected-file`).

**Cost.** One Sonnet run per qualifying session. Bounds: `--max-budget-usd`
(`GRID_AUTOHANDOFF_MAX_USD`, default 1.00; it may not bind on a subscription plan),
`--max-turns 25`, and a wall-clock alarm (`GRID_AUTOHANDOFF_TIMEOUT`, default 900 s).
Every run is in the log and in the run record (`scripts/run-record.sh`, role
`auto-handoff`).

**The child can only write.** It runs in the session's directory with
`--tools Read,Write,Bash`. Write access is path-scoped allow rules,
`Edit(//<abs dir>/**)`, for the handoff target directory and the fallback directory
only; `Edit` itself and `Bash(git:*)` are denied, and Bash is limited to `hostname`,
`realpath`, `readlink`, `ls` and `date`. A system prompt (`lib/auto-handoff-system.md`)
tells it to write only the two files and run no git. The target directory is resolved
the way the handoff skill resolves it: the first matching row of `handoff-locations.md`
in the private dir (`$GRID_PRIVATE_DIR`, else `~/.the-grid-private/`), else an existing
`logs` directory of the session's directory in any casing. If it does not exist the
child writes to the fallback directory instead. A row's directory is matched ignoring
case at every component (`Docs/Handoffs` finds `docs/handoffs`). When two directories
match (`Logs` and `LOGS`, or an exact-case row plus another casing) nothing is granted:
the spawn line says `target-refused=ambiguous-case` and the child writes to the
fallback directory.

**Confinement.** Whether Claude Code honours the `Edit(//<abs>/**)` rule form was not
proven live (operator check B1), so the rules are not the only barrier:

- The resolved target must lie under the session's directory or the private repo. A
  `LOGS` symlink that points elsewhere is refused (only the fallback directory is
  granted; the spawn log line says `target-refused=<why>`). A table row written as a
  RELATIVE path must resolve inside the session's directory or the private repo too
  (`outside-cwd` otherwise: a tracked symlink at that path cannot redirect the grant).
  Only a row written as an ABSOLUTE path may name another repo, and then only if it has
  no `..`, is inside a git work tree whose root is not `$HOME`, and is not `$HOME`, `/`
  or under `~/.ssh`, `.claude`, `.config`, `.gnupg`, `.aws`, `.local/bin` or `.bashrc.d`.
  The private repo's own root is never a target (`private-root`): the child could
  rewrite `handoff-locations.md`, which decides future grants.
- A path with a glob metacharacter (`* ? [ ] { } ( ) !`) or a newline, or with a `..`
  component, gets no rule; the fallback directory name is sanitised the same way.
- The child runs with `--permission-mode default`, `--setting-sources user` and
  `--strict-mcp-config`, with extra denies for `~/.ssh`, `~/.claude`, `~/.config`,
  `~/.gnupg`, `~/.aws`, shell startup files, `~/.gitconfig` and anything under a `.git`
  directory.
- It starts under `env -i`: it gets `PATH`, `HOME`, locale, `TMPDIR`,
  `CLAUDE_CONFIG_DIR`, `CLAUDE_CODE_OAUTH_TOKEN`, the recursion guard, and only the
  variables named in `GRID_AUTOHANDOFF_KEEP_ENV` (comma list of names or `PREFIX*`).
  `GH_TOKEN`, `ANTHROPIC_API_KEY`, cloud credentials and `SSH_AUTH_SOCK` are not passed;
  if `claude` authenticates through an API key variable, list it there.
  **Widening risk (operator item, not yet probed):** `GRID_AUTOHANDOFF_KEEP_ENV` is read
  from the environment of the hook, and whether a project's `env` block (settings
  `env`) can reach that environment has not been checked. If it can, a repository could
  name a variable here and have it passed into the child (an API key, or a variable
  that changes how a tool the child runs behaves), so treat the variable as machine
  configuration: set it in your own shell profile, never from a project, and keep the
  list to the authentication variables `claude` needs. The worker does not restrict
  it to an allowlist yet; that is the follow-up if the probe shows propagation.
- The worker's own git calls after the child run with `core.fsmonitor=false`,
  `core.hooksPath=/dev/null` and the `ext::` transport off (your own configuration for
  remote access is left alone, so a push to a `git@host:` remote works), and only in a git dir that existed
  before the run, so a configuration
  the child managed to plant cannot execute anything. The repository's own hooks
  therefore do not run for the handoff commit (the worker's strict secret scan runs
  first); a git dir the child creates is `unexpected-git-dir`.
- Afterwards the worker detects (it never reverts) changes it could not stop; see the
  next list. It cannot see a write to an arbitrary path outside the directories and
  files listed there.

**What the worker does after the child.** It never trusts the model's side effects:

1. A change (content compared, before and after) to git `config`, `HEAD`, `info/`,
   `hooks/`, a submodule's config and hooks, a linked worktree's config, hooks and
   info, or a `core.hooksPath` directory, in the session's repo, the target repo or the
   fallback repo; or to shell startup files, `~/.ssh/{authorized_keys,config,config.d,rc}`,
   `~/{.gitconfig,.npmrc,.xprofile,.pam_environment,.local/bin,.bashrc.d}`,
   `~/.config/{autostart,systemd/user,git/attributes}`, Claude's
   `settings*.json`, `.credentials.json`, `CLAUDE.md`, `hooks/` and `commands/`, is
   `unexpected-file`: no commit, changed paths logged, nothing moved. (Not watched:
   a repo's `refs`, `packed-refs` and `index`, which change legitimately while you
   work.) The files your own config pulls in are watched too: those named by a
   `~/.gitconfig` or `~/.config/git/config` `include.path` / `includeIf.*.path`, and by
   an `Include` line of `~/.ssh/config`, followed through nested includes (five levels)
   and found once before the run. Bounds: only paths under `$HOME`; a glob (or a `%`/`$`
   token) watches the files it matches today plus the directory in front of its first
   special character, so a new file there is seen, except directly in `~/.ssh` or `$HOME`
   (matches only; `known_hosts` changes under any ssh) and for directories of more than
   500 entries; at most 64 paths; a path holding a newline is skipped; a symlink is
   watched as itself and where it points (when that is under `$HOME`). A `.git` entry
   that did not exist before the run, anywhere under the scanned directories, is
   `unexpected-git-dir`.
2. Every file or symlink (symlinks are not followed) that is new or changed during the run,
   under the session's directory (any depth, `.git/` excluded), the fallback directory
   and the target directory is collected (NOT the rest of the repo the commit lands in:
   other agents write there while the run is going, and a sibling session's files must
   not fail this one; two workers that share a write directory or a repo take turns), and a symlink named
   `*-handoff.md` or `*-context.md` is reported whatever its age. Exactly one
   `<p>-handoff.md` and at most one `<p>-context.md` with the same prefix, in the target
   or fallback directory, are expected. Anything else is `unexpected-file` (no commit,
   every path logged, nothing moved or deleted); no handoff file at all is
   `no-handoff-file`. A file or symlink that was there before the run and is gone after
   it is `unexpected-file` too, logged as `deleted=<paths>` (the child only creates
   files; a build or a person removing files in the directory mid-run is reported the
   same way as one adding them).
3. Both files are scanned with the secret table (`lib/secret-patterns.sh`), whatever the
   project profile says, in strict mode: the "example"/placeholder exemptions do not
   apply (a model can add the word to any line), and
   four extra shapes count: a run of 64 or more base64 characters, `Bearer <20+ chars>`,
   a URL password of 6 or more characters (`scheme://user:secret@host`, including a
   password that starts with `$`, `<` or `{` or holds a colon, and an empty user name,
   `scheme://:secret@host`) and `pass`/`pwd`/`password`
   assigned a value of 6 or more characters. An unquoted assigned value (`api_key =
   abc...`) counts at 16+ characters even when it is all letters or holds parentheses.
   Unlike the commit guard (which skips a value whose first character is `$`, `<` or `{`),
   the strict scan does not skip it (a model can put one in front of any value, and a
   password may start with one), reads a quoted value that begins with blanks (`api_key = " abc..."`), counts a
   run of 16 or more backslashes after the `=` as a value, and reads the multibyte blanks
   that only some locales know (U+3000, U+2003, U+00A0 and the like) as ordinary blanks (the
   line is scanned as it is and again with those blanks replaced, so neither reading hides
   a finding).
   A templated value such as `token=${A_LONG_VARIABLE_NAME}` is therefore quarantined too.
   A long hex digest in a handoff is therefore quarantined too. The same
   scan runs first on the timeout, child-failure and `unexpected-file` paths: a NEW file
   with a hit moves to the quarantine directory (the reason stays `timeout` and so on,
   with `secret=` and `quarantine=` added); a pre-existing file the child changed is only
   reported. A hit is `secret`: both files move to
   `${GRID_STATE_DIR:-$HOME/.grid}/handoff-quarantine/<session>/` (outside every repo),
   nothing is committed, and only names and line numbers are logged. Review and delete
   them.
4. The pair is committed by explicit path in the repository that holds the real files, so
   the operator's other staged work is not swept in. Outside any repository the files
   stay on disk (`commit=none`). A failed commit is `commit-failed`.
5. It pushes only when that repository is the private repo
   (`${GRID_PRIVATE_DIR:-$HOME/.the-grid-private}`), its branch has an upstream, and the
   handoff commit is the only unpushed one. A plain `git push`, nothing else.

**What the model sees and what the log keeps.** The digest the child reads is scanned
with the same strict table before the child starts: a matching line becomes
`[line redacted: <pattern>]` (the spawn log line says `redacted=<n>`), so a secret in the
transcript is never in front of the model. Child output and git's error text are masked
the same way before they are written to the log (`child| [masked: <pattern>]`). Each
message in the digest is cut to the size cap before it is measured, so one huge message
cannot exhaust memory.

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
| `GRID_AUTOHANDOFF_WAIT` | 120 | seconds a second session in the same directory waits for the first before skipping as `cwd-busy` |
| `GRID_AUTOHANDOFF_FORCE` | unset | `1` skips the already-ran, short-session and marker checks (parity runs, tests) |
| `GRID_HANDOFF_FALLBACK_DIR` | see above | where a handoff lands when the target directory is missing or denied |
| `GRID_PRIVATE_DIR` | `~/.the-grid-private` | the one repo the worker may push |
| `GRID_AUTOHANDOFF_KEEP_ENV` | unset | extra variables the child keeps under `env -i`: names or `PREFIX*`, comma separated (the stub in tests needs `STUB_*,GRID_*`) |
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

- `action=skip`: `bad-payload` (including a session id over 64 characters),
  `no-transcript`, `already-ran`, `short-session`, `no-new-turns`, `already-running`
  (another worker holds this session's lock), `cwd-busy` (another session held the
  directory's lock for `GRID_AUTOHANDOFF_WAIT` seconds; no marker is written, so a later
  end may retry), `cwd-too-broad` (the session directory is `/`, `$HOME` or a parent of
  it) and `no-perl` (written by the hook: without perl it cannot detach or time out).
- `action=spawn reason=ok`: the child started (`end=` is the SessionEnd reason).
- `action=done reason=ok`: the files were written and checked; `commit=` is `none` or the
  short sha.
- `action=error`: `terminated` (the worker got TERM, HUP or the hook's outer alarm; a
  half-made commit was unstaged), `timeout`, `claude-exit-<n>` (127 means the binary could not be run),
  `no-handoff-file`, `unexpected-file` and `unexpected-git-dir` (see `paths=` and `deleted=`), `repo-busy`, `secret`, `commit-failed`,
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
- nested escaped backticks (`` `echo \`git commit -n\`` ``),
- data written to a file and executed later (`printf '%s\n' 'git commit -n' > run.sh; sh run.sh`):
  the same hole as a script written with the Write tool. (A heredoc is not an example:
  its body is read as code, so `cat > run.sh <<EOF` holding a git flag blocks.)
- an interpreter that runs git from a quoted string (`python3 -c "os.system('git ...')"`,
  `node -e "execSync('git ...')"`),
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

Quote state is tracked so that one quote cannot hide a later command: `$'..'` strings end
at an unescaped `'`, and `$( )` or backticks inside double quotes have their own quotes. If
a quote or substitution is still open at the end of a command that names git, the guard
blocks with "a quote or substitution in this command is not closed": it cannot tell where
later commands start, so it fails closed.

Heredoc bodies are plain code. There is no heredoc modelling: `<<` is an ordinary word and
a body is read like any other lines of shell text, whatever consumes it (`| sh`,
`source /dev/stdin <<EOF`, `python3<<EOF`, a nested heredoc, arithmetic `1<<2`). That
removes every way to get a "data" heredoc wrong, at a known cost:

- a body that merely MENTIONS a git flag blocks (`cat <<'EOF'` holding `git commit --no-verify`
  text, a commit message that says "never git push --force"). Write such text with the
  Write tool and use `git commit -F <file>`;
- an apostrophe in a body opens a quote. An odd number leaves it open at the end, so the
  command blocks with the "not closed" message (the usual case: `don't` in a commit message
  inside `git commit -m "$(cat <<'EOF' ... EOF)"`; avoid the apostrophe or use `-F <file>`).
  An EVEN number pairs up and swallows the text between the apostrophes, which can hide a
  later git call in the same command (rare, accepted: it needs two stray apostrophes and a
  git call after them in one command).

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
`--no-verify` is blocked from 7 characters (`--no-ve`) and `git push --mirror` from 3
(`--m`); `--force` has no valid abbreviation.

The secret scan covers the patterns in `lib/secret-patterns.sh` and nothing else: no
entropy scoring, no token split over several lines, and (in this commit guard) an unquoted
assigned value that is made only of letters is not flagged (the auto-handoff worker's
strict scan flags it). An assignment value counts when it is quoted and
16+ characters, or unquoted, 16+ characters, with a digit and no parentheses; a value
that starts with `$`, `<` or `{` is a template and is skipped (the strict scan does not skip it, see
the auto-handoff section). A match is passed over
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
