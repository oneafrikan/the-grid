## Purpose

Make the three AI roles (`ai-engineer`, `prompt-engineer`, `context-engineer`) distinct and aware of each other, so each request has one obvious owner and no role depends on another being wired.

## ADDED Requirements

### Requirement: ai-engineer is narrowed to runtime plumbing
`ai-engineer`'s `role.yaml` (`summary`, `description`, `owns`) and `AGENTS.md` `## Scope` SHALL describe the runtime around model calls (model and effort selection, API caching mechanics, structured-output plumbing, retries and failure codes, agent loops, tool/MCP integration, async execution, retrieval plumbing, observability, per-call cost tracking) and SHALL NOT claim context-window budget design or retrieval design, which belong to `context-engineer`.

#### Scenario: No duplicated ownership
- **WHEN** `ai-engineer` and `context-engineer` `owns` text are compared
- **THEN** no duty appears in both, and context-window budget design and retrieval design appear only in `context-engineer`

#### Scenario: Size
- **WHEN** `compose.py --lint-roles` runs
- **THEN** `ai-engineer/AGENTS.md` is 4096 bytes or less and `ai-engineer/SOUL.md` is no larger than before

### Requirement: prompt-engineer scope is unchanged
`prompt-engineer`'s scope SHALL stay prompt text, rubrics, few-shot examples, output schemas and versioning; only its routing table SHALL change, replacing the single "Context, token budget, caching, retries, model choice, tool plumbing" row with rows that send context, token-budget design and cache-friendly layout to `context-engineer` and retries, model choice and tool plumbing to `ai-engineer`.

#### Scenario: Diff is limited
- **WHEN** the `prompt-engineer` change is diffed
- **THEN** only its routing table rows differ

### Requirement: Cross-awareness without hard dependency
Each of the three roles' `AGENTS.md` routing table SHALL name the other two roles for the work it hands off, and for each route SHALL say what to do when that role is not wired (tell the user which role should take it); `context-engineer` SHALL NOT instruct any step that requires `ai-engineer` or `prompt-engineer` to be present.

#### Scenario: Every pair is covered
- **WHEN** the three routing tables are read
- **THEN** each role names both other roles at least once

#### Scenario: Role absent
- **WHEN** a machine wires `core` but not `grid`
- **THEN** `context-engineer`'s routes to the other two roles end in "tell the user which role should take it" instead of a failed delegation
