# hooks/

Claude Code hooks that ship with the-grid. Shell scripts, zero model calls, one
launcher, one catalogue.

> **Status.** Built so far: the launcher, the catalogue, and the two guard hooks
> below. Not built yet: the emitter that writes hooks into a project's settings
> (`agent-factory/deploy_hooks.py`), the `hooks:` key in `.grid/project.yaml`, and the
> machine-level auto-handoff hook. Until the emitter exists, the profile table below
> describes the design; to use a guard now, add the launcher command to a settings
> file by hand (see "Calling a hook").

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
| `pre-bash-no-bypass` | PreToolUse / Bash | closed | Blocks `--no-verify` (any git subcommand), `git commit -n`, `-c core.hooksPath=`, `git config` writes of `core.hooksPath` or of an alias hiding `--no-verify`/`-n`, the `GIT_CONFIG_COUNT` / `GIT_CONFIG_PARAMETERS` / `GIT_CONFIG_KEY_*` / `HUSKY=0` assignments, and force pushes (`--force`, `--mirror`, `+refspec`, `-f` clusters). `--force-with-lease` is allowed. | 0 tokens; about 20 ms per Bash call; about 60 tokens only when it blocks |
| `pre-bash-secret-scan` | PreToolUse / Bash | closed | On `git commit`: scans the added lines of the staged diff (and of the working tree when the commit names paths or uses `-a`/`-i`/`-o`) for secret patterns, and blocks sensitive file names. On `git add`: blocks sensitive file names. | 0 tokens; no work unless the command is `git commit` or `git add`; a short file:line list only when it blocks |

The machine-readable version of this table is `catalogue.json` (the only place scope,
profile and cost are defined). Every entry has a non-empty `cost`.

## How it fits together

```
settings.json  ->  bash ".../hooks/run.sh" <id>   ->   hooks/scripts/<id>.sh
                     (id check, kill switches)          (sources hooks/lib/*.sh)
```

- `run.sh <id>` rejects an id that is not `[a-z0-9-]+` or has no `scripts/<id>.sh`
  (exit 2), honours the kill switches, then runs the script with stdin passed through.
  It needs no `jq`, so it behaves on a machine without it.
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

## Exit codes (Claude Code's rule)

- Only exit **2** blocks a `PreToolUse` call; the stderr text is shown to the agent.
- Any other non-zero exit, including **127** ("command not found", for example a
  missing `run.sh`), is a visible, non-blocking error. A guard whose script is missing
  therefore stops guarding, visibly. That is deliberate: bricking every Bash call on a
  machine without the-grid is worse.
- The one failure inside our control that would otherwise turn a guard into a silent
  no-op is a missing `jq`, so the guards exit 2 with an install hint when `jq` is absent.
- Both guards exit 0 on input that is not JSON, a tool other than Bash, or no command.

## Adding a hook

1. Write `hooks/scripts/<id>.sh` (`<id>` is lowercase letters, digits and hyphens). Source
   `lib/common.sh`, call `grid_require_jq closed` (a guard) or `open` (a background hook),
   and comment the script.
2. Add one entry to `catalogue.json`: `id`, `scope` (`project` or `user`), `event`,
   `matcher` (omit for events without one), `min_profile` (project hooks only), `fail`
   (`closed` or `open`), `timeout`, `model_cost`, a non-empty `cost`, and `description`.
3. Add tests to `tests/test_hooks.bats`. The suite fails if a catalogue id has no script,
   a script has no catalogue entry, or a `cost` is empty.
4. The gate runs `shellcheck -S warning` over `hooks/*.sh`, `hooks/lib/*.sh` and
   `hooks/scripts/*.sh`. Keep the scripts to bash, `jq` and POSIX tools.

Nothing under `hooks/` may use network tools or URLs: the vetting audit
(`python3 scripts/audit.py --root . hooks`) treats a hook that talks to the network as a
high-severity finding.

## Known gaps

The guards do not inspect:

- wrappers nested more than one level deep (`sudo env git ...`),
- shell aliases and functions,
- scripts that call git,
- variables expanded at run time (`$CMD`),
- `git -c alias.x=...` one-shot aliases,
- heredoc bodies that sit outside quotes (each body line is read as a command, so a body
  line that itself starts with `git push --force` is a false positive),
- command substitution outside quotes (`$(git commit --no-verify)`).

The secret scan covers the patterns in `lib/secret-patterns.sh` only (no entropy
scoring), and it scans the repository in the payload's `cwd`.

## The `grid:allow-secret` pragma (for humans)

A line that carries the text `grid:allow-secret` is skipped by the secret scan, for a
known false positive such as a documented sample key. Lines containing `example`,
`placeholder`, `changeme`, `your_`, `xxxxxxxx` or `redacted` (any case) are skipped as
well. The block message never mentions the pragma: an agent that reads the message
should not learn how to silence the check.

## Other harnesses

The scripts read the Claude Code `PreToolUse` payload (`tool_name`, `tool_input.command`,
`cwd`) on stdin. That is the only seam; another harness would need an adapter that
produces the same JSON. Nothing here is built for one (see the `multi-harness` change).
