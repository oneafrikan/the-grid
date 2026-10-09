## Why

Claude Code hooks are the only way to make a safety rule or a habit unconditional, but today the-grid ships none. Hooks are wired by hand per machine, and the one place they exist (issue-loop) hard-codes absolute paths. Gareth also runs `/handoff` after every session and wants it never forgotten. A per-project hook profile (off, minimal, standard, strict), declared once and emitted portably, gives cheap guards by default and makes model-calling hooks an explicit opt-in.

## What Changes

- New `hooks/` directory in the-grid: a launcher (`hooks/run.sh`), a catalogue (`hooks/catalogue.json`: id, event, matcher, minimum profile, fail mode, token-cost note) and one script per hook.
- New emitter `agent-factory/deploy_hooks.py`: reads `hooks:` from `<project>/.grid/project.yaml` and merges the chosen profile's hooks into `<project>/.claude/settings.local.json` (or `settings.json` with `target: shared`). Generated entries carry a marker; hand-written hooks are never touched; re-runs are no-ops.
- Three starter hooks: `pre-bash-no-bypass` (blocks `--no-verify` and force-push), `pre-bash-secret-scan` (blocks a commit that adds a secret), `session-end-auto-handoff` (detached `claude -p --model sonnet "/handoff"` driven by the session transcript when `/handoff` was not run).
- `deploy.py` accepts the new `hooks` key; the project-factory `.grid/project.yaml` skeleton gains a commented `hooks:` block.
- `scripts/gate.sh` shellchecks `hooks/`.

## Capabilities

### New Capabilities

- `hook-profiles`: profile declaration in `.grid/project.yaml`, the catalogue, the portable launcher, the non-clobbering emitter and runtime kill switches.
- `git-guard-hooks`: the no-bypass guard and the commit secret scan.
- `auto-handoff`: the SessionEnd hook, its detached worker, skip rules, recursion guard and logging.

### Modified Capabilities

None. `openspec/specs/` is empty; the `deploy.py` allowed-keys change is covered by a `hook-profiles` requirement.

## Impact

- New: `hooks/` (run.sh, catalogue.json, lib/, scripts/, README.md), `agent-factory/deploy_hooks.py`, `tests/test_hooks.bats`, `tests/test_deploy_hooks.bats`.
- Edited: `agent-factory/deploy.py` (one allowed key), `scripts/gate.sh` (shellcheck globs), `project-factory/templates/_common/.grid/project.yaml` (comments only), `CLAUDE.md` and `agent-factory/README.md` (pointers).
- Machines need `jq` and `perl` (both are default or one package away on macOS, Ubuntu, Arch); the emitter needs the agent-factory venv, like `deploy.py`.
- Token cost: `off`, `minimal` and `standard` cost zero tokens unless a guard blocks (about 60 tokens of explanation). `strict` adds one Sonnet run per non-trivial session.
- Use case named (new asset type): hooks for web/app, data-engineering and infra repos where a committed secret, a skipped pre-commit hook or a force-push is costly, plus the never-forgotten session handoff.

## Non-goals

- User-level (`~/.claude/settings.json`) emission. Per-project only; a machine-wide default is a later change.
- Emitters for Codex, Gemini CLI, OpenCode, Pi or OpenClaw. ECC ships Codex and Cursor hook adapters, which suggests those harnesses have hooks, but each is unverified here; the emitter keeps a seam (catalogue is harness-neutral, settings merge is one function) and workstream 11 verifies and builds them.
- Session-start or per-response hooks that inject context (instincts, memory) - that is workstream 7.
- Rewriting issue-loop's hooks or its `merge_hook` in `scripts/instantiate.sh`; the emitter ports the same merge semantics to Python and leaves the original alone.
- Per-hook options in `project.yaml` (turn thresholds, byte caps); those are environment variables only.
- A hook-authoring framework, dispatcher process or Node runtime like ECC's; scripts are plain bash.
