## Purpose

Make a green CI run mean the same thing as a green local gate, so the unattended loop can trust it.

## ADDED Requirements

### Requirement: CI runs the commit gate with the agent-factory venv
The CI workflow SHALL build `agent-factory/.venv` from `agent-factory/requirements.txt` and run `bash scripts/gate.sh`.

#### Scenario: Venv-dependent tests run on a runner
- **WHEN** the workflow runs on a pull request
- **THEN** no bats test is skipped with the reason "agent-factory venv not built"
- **AND** the gate step exits 0

#### Scenario: Workflow regression is caught
- **WHEN** `CI=true` and `agent-factory/.venv/bin/python` does not exist
- **THEN** the test `agent-factory venv exists when CI=true` fails

### Requirement: Wired-skill tests use the real wiring rules
Tests that validate "wired" skills MUST obtain the set by running `wire.sh` into a throwaway directory against the personal baseline if present, else `baseline-submodules.example.txt`.

#### Scenario: Runner without a personal baseline
- **WHEN** `baseline-submodules.txt` is absent
- **THEN** the example baseline defines the wired set
- **AND** library submodule skills with missing frontmatter do not fail the frontmatter tests

#### Scenario: A wired skill lacks a name
- **WHEN** a wired skill's `SKILL.md` has no `name:` line
- **THEN** the name test fails and prints that path

### Requirement: Live skills-dir health test skips on runners
The test `skills dir exists` SHALL skip when `CI=true` and the skills dir is absent, and SHALL fail when the dir is absent on a non-CI machine.

#### Scenario: Runner
- **WHEN** `CI=true` and `~/.claude/skills` does not exist
- **THEN** the test is reported as skipped with a reason

#### Scenario: Real machine
- **WHEN** `CI` is unset and the skills dir does not exist
- **THEN** the test fails
