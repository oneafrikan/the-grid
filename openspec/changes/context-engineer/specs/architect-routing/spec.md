## Purpose

Answer "who is the architect?" without adding a role: `tech-lead` keeps the architecture decision and is told which wired skills and agents supply the method, and routes context design to `core-context-engineer`.

## ADDED Requirements

### Requirement: Architecture routing in tech-lead
`agent-factory/roles/tech-lead/AGENTS.md` `## Routing` SHALL contain one bullet that names the `architecture-designer` skill for ADRs, trade-offs and diagrams, the `cloud-architect`, `microservices-architect`, `rag-architect` and `legacy-modernizer` skills for the narrower cases, and the built-in `Plan` agent for read-only option-weighing, and SHALL state that the architecture decision stays with the tech lead; and SHALL NOT introduce an `architect` role or `delegates_to` entry.

#### Scenario: No new role
- **WHEN** `ls agent-factory/roles` and `examples/grid.yaml` are inspected
- **THEN** no `architect` role exists and `tech-lead`'s `delegates_to` is unchanged

#### Scenario: Skills exist
- **WHEN** each named skill is looked up in the wired skill set
- **THEN** every name resolves (or the bullet is corrected to a name that does)

### Requirement: Context design routes to the core role
`tech-lead/AGENTS.md` `## Routing` SHALL contain one bullet saying context design (what loads into a session, `CLAUDE.md`/memory/skill layout, context budget) is off-team and goes to `core-context-engineer` with the question and the decision it informs, following the wording shape of the existing `researcher` bullet.

#### Scenario: Not on the roster
- **WHEN** `compose.py examples/grid.yaml --target claude-code --check` runs
- **THEN** it exits 0 and `context-engineer` is not in the generated roster table

### Requirement: Orchestrator size cap respected
`tech-lead/AGENTS.md` SHALL be 5120 bytes or less after the edit, with no Hard rule removed, the added bullets paid for by tightening the one-off-prompt and research bullets.

#### Scenario: Cap
- **WHEN** `wc -c agent-factory/roles/tech-lead/AGENTS.md` runs
- **THEN** the count is 5120 or less and `compose.py --lint-roles` exits 0
