## Purpose

Give every orchestrator one numbered, answerable format for asking the human to decide, so replies can be "D3: B".

## ADDED Requirements

### Requirement: Orchestrators receive the decision-brief section
The composer SHALL append the contents of `agent-factory/_core/DECISION_BRIEF.md` to every role with `orchestrator: true`, in both the full and lean profiles, and MUST NOT append it to specialist roles.

#### Scenario: Orchestrator output contains the section
- **WHEN** the fixture project is composed for the `claude-code` target
- **THEN** each orchestrator skill file contains a `## Decision briefs` heading
- **AND** each specialist subagent file does not

#### Scenario: Lean deploy contains it for orchestrators only
- **WHEN** `deploy.py` deploys `tech-lead` and `qa-engineer` with `--profile lean`
- **THEN** the `tech-lead` skill contains `## Decision briefs`
- **AND** the `qa-engineer` agent does not

### Requirement: The brief format is numbered and recommends
The brief fragment SHALL define a `D<N>` label, a summary, stakes, two to four lettered options with exactly one recommendation, and the reply form `D<N>: <letter>`.

#### Scenario: Fragment carries the required fields
- **WHEN** `agent-factory/_core/DECISION_BRIEF.md` is read
- **THEN** it contains `D<N>`, `Summary`, `Stakes`, `Recommendation` and the reply example `D3: B`

### Requirement: Unattended orchestrators auto-decide conservatively
The fragment MUST instruct an unattended orchestrator to take the recommended option unless it is destructive or irreversible, to take the conservative option in that case, and to record each auto-chosen decision.

#### Scenario: Unattended rule is present
- **WHEN** `agent-factory/_core/DECISION_BRIEF.md` is read
- **THEN** it contains the unattended rule naming "destructive or irreversible" and the recording requirement

### Requirement: The brief fragment is size-linted and does not enlarge role files
`compose.py --lint-roles` SHALL fail with `E_DECISION_BRIEF` when the fragment is missing, over 1500 bytes, or lacks the `D<N>` marker, and adding the fragment MUST NOT change any role's own `AGENTS.md`.

#### Scenario: Oversize fragment is reported
- **WHEN** the lint runs against a copy of the fragment larger than 1500 bytes
- **THEN** it reports `E_DECISION_BRIEF` and exits 1

#### Scenario: Real roles stay within their caps
- **WHEN** `compose.py --lint-roles` runs on the repository
- **THEN** it exits 0
- **AND** `agent-factory/roles/tech-lead/AGENTS.md` is byte-identical to its pre-change content
