## Why

Nobody owns context design. What loads into a session (`CLAUDE.md`, `AGENTS.md`, memory, skills, role files), how big it is, and how it is split is today a side duty of `ai-engineer` ("Context and token budgets", "retrieval plumbing" in its `role.yaml` `owns:`), with `technical-writer` keeping the prose true and the human doing the rest. `ai-engineer` is already a wide brief (runtime plumbing, agent loops, MCP, cost, fine-tuning), and `docs/role-authoring.md` says that a role which cannot meet the 4 KB contract "is two roles - flag it, don't cram". A dedicated role gives context work one owner, keeps `ai-engineer` focused on runtime plumbing, and keeps `prompt-engineer` focused on prompt text.

Use case: the-grid is a context-budget project (description budget gate, `budget.py`, section splitting, handoff skill, memory rules). Every machine benefits from a role that designs and measures what loads, so the role lives in `core`, not in the dev team.

## What Changes

- New role `context-engineer` in `agent-factory/roles/`, enrolled in `authored-roles.txt`, composed in `examples/core.yaml` (agent name `core-context-engineer`).
- `ai-engineer` is narrowed: context windows, token budgets and retrieval design move to `context-engineer`; model choice, structured-output plumbing, failure handling, agent loops, tools/MCP, async execution and cost tracking stay.
- `prompt-engineer` is unchanged in scope. All three AI roles gain a "hands off to" boundary naming the other two, worded so a missing role is never a hard dependency.
- `tech-lead` routing: the existing ADR bullet is extended to name the narrower architecture skills and the built-in `Plan` agent (no new architect role), and a context-work route to `core-context-engineer` is added. `tech-lead/AGENTS.md` is 5113 of 5120 bytes, so the edit trims existing text to net zero or less.
- Counts and rosters that name the core project or the public role total are updated; generated files are regenerated.

## Capabilities

### New Capabilities

- `context-engineer-role`: the new role, its scope, files, project and enrolment.
- `ai-role-boundaries`: the three-way split between `ai-engineer`, `prompt-engineer` and `context-engineer`, and the cross-awareness each role file carries.
- `architect-routing`: how `tech-lead` routes architecture and context work without a new architect role.

### Modified Capabilities

None. `openspec/specs/` holds no role specs.

## Impact

- New: `agent-factory/roles/context-engineer/` (7 files).
- Edited: `agent-factory/roles/{ai-engineer,prompt-engineer,tech-lead}/`, `agent-factory/authored-roles.txt`, `agent-factory/examples/core.yaml`.
- Docs naming the core roster or the role total: `CLAUDE.md`, `README.md`, `agent-factory/README.md`, `skills/grid-help/sections/orientation.md`, `baseline-submodules.example.txt` (comment), `index.html`, and `tests/test_docs_accuracy.bats` if its assertions pin the old text.
- Generated, regenerated not hand-edited: `MAP.md` (`python3 scripts/map.py`), `plugins/` and `.claude-plugin/marketplace.json` (`python3 scripts/build-plugins.py`), `dist/personas/` (whatever produces it; find it in group 4), `grid.lock` only if the baseline changes (it does not).
- Token cost: one more agent description in the listing (`agent_roles_max_chars` in `docs/budget-target.json`, currently 5672, will need `--allow-raise` and review). No new always-on text: the role is operator- or Signal-Protocol-invoked.
- Machines: `core` wires everywhere, so `core-context-engineer` appears on every machine after `compose.py examples/core.yaml` and `wire.sh`.

## Non-goals

- No new architect role. Architecture stays with `tech-lead` plus the wired `architecture-designer` skill.
- No rename of `ai-engineer` or `prompt-engineer`, and no `ai-` prefix on the new role. Agent names will not group alphabetically (`core-context-engineer` vs `grid-ai-engineer`); accepted to avoid churn.
- `context-engineer` is not added to any `delegates_to` (a core role cannot be a delegate of a grid orchestrator without a compose error).
- No ADR location convention.
- No change to `_core/` fragments, `compose.py`, or any project other than `core` (composition) and `grid` (recompose after the `ai-engineer`, `prompt-engineer`, `tech-lead` edits).
- No recompose of private projects.
- No change to how `budget.py` measures; the role uses it, it does not extend it.
- No fine-tuning, eval or prompt-text work in the new role.
