## Purpose

Stop a release being cleared by one reviewer's view alone: correctness and security are judged independently and both must pass.

## ADDED Requirements

### Requirement: Release gate uses two independent reviewers
The `tech-lead` operating procedure SHALL require `qa-engineer` and `security-reviewer`, each in a fresh context with the same packet, before a change is reported as passing the release gate.

#### Scenario: Procedure names both roles and independence
- **WHEN** `agent-factory/roles/tech-lead/SKILL.md` is read
- **THEN** its release-gate step names `qa-engineer` and `security-reviewer`
- **AND** states that neither reviewer sees the other's verdict

#### Scenario: Lean deploy carries the procedure
- **WHEN** `tech-lead` is deployed with `--profile lean`
- **THEN** the deployed skill contains the release-gate step

### Requirement: Both reviewers must pass
The procedure MUST report the gate as passed only when `qa-engineer` returns PASS and `security-reviewer` returns no open Critical or High finding.

#### Scenario: One reviewer blocks
- **WHEN** `qa-engineer` returns PASS and `security-reviewer` reports an open High finding
- **THEN** the gate is reported as blocked
- **AND** the finding is forwarded verbatim to the owning specialist

#### Scenario: A reviewer is unavailable
- **WHEN** either role cannot be spawned
- **THEN** the procedure states the gate is not passed and tells the user which role is missing

### Requirement: Fix loop is capped and re-reviews with fresh agents
After a blocked gate the procedure SHALL re-run both reviewers with fresh agents after fixes, and MUST escalate to the human after the third blocked round.

#### Scenario: Third block escalates
- **WHEN** a third consecutive round returns a BLOCK
- **THEN** the procedure stops fixing and escalates with the verdicts of all rounds

### Requirement: Behaviour is covered by golden eval cases
The repository SHALL include eval cases for the gate under `evals/cases/tech-lead/` that validate in the gate and are not run by it.

#### Scenario: Cases validate
- **WHEN** `run_evals.py --validate` runs
- **THEN** it exits 0 and the two gate cases are among those validated
