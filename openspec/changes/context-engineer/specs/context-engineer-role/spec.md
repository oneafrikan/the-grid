## Purpose

Give context design (what loads into a session, how big it is, how it is split) one owner: a specialist role in the `core` project that survives `-project:grid` and is wired on every machine.

## ADDED Requirements

### Requirement: The role exists and passes the authoring contract
`agent-factory/roles/context-engineer/` SHALL contain `role.yaml`, `SOUL.md`, `IDENTITY.md`, `AGENTS.md`, `USER.md`, `MEMORY.md` and `SKILL.md`, the role SHALL be listed in `agent-factory/authored-roles.txt`, and `python3 agent-factory/compose.py --lint-roles` SHALL exit 0 with `AGENTS.md` at or under 4096 bytes and containing `Scope`, `What to get right hardest`, `Hard rules` and `Receiving work` sections.

#### Scenario: Lint passes
- **WHEN** `compose.py --lint-roles` runs on the tree
- **THEN** it exits 0 and reports no `E_*` code for `context-engineer`

#### Scenario: Size cap
- **WHEN** `wc -c agent-factory/roles/context-engineer/AGENTS.md` runs
- **THEN** the byte count is 4096 or less

### Requirement: Role metadata
`role.yaml` SHALL set `name: context-engineer`, `title: Context Engineer`, `default_model: sonnet`, `orchestrator: false`, `tools: [Read, Grep, Glob, Write, Edit, Bash]`, and a `summary` and `description` of 250 characters or fewer each, the description starting `Context Engineer.` and ending with a `Use for ...` trigger.

#### Scenario: Description within budget
- **WHEN** `python3 scripts/budget.py --check` runs after the raise in the budget task
- **THEN** it exits 0 and no entry exceeds `per_entry_max_chars`

### Requirement: Scope
`AGENTS.md` SHALL state that the role owns what loads into a session and when (`CLAUDE.md`, `AGENTS.md`, memory, skills, role files), size and split, cache-friendly ordering of stable prefixes, retrieval design, compaction and handoff design, and measurement with `scripts/budget.py`; and SHALL state that it does not own prompt text, model-call runtime, or prose accuracy of docs.

#### Scenario: Out-of-lane request
- **WHEN** a request asks the role to rewrite a system prompt or to build a retry loop
- **THEN** `AGENTS.md` routes it to the owning role by name

### Requirement: Measured, diff-first changes
`AGENTS.md` `Hard rules` SHALL include: measure before and after any change it proposes and call an unmeasured effect "unmeasured"; show the diff before editing a human's `CLAUDE.md` or memory files; state the token cost of any always-on addition; and apply the shared four rules from `docs/role-authoring.md` (verify before declaring done, state planned versus built, quote failing output verbatim, name the independent check and label a self-check).

#### Scenario: Always-on addition
- **WHEN** the role proposes text that loads every session
- **THEN** its report states the byte cost and the budget it counts against

### Requirement: Composed in core, wired everywhere
`agent-factory/examples/core.yaml` SHALL list `context-engineer` (without `bare: true`) and update its `description` and header comment to name six roles, and composing it SHALL produce a subagent named `core-context-engineer` with no `delegates_to` entry anywhere.

#### Scenario: Compose and wire
- **WHEN** `compose.py examples/core.yaml --target claude-code` then `bash scripts/wire.sh` run, and `wire.sh` runs a second time
- **THEN** `~/.claude/agents/core-context-engineer.md` resolves into the grid checkout and the second `wire.sh` run changes nothing

#### Scenario: Survives grid subtraction
- **WHEN** a machine overlay carries `-project:grid`
- **THEN** `core-context-engineer` is still wired and its role file does not require `ai-engineer` or `prompt-engineer` to exist
