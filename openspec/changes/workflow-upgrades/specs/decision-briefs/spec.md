## Purpose

Give every orchestrator one numbered, answerable format for asking the human to decide, so replies can be "D3: B".

## ADDED Requirements

### Requirement: Orchestrators receive a size-linted decision-brief section
The composer SHALL append `agent-factory/_core/DECISION_BRIEF.md` to every role with `orchestrator: true` in both the full and lean profiles, MUST NOT append it to specialists or edit any role's own `AGENTS.md`, and `--lint-roles` SHALL report `E_DECISION_BRIEF` when the fragment is missing, over 1500 bytes, or lacks `D<N>`.

#### Scenario: Orchestrator output contains the section
- **WHEN** the fixture project is composed for the `claude-code` target
- **THEN** each orchestrator skill file contains a `## Decision briefs` heading
- **AND** each specialist subagent file does not

#### Scenario: Lean deploy contains it for orchestrators only
- **WHEN** `deploy.py` deploys `tech-lead` and `qa-engineer` with `--profile lean`
- **THEN** the `tech-lead` skill contains `## Decision briefs`
- **AND** the `qa-engineer` agent does not

#### Scenario: Oversize fragment is reported
- **WHEN** the lint checks a fragment larger than 1500 bytes
- **THEN** it reports `E_DECISION_BRIEF`

### Requirement: The brief format is numbered, recommends, and auto-decides conservatively
The fragment SHALL define a `D<N>` label, summary, stakes, two to four lettered options with one recommendation and the reply form `D<N>: <letter>`, and MUST tell an unattended orchestrator to take the recommended option unless it is destructive or irreversible, take the conservative option then, and record each auto-chosen decision.

#### Scenario: Fragment carries the required fields
- **WHEN** `agent-factory/_core/DECISION_BRIEF.md` is read
- **THEN** it contains `D<N>`, `Summary`, `Stakes`, `Recommendation`, the reply example `D3: B` and the phrase `destructive or irreversible`
