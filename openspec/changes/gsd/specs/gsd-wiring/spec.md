## Purpose

Compose, name, enrol and count the new role without disturbing other projects or the budget gate.

## ADDED Requirements

### Requirement: Role files and enrolment
`agent-factory/roles/gsd/` SHALL contain `role.yaml` (`orchestrator: true`, `default_model: sonnet`, `summary` and `description` each 250 characters or fewer, the description starting `GSD.` and naming the small-fix fan-out use), `SOUL.md`, `IDENTITY.md`, `AGENTS.md` (5120 bytes or fewer, with `Scope`, `What to get right hardest`, `Hard rules`, `Roster`, `Delegation & Context`, `Routing`, and the `{{ROSTER_TABLE}}` token), `USER.md`, `MEMORY.md` and `SKILL.md`; and `authored-roles.txt` SHALL list `gsd` in the orchestrator block.

#### Scenario: Lint
- **WHEN** `python3 agent-factory/compose.py --lint-roles` runs
- **THEN** it exits 0 with no `E_*` code for `gsd`

### Requirement: Composed as a bare grid skill
`agent-factory/examples/grid.yaml` SHALL list `gsd` with `bare: true` and `delegates_to` of backend-dev, frontend-dev, fullstack-engineer, devops, data-engineer, sdet, qa-engineer and technical-writer, SHALL NOT add it to `ceo-orchestrator`'s `delegates_to`, and SHALL update its description count.

#### Scenario: Compose and wire
- **WHEN** `compose.py examples/grid.yaml --target claude-code` and `bash scripts/wire.sh` run, and `wire.sh` runs a second time
- **THEN** `/gsd` resolves into the grid checkout as a skill and the second run changes nothing

#### Scenario: No name clash
- **WHEN** wired skills and agents are listed
- **THEN** exactly one entry is named `gsd`

### Requirement: Counts, generated files and budget
Every doc that names grid's orchestrator count or the public role total SHALL be updated to the derived numbers, generated files SHALL be regenerated not hand-edited, and `docs/budget-target.json` SHALL be raised only through `budget.py --update-target --allow-raise` with before and after shown.

#### Scenario: Gate
- **WHEN** `bash scripts/gate.sh` runs twice
- **THEN** both runs pass and the second changes no file
