## Why

Claude Code hooks are the only way to make a safety rule or a habit unconditional, but today the-grid ships none. Hooks are wired by hand per machine, and the one place they exist (issue-loop) hard-codes absolute paths. The operator runs `/handoff` at the end of every session and wants it never forgotten on any machine. Two needs follow: per-project guard hooks (a profile declared once and emitted portably), and one machine-level auto-handoff that is on wherever the-grid is installed.

## What Changes

- New `hooks/` directory in the-grid: a launcher (`hooks/run.sh`), a catalogue (`hooks/catalogue.json`: id, scope, event, matcher, minimum profile, fail mode, token-cost note) and one script per hook.
- New emitter `agent-factory/deploy_hooks.py` with two modes:
  - project mode: reads `hooks:` from `<project>/.grid/project.yaml` and merges the chosen profile's guard hooks into `<project>/.claude/settings.local.json` (or `settings.json` with `target: shared`);
  - `--user` mode (stdlib only): maintains the machine-level hooks in `${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json`.
  - Generated entries carry a marker; hand-written hooks are never touched; re-runs are no-ops.
- Two project guard hooks (a mistake-catcher, not a security boundary): `pre-bash-no-bypass` (blocks `--no-verify`, hook-disabling config and force-push, including one level of shell wrapping) and `pre-bash-secret-scan` (blocks a commit or `git add` that adds a secret or a sensitive file). The secret pattern table lives once in `hooks/lib/secret-patterns.sh`.
- One machine-level hook, `auto-handoff`: on SessionEnd, if no handoff ran in the session, a detached worker runs `claude -p "/handoff"` (Sonnet, budget and time caps, plus a turn cap if the CLI accepts one) over a transcript digest. The child may only write the two handoff files; the worker checks them, secret-scans them, commits them by explicit path, and pushes only the private repo when that commit is the sole unpushed one.
- `wire.sh` turns `auto-handoff` on by default on every run; a manifest line `-hook:auto-handoff` (baseline or machine overlay) turns it off for that machine. `GRID_DISABLED_HOOKS=auto-handoff` turns it off for one session.
- `deploy.py` accepts the new `hooks` key; the project-factory `.grid/project.yaml` skeleton gains a commented `hooks:` block; `scripts/gate.sh` shellchecks `hooks/`.

## Capabilities

### New Capabilities

- `hook-profiles`: per-project profile declaration, the catalogue, the portable launcher, the non-clobbering emitter and runtime kill switches.
- `git-guard-hooks`: the no-bypass guard and the commit secret scan.
- `auto-handoff`: the machine-level SessionEnd hook, its wiring and opt-out, the detached worker, skip rules, recursion guard, caps and logging.

### Modified Capabilities

None. `openspec/specs/` is empty; the `deploy.py` allowed-keys change and the `wire.sh` manifest grammar change are covered by requirements in the new capabilities.

## Impact

- New: `hooks/` (run.sh, catalogue.json, lib/, scripts/, README.md), `agent-factory/deploy_hooks.py`, `tests/test_hooks.bats`, `tests/test_deploy_hooks.bats`, `tests/test_auto_handoff_wiring.bats`.
- New test assets: `tests/helpers/hooks.bash`, `tests/fixtures/hooks/` (real hook payloads and transcript line shapes captured once by the operator, a hand-written-settings fixture).
- Edited: `scripts/wire.sh` (`hook:` manifest entries, user-hook sync, `--check`, manifest row), `tests/helpers/setup.bash` (sandbox `CLAUDE_CONFIG_DIR`, hook log/state dirs, `GRID_PRIVATE_DIR`, a tripwire value for the existing `GRID_CLAUDE`), `tests/helpers/stubs.bash` from `loops` (the `claude` stub gains handoff modes), `tests/test_gate.bats` (one case), `agent-factory/deploy.py` (one allowed key), `scripts/gate.sh` (shellcheck globs), `machines/example.txt` and `baseline-submodules.example.txt` (comments), `project-factory/templates/_common/.grid/project.yaml` (comments only), `CLAUDE.md` and `agent-factory/README.md` (pointers).
- Machines need `jq`, `perl` and `python3` (default or one package away on macOS, Ubuntu, Arch). Project mode needs the agent-factory venv, like `deploy.py`; `--user` mode does not.
- Token cost:
  - project profiles cost zero tokens unless a guard blocks (about 60 tokens of explanation);
  - `auto-handoff` is on by default and costs one Sonnet run per qualifying session (5+ human turns, no manual handoff), capped by a USD budget, a wall-clock timeout and (if the CLI accepts it) a turn limit. Sessions where the operator ran `/handoff` cost nothing extra.
- Use case: guard hooks for web/app, data-engineering and infra repos where a committed secret, a skipped pre-commit hook or a force-push is costly; the auto-handoff for every working session on every machine.

## Non-goals

- Pushing anything but a handoff-only commit in the private repo. Handoff commits in any other repo are left for the operator's next manual push (see design.md).
- Machine-level guard hooks. Guards are per project; only `auto-handoff` is machine-level.
- Emitters for Codex, Gemini CLI, OpenCode, Pi or OpenClaw. The catalogue is harness-neutral and the settings merge is one function; `multi-harness` owns verifying and building other harnesses.
- Session-start or per-response hooks that inject context (instincts, memory); that is `instincts`.
- Rewriting issue-loop's hooks or `merge_hook` in `scripts/instantiate.sh`; the emitter ports the merge semantics to Python and leaves the original alone.
- Per-hook options or `enable`/`disable` lists in `project.yaml`; the profile picks the set, environment variables tune the rest.
- A hook-authoring framework, dispatcher process or Node runtime like ECC's; scripts are plain bash.
