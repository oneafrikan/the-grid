## Purpose

Stop a release being cleared by one reviewer's view alone: correctness and security are judged independently and both must pass.

## ADDED Requirements

### Requirement: Both independent reviewers must pass
The `tech-lead` operating procedure SHALL send the same packet to `qa-engineer` and `security-reviewer`, each in a fresh context without the other's verdict, and MUST report the gate as passed only when `qa-engineer` returns PASS and `security-reviewer` reports no open Critical or High finding.

#### Scenario: Procedure names both roles and independence
- **WHEN** `agent-factory/roles/tech-lead/SKILL.md` is read
- **THEN** its release-gate step names `qa-engineer` and `security-reviewer`
- **AND** states that neither reviewer sees the other's verdict

#### Scenario: Lean deploy carries the procedure
- **WHEN** `tech-lead` is deployed with `--profile lean`
- **THEN** the deployed skill contains the release-gate step

#### Scenario: Gate cases validate
- **WHEN** `run_evals.py --validate` runs
- **THEN** it exits 0 with the two `evals/cases/tech-lead/gate-*` cases among those validated

### Requirement: Fix loop is capped and re-reviews with fresh agents
After a blocked gate the procedure SHALL forward findings verbatim to the owning specialist, re-run both reviewers with fresh agents, and MUST escalate to the human after the third blocked round or when either reviewer is unavailable.

#### Scenario: Third block escalates
- **WHEN** a third consecutive round returns a BLOCK
- **THEN** the procedure stops fixing and escalates with the verdicts of all rounds

#### Scenario: A reviewer is unavailable
- **WHEN** either role cannot be spawned
- **THEN** the procedure states the gate is not passed and names the missing role
