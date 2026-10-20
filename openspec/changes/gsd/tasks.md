# Tasks

Conventions: one agent, one worktree off `main`; the operator wants no PR, so land directly on `main` once `bash scripts/gate.sh` passes twice, one commit per group, then remove the worktree and branch. Decisions are in `design.md` (`Decided:` lines); do not re-decide them. Comment any file you add. Overlaps with the `context-engineer` change (#298) on count lines, `authored-roles.txt` and the budget: derive numbers from files, rebase if the other landed first.

## 1. Re-verify premises (no edits)

- [ ] 1.1 `git fetch`; `git worktree list`; confirm the roles named in `delegates_to` exist, `grid.yaml` still lists 3 orchestrators, `authored-roles.txt` has an orchestrator block, and no skill or agent named `gsd` is wired (`ls ~/.claude/skills ~/.claude/agents | grep -i gsd`).
- [ ] 1.2 If any premise is false, stop and report; do not patch around it.

## 2. Role files

Depends on: 1.

- [ ] 2.1 Create `agent-factory/roles/gsd/` (7 files) modelled on `roles/tech-lead/` for the orchestrator structure and written to `docs/role-authoring.md`. `AGENTS.md` <= 5120 B. Content per `design.md` and the `gsd-orchestrator` spec; say plainly in `Scope` that PRDs, ADRs, security review and CI/release gates are out and belong to `tech-lead` and feature releases.
- [ ] 2.2 Add `gsd` to `agent-factory/authored-roles.txt` (orchestrator block).
- [ ] 2.3 Verify: `python3 agent-factory/compose.py --lint-roles` exits 0.

## 3. Compose in grid

Depends on: 2.

- [ ] 3.1 Edit `agent-factory/examples/grid.yaml`: add the `gsd` entry with `bare: true` and its `delegates_to`; leave `ceo-orchestrator` untouched; update the `description:` and header-comment counts.
- [ ] 3.2 Verify: `agent-factory/.venv/bin/python agent-factory/compose.py agent-factory/examples/grid.yaml --target claude-code --check` shows only the expected drift; compose output stays in ignored dirs.

## 4. Counts, docs, generated files, budget

Depends on: 3.

- [ ] 4.1 Find and update docs: `git grep -n -E '3 orchestrators|24 roles|21 specialists|[0-9]+ (composed )?(public )?roles|7 orchestrators' -- . ':(exclude)repos' ':(exclude)LOGS' ':(exclude)openspec' ':(exclude)dist' ':(exclude)plugins' ':(exclude)MAP.md'`. Derive numbers from the files. Update `tests/test_docs_accuracy.bats` assertions together with the docs.
- [ ] 4.2 Regenerate: `python3 scripts/map.py`; `python3 scripts/build-plugins.py` (needs `agent-factory/.venv`); the `dist/personas/` generator (find it; do not hand-edit).
- [ ] 4.3 Budget: `python3 scripts/budget.py --report` before and after, then `python3 scripts/budget.py --update-target --allow-raise`.
- [ ] 4.4 Verify: `bash scripts/gate.sh` twice; the second run changes no file.

## 5. Land and wire

Depends on: 4.

- [ ] 5.1 Land on `main` directly (rebase first if `main` moved); push; remove the worktree and branch.
- [ ] 5.2 HUMAN, on each machine after pull: `cd agent-factory && .venv/bin/python compose.py examples/grid.yaml --target claude-code && cd .. && bash scripts/wire.sh`; run `wire.sh` a second time (must be a no-op); confirm `/gsd` is wired.
