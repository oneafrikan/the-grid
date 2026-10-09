## Purpose

Make a green CI run mean the same thing as a green local gate, so the unattended loop can trust it.

## ADDED Requirements

### Requirement: CI runs the commit gate with the agent-factory venv
The CI workflow SHALL run on pushes to `main` and `next` and on every pull request, build `agent-factory/.venv` from `agent-factory/requirements.txt`, and run `bash scripts/gate.sh`, with machine-only tests skipping on a runner.

#### Scenario: Venv-dependent tests run on a runner
- **WHEN** the workflow runs on a pull request
- **THEN** no bats test is skipped with the reason "agent-factory venv not built"
- **AND** the gate step exits 0

#### Scenario: Push to next is gated
- **WHEN** a commit is pushed to `next`
- **THEN** the workflow runs

#### Scenario: Workflow regression is caught
- **WHEN** `CI=true` and `agent-factory/.venv/bin/python` does not exist
- **THEN** the test `agent-factory venv exists when CI=true` fails

#### Scenario: Live skills dir absent on a runner
- **WHEN** `CI=true` and the skills dir does not exist
- **THEN** the test `skills dir exists` is reported as skipped with a reason

#### Scenario: Live skills dir absent on a real machine
- **WHEN** `CI` is unset and the skills dir does not exist
- **THEN** the test `skills dir exists` fails

### Requirement: Wired-skill tests use the real wiring rules
`wire.sh` SHALL read the baseline manifest from `$GRID_BASELINE` when set (default `$GRID_DIR/baseline-submodules.txt`), and tests that validate wired skills MUST obtain the set by running `wire.sh` into a throwaway directory with `GRID_BASELINE` set to the personal baseline if present, else `baseline-submodules.example.txt`.

#### Scenario: Baseline override
- **WHEN** `GRID_BASELINE` names a file that lists only repo `a` of repos `a` and `b`
- **THEN** only `a`'s skills are wired

#### Scenario: Runner without a personal baseline
- **WHEN** `baseline-submodules.txt` is absent
- **THEN** the example baseline defines the wired set
- **AND** library submodule skills with missing frontmatter do not fail the frontmatter tests

#### Scenario: A wired skill lacks a name
- **WHEN** a wired skill's `SKILL.md` has no `name:` line
- **THEN** the name test fails and prints that path
