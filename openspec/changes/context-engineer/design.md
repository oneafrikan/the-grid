## Context

- Facts below were read from `main` at `3ce7965` (2026-10-20). A large upgrade may land before this is built: **re-check every number and file name before editing** (group 1 does this).
- `ai-engineer` (`agent-factory/roles/ai-engineer/`, 2966 B `AGENTS.md`): `role.yaml` `owns:` lists "Context and token budgets, prompt caching, model/effort selection, retries and failure codes, agent loops, tool/MCP integration, async model calls, retrieval plumbing, observability and cost tracking". Its routing table sends "Prompt text, rubric, schema semantics" to `prompt-engineer`.
- `prompt-engineer` (2616 B `AGENTS.md`): routing table sends "Context, token budget, caching, retries, model choice, tool plumbing" to `ai-engineer`. Its scope is correct and does not change.
- `tech-lead` is an orchestrator: `AGENTS.md` cap is 5120 B and the file is **5113 B** (`docs/role-authoring.md`, Variants). Any addition must be paid for by trimming existing text. It already has an ADR bullet ("ADR authoring is a wired skill ... `architecture-designer`") and a bullet saying one-off prompt tuning is self-serve and "isn't a gap that needs a new role".
- `core` is `agent-factory/examples/core.yaml`: 5 roles, no delegation chain, wired on every machine via `project:core`. Agent names render `<slug>-<role>` unless `bare: true`. A core role cannot be in a grid orchestrator's `delegates_to` (a delegate not on the team is a hard compose error); `researcher` is the precedent, reached by direct route or Signal Protocol.
- Role contract: `agent-factory/docs/role-authoring.md` (sections `Scope`, `What to get right hardest`, `Hard rules`, `Receiving work`; the shared four rules; `AGENTS.md` <= 4096 B for specialists; "route to a role by name, and say what to do if it isn't available"). `compose.py --lint-roles` enforces it for roles listed in `authored-roles.txt`.
- Description budget: `docs/budget-target.json` has `per_entry_max_chars` 250 and `agent_roles_max_chars` 5672. A new agent description raises the second. `python3 scripts/budget.py --update-target --allow-raise` is the only way to raise it and needs review.
- Issue-loop worker issues are picked by the `ready-for-agent` label. The tracking issue for this change must not carry it.

## The three roles

| Role | Project | Composed name | Owns | Does not own |
|---|---|---|---|---|
| `ai-engineer` | grid | `grid-ai-engineer` | Runtime around model calls: model/effort selection, API prompt-caching mechanics, structured-output plumbing, retries and failure codes, agent loops, tool/MCP integration, async execution, retrieval plumbing (clients, indexes, calls), observability, per-call cost tracking, fine-tuning/deployment where applicable | What loads into context, how much, how it is split; prompt text |
| `prompt-engineer` | grid | `grid-prompt-engineer` | Prompt text: system prompts, rubrics, few-shot examples, output schemas, versioning (unchanged) | Runtime plumbing; context layout and budget |
| `context-engineer` | core | `core-context-engineer` | Context design and budget: what loads into a session and when (`CLAUDE.md`, `AGENTS.md`, memory, skills, role files), size and split (skill `sections/`, role file caps), cache-friendly ordering of stable prefixes, retrieval design (what to retrieve, chunking, ranking, how much enters context), compaction and handoff design, measuring with `scripts/budget.py` | Prompt text; model calls and their runtime; prose accuracy of docs (`technical-writer`) |

## Decisions

- Decided: the new role is named `context-engineer`, lives in `core`, and composes to `core-context-engineer`. No `bare: true`. The names do not group with `grid-ai-*`; accepted (operator, 2026-10-20) to avoid renaming `prompt-engineer`.
- Decided: `role.yaml`: `default_model: sonnet`, `orchestrator: false`, `tools: [Read, Grep, Glob, Write, Edit, Bash]` (Bash for `budget.py` and size checks, Edit/Write for the files it is asked to restructure). `summary` and `description` each <= 250 chars, in the form `Context Engineer. <what it owns>. Use for <trigger>.`
- Decided: it is a specialist subagent, not an orchestrator, with no `delegates_to`. It is invoked directly, by `tech-lead` as a routed off-team call, or by Signal Protocol.
- Decided: split of the contested `ai-engineer` duties: context-window and token **budget as design** (what fits, what to drop or compact) and **retrieval design** move to `context-engineer`; **per-call cost tracking**, **API caching mechanics** and **retrieval plumbing** stay with `ai-engineer`. Cache-friendly ordering of the stable prefix is `context-engineer`. These are the writer's draft calls; the PR reviewer confirms them.
- Decided: `context-engineer` measures before and after any change it proposes (`python3 scripts/budget.py --report`, `wc -c`), and a context change with no number is reported as "unmeasured".
- Decided: `context-engineer` never edits a human's `CLAUDE.md` or memory files without showing the diff first and never raises an always-on token cost without stating it (matches the `config.yaml` rule: anything that injects text into context is opt-in and budgeted).
- Decided: boundary wording follows `role-authoring.md`: each routing row names the role and says what to do if it is not wired ("tell the user which role should take it"). `context-engineer` lives in `core`, which survives `-project:grid`, so it must not depend on `ai-engineer` or `prompt-engineer` existing.
- Decided: `ai-engineer` edits: `role.yaml` (`summary`, `description`, `owns`), `AGENTS.md` `## Scope` and its routing table, plus `SKILL.md`/`SOUL.md` only where they name a moved duty (grep for `context`, `token budget`, `retrieval`). `SOUL.md` does not grow. `AGENTS.md` stays <= 4096 B.
- Decided: `prompt-engineer` edits are limited to the routing table (split the "Context, token budget, caching" row) and nothing else.
- Decided: `tech-lead` edit replaces the ADR bullet with an "Architecture is a wired skill, not a role" bullet naming `architecture-designer` (ADRs, trade-offs, diagrams), `cloud-architect`, `microservices-architect`, `rag-architect`, `legacy-modernizer` (narrower cases) and the built-in `Plan` agent (read-only option-weighing), and states the decision stays with the tech lead. It adds one bullet routing context design to `core-context-engineer` as an off-team call (same shape as the `researcher` bullet). Pay for it by tightening the one-off-prompt bullet and the research bullet; remove no Hard rule. Final `AGENTS.md` must be <= 5120 B.
- Decided: no ADR location is named anywhere in this change.
- Decided: counts after the change: `core` 6 roles; public roles 39 (7 orchestrators + 32 specialists); `grid` stays 24. Re-derive from the files before editing docs, do not trust these numbers.
- Decided: the budget ratchet is raised, not worked around: run `budget.py --update-target --allow-raise`, show the before and after numbers in the PR body, and leave the raise for review.
- Decided: recompose only `core` and `grid`. Do not recompose `finance-desk`, `learning-desk` or any private project. The private `research-desk` is untouched and must stay wired (compare `ls agent-factory/projects/` before and after).
- Decided: branch and PR base is `main`. If a `next` branch exists on `origin` when you start, ask which base; do not guess.

## Risks

- `ai-engineer` scope is wide even after narrowing. If a later pass shows the three roles overlap in practice, the fix is a boundary edit, not a fourth role.
- Name mismatch (`core-context-engineer` vs `grid-ai-engineer`) is permanent unless the operator renames later; renaming `prompt-engineer` touches about 25 files and generated output (see the proposal discussion), so it is deliberately out of scope.
- `tests/test_docs_accuracy.bats` pins some `CLAUDE.md` wording about `project:core`; update the assertion with the doc, not around it.
- A parallel upgrade may have changed the same files. Group 1 is a re-verify step; stop and report if any premise above is false (do not patch past it).
