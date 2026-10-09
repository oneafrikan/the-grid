## Purpose

Connect instincts to the existing learning-desk without a new subsystem: tank turns patterns into proposed changes and candidate skills, oracle may offer preference instincts, and nothing is applied without the operator.

## ADDED Requirements

### Requirement: Tank reads instincts as a named source and treats a single-project instinct as a lead
The `tank` role SHALL list the instincts store as a read-only source and SHALL treat an instinct active in one project as a lead and one active in two or more projects as a pattern.

#### Scenario: Role guidance
- **WHEN** `agent-factory/roles/tank/AGENTS.md` is read
- **THEN** it names `~/.the-grid-private/learning/instincts/` as a source and states the lead-versus-pattern rule

### Requirement: Tank evolve drafts skills only into the private store
The `tank` role SHALL write candidate skills only under `~/.the-grid-private/learning/tank/skill-drafts/<slug>/SKILL.md` and MUST NOT wire, install or write them into the public repo.

#### Scenario: Draft from a cluster
- **WHEN** `instincts.sh clusters` lists a cluster of three active instincts in one domain and the operator asks tank to evolve it
- **THEN** a draft `SKILL.md` with `name`, `description` and an Evidence section naming the instinct ids appears under `skill-drafts/`
- **AND** no file under `skills/` changes

#### Scenario: Draft from a LEARNINGS.md entry
- **WHEN** the operator names a procedural `LEARNINGS.md` entry
- **THEN** tank drafts a candidate skill the same way and cites the entry hash

### Requirement: Evolve input is deterministic and free
The system SHALL provide `instincts.sh clusters`, which lists clusters of at least 3 active instincts with confidence at least 0.6 sharing a domain, plus global instincts at or above 0.75, using no model call.

#### Scenario: Cluster listing
- **WHEN** the store holds three testing instincts at 0.6 or higher
- **THEN** `clusters` lists them as one cluster

### Requirement: The weekly job is a script and tank stays on request
The system SHALL run weekly analysis as a script outside any agent role, so tank remains operator-triggered only.

#### Scenario: Tank rule unchanged
- **WHEN** tank's hard rules are read
- **THEN** they still state that tank never runs unattended

### Requirement: Oracle may offer preference instincts with per-entry approval
The `oracle` role SHALL offer a `preference` instinct with confidence at least 0.6 as a profile candidate only when the operator names the instincts store in that session, tagged OBSERVED and saved only after a yes.

#### Scenario: Not named
- **WHEN** the operator has not named the instincts store
- **THEN** oracle does not read it
