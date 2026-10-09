## Purpose

Let a project declare how many of the-grid's Claude Code hooks it wants (off, minimal, standard, strict), and emit exactly those into the project's settings portably, without touching hand-written hooks, with the token cost of every hook stated.

## ADDED Requirements

### Requirement: Profile resolution
The emitter SHALL resolve the hook set from the `hooks:` key of `<project>/.grid/project.yaml` (`profile` of `off`, `minimal`, `standard` or `strict`, absent meaning `off`, plus optional `enable` and `disable` id lists), where each catalogue entry has one `min_profile` and a profile includes every hook at or below it.

#### Scenario: Absent key means off
- **WHEN** `deploy_hooks.py` runs on a project whose `.grid/project.yaml` has no `hooks:` key and no `--profile` flag is given
- **THEN** no grid hook entry is written to either settings file

#### Scenario: Flag overrides file
- **WHEN** `project.yaml` says `profile: minimal` and the emitter is run with `--profile strict`
- **THEN** the strict set of hooks is emitted

#### Scenario: Unknown profile is rejected
- **WHEN** `project.yaml` says `profile: paranoid`
- **THEN** the emitter exits non-zero naming the allowed values and writes nothing

#### Scenario: Standard includes minimal
- **WHEN** the profile is `standard`
- **THEN** the emitted set contains the `minimal` hooks and the `standard` hooks and no `strict` hook

#### Scenario: Enable adds a higher hook
- **WHEN** the profile is `minimal` and `enable` lists `session-end-auto-handoff`
- **THEN** that hook is emitted in addition to the minimal set

#### Scenario: Disable removes a hook
- **WHEN** the profile is `standard` and `disable` lists `pre-bash-secret-scan`
- **THEN** that hook is not emitted

#### Scenario: Off with enable is an error
- **WHEN** the profile is `off` and `enable` is non-empty
- **THEN** the emitter exits non-zero and writes nothing

#### Scenario: Agent deploy tolerates the hooks key
- **WHEN** `deploy.py` runs on a project whose `project.yaml` contains a `hooks:` mapping
- **THEN** it deploys agents as before and does not report an unknown key

#### Scenario: Project-factory skeleton resolves to off
- **WHEN** `deploy_hooks.py` reads the unmodified project-factory `.grid/project.yaml` skeleton
- **THEN** the profile resolves to `off`

### Requirement: Portable launcher and runtime kill switches
Every emitted hook command SHALL invoke the-grid's `hooks/run.sh` through `${GRID_DIR:-$HOME/.the-grid}` with no absolute user-home path, and the launcher MUST exit 0 without running a hook when `GRID_HOOKS=off` or the hook id is in `GRID_DISABLED_HOOKS`, and reject any id that is not a catalogue entry.

#### Scenario: No absolute paths
- **WHEN** hooks are emitted for any profile on a machine whose home is `/home/someone` or `/Users/someone`
- **THEN** the written settings file contains neither that home path nor any `/Users/` or `/home/` string

#### Scenario: Missing grid is a visible error
- **WHEN** a generated command runs on a machine where `${GRID_DIR:-$HOME/.the-grid}/hooks/run.sh` does not exist
- **THEN** the shell exits non-zero (127) so the hook is reported as an error rather than silently passing

#### Scenario: Global off
- **WHEN** `GRID_HOOKS=off` is set and any hook is launched with input that would otherwise block
- **THEN** the launcher exits 0

#### Scenario: Single hook disabled
- **WHEN** `GRID_DISABLED_HOOKS=pre-bash-no-bypass` is set and that hook is launched with a blocking input
- **THEN** the launcher exits 0 and other hooks still run

#### Scenario: Path traversal id
- **WHEN** the launcher is called with the id `../../etc/passwd`
- **THEN** it exits non-zero without executing anything

### Requirement: Non-clobbering merge
The emitter MUST add, update and remove only entries it generated, recognised by the generated-command pattern, and leave every other key and hook in the settings files unchanged.

#### Scenario: Hand-written hooks survive
- **WHEN** `settings.local.json` already holds a hand-written PreToolUse Bash hook and other settings keys, and the emitter runs
- **THEN** those entries and keys are still present and unmodified after the run

#### Scenario: Lowering the profile removes only generated entries
- **WHEN** the profile is lowered from `strict` to `minimal` and the emitter re-runs
- **THEN** the standard and strict generated entries are removed, the minimal entry and all hand-written entries remain

#### Scenario: Off removes all generated entries
- **WHEN** the profile is changed to `off` and the emitter re-runs
- **THEN** no generated entry remains in either settings file and hand-written entries are untouched

#### Scenario: Invalid JSON is not overwritten
- **WHEN** the target settings file is not valid JSON
- **THEN** the emitter exits non-zero before writing and the file is byte-identical afterwards

#### Scenario: Target change moves entries
- **WHEN** `target` changes from `local` to `shared` and the emitter re-runs
- **THEN** the generated entries appear in `settings.json` and are gone from `settings.local.json`

### Requirement: Idempotent, checkable and cost-disclosed emission
The emitter SHALL produce byte-identical settings on a second run with unchanged inputs, report drift with a non-zero `--check` that writes nothing, and print every hook's minimum profile, token-cost note and model-call flag under `--list`.

#### Scenario: Second run is a no-op
- **WHEN** the emitter runs twice in a row with the same inputs
- **THEN** the second run reports no change and the file bytes and modification time are unchanged

#### Scenario: Drift is reported
- **WHEN** a generated entry has been deleted by hand and `deploy_hooks.py --check` runs
- **THEN** it exits non-zero, names the missing hook and writes nothing

#### Scenario: List shows cost
- **WHEN** `deploy_hooks.py --list` runs
- **THEN** each hook is printed with its minimum profile, its cost note and whether it calls a model

#### Scenario: Catalogue and scripts agree
- **WHEN** the test suite runs
- **THEN** it fails if a catalogue id has no `hooks/scripts/<id>.sh`, a script has no catalogue entry, or an entry has an empty `cost`
