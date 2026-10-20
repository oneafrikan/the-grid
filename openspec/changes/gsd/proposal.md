## Why

`grid-tech-lead` is built for large-team work: PRD-first handoffs, a QA release gate, a security gate, ADRs. Used on small fixes it forces process the operator does not need and slows everything down. Rule 15 of the shared rules now says the main session never writes code, small changes go to one specialist with no process, and several independent small fixes fan out; it refers to `gsd` "once it exists". This change builds that fan-out role: the small-team hacker beside the large-team tech lead.

Use case: several small, independent fixes in one session, each of which would eat context window if done inline. `gsd` splits them, fans them out to specialists with their own context windows, merges the branches, and has `qa-engineer` verify. Security and CI/release gates wait for feature releases.

## What Changes

- New orchestrator role `gsd` in `agent-factory/roles/`, composed in `examples/grid.yaml` with `bare: true` (invoked as `/gsd`), enrolled in `authored-roles.txt`.
- `delegates_to`: backend-dev, frontend-dev, fullstack-engineer, devops, data-engineer, sdet, qa-engineer, technical-writer. `grid-ponytail` is reached by name (it is root-owned, not a compose role).
- Not added to `ceo-orchestrator`'s `delegates_to` (standalone, invoked by the operator). No change to `tech-lead`.
- Counts and rosters that name grid's orchestrators or the role total are updated; generated files regenerated.

## Capabilities

### New Capabilities

- `gsd-orchestrator`: what the role does and does not do (split, one-fix and many-fix flows, merge, QA, escalation, hard rules).
- `gsd-wiring`: composition, naming, enrolment, counts, budget.

### Modified Capabilities

None.

## Impact

- New: `agent-factory/roles/gsd/` (7 files).
- Edited: `agent-factory/examples/grid.yaml`, `agent-factory/authored-roles.txt`, docs naming grid's orchestrator count or the public role total (find them with the grep in `tasks.md`), `docs/budget-target.json` (raise, reviewed).
- Generated, regenerated not hand-edited: `MAP.md`, `plugins/`, `.claude-plugin/marketplace.json`, `dist/personas/`.
- Token cost: one more skill description in the listing (orchestrator budget `orchestrator_roles_max_chars`). No always-on text.
- Overlaps with the `context-engineer` change (#298): both touch the same count lines, `authored-roles.txt` and the budget target. Either can land first; the second rebases. Counts are derived from files, never copied from this spec.

## Non-goals

- No change to `tech-lead`; it keeps PRDs, gates and ADRs for feature work.
- No security review, CI or release gate inside `gsd`; those belong to feature releases.
- No PRDs, ADRs, task tracking or project-manager involvement.
- `gsd` does not write code itself, and does not push beyond the working branch unless told to.
- No new specialist roles.
- No ADR location convention.
