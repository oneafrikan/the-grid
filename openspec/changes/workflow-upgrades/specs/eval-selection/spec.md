## Purpose

Run paid role evals only for the roles whose files changed, so CI or the issue loop can afford to run them on every change.

## ADDED Requirements

### Requirement: Changed files select roles
`run_evals.py --changed <git-range>` SHALL map changed paths to roles using the built-in rules for `agent-factory/roles/<role>/**` and `evals/cases/<role>/**` and the rules in `evals/touchfiles.yaml`, with the first matching rule winning per file.

#### Scenario: A role file selects that role
- **WHEN** a commit changes only `agent-factory/roles/qa-engineer/AGENTS.md`
- **THEN** `--changed HEAD~1 --dry-run` selects only `qa-engineer`

#### Scenario: A case file selects its role
- **WHEN** a commit changes only `evals/cases/tron/example.yaml`
- **THEN** only `tron` is selected

#### Scenario: A narrow rule precedes a broad one
- **WHEN** a commit changes only `agent-factory/_core/DECISION_BRIEF.md`
- **THEN** the orchestrator roles with cases are selected
- **AND** `qa-engineer` is not

#### Scenario: Unrelated change selects nothing
- **WHEN** a commit changes only `README.md`
- **THEN** the output contains `no eval-relevant changes` and the exit status is 0 without `GRID_EVALS=1`

### Requirement: Selection stays opt-in and capped
With `--changed`, real runs MUST still require `GRID_EVALS=1` and `--yes`, and the run SHALL be refused before any spend when its worst case exceeds `--max-total` (default 5.00 USD).

#### Scenario: Broad change exceeds the cap
- **WHEN** a commit changes `agent-factory/compose.py` and `--max-total` is left at its default
- **THEN** the command exits 2 and names `--role` and `--max-total` as options
- **AND** no model is called

#### Scenario: Raised cap allows the plan
- **WHEN** the same range is run with `--max-total 50 --dry-run`
- **THEN** it prints the plan and the worst-case spend and exits 0

#### Scenario: Real run needs both gates
- **WHEN** `--changed` selects a role and `GRID_EVALS=1` is unset
- **THEN** the command exits 2 and writes no results file

### Requirement: Bad input fails loudly
An unusable git range SHALL exit 2 with an `E_RANGE` message, and `--validate` MUST reject a touchfile rule that names a role which does not exist.

#### Scenario: Unknown range
- **WHEN** `--changed no-such-ref..HEAD` runs
- **THEN** it exits 2 and the error output contains `E_RANGE`

#### Scenario: Touchfile names a missing role
- **WHEN** `evals/touchfiles.yaml` lists a role that has no directory and `--validate` runs
- **THEN** it exits 1 and reports the role as unknown
