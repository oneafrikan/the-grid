# Tasks

Conventions: one agent, one worktree off `main`, one PR to `main` containing all groups (the operator asked for a single PR), one commit per group in order. Verify command is `bash scripts/gate.sh` unless stated. Decisions are in `design.md` (`Decided:` lines); do not re-decide them. Do not merge; the operator merges. Do not run `wire.sh` or `compose.py` against the real `~/.claude` from the worktree (use the post-merge steps in group 6). Comment any script or config you touch.

## 1. Re-verify the premises (no edits)

Depends on: nothing.

- [ ] 1.1 Fresh `git fetch`; `git worktree list` and report anything stale. Confirm `tech-lead/AGENTS.md` byte count, `ai-engineer`/`prompt-engineer` `owns:` text, `core.yaml` role list, and the public role count (`ls agent-factory/roles` minus private, minus `_*`) against the numbers in `design.md`.
- [ ] 1.2 Confirm the skill names in the `architect-routing` spec resolve: `ls ~/.claude/skills | grep -E '^(architecture-designer|cloud-architect|microservices-architect|rag-architect|legacy-modernizer)$'` (all five).
- [ ] 1.3 If any premise is false, STOP and report which; do not patch around it (two-strike rule).

Acceptance: a one-paragraph premise report in the PR body, all true or the run stopped.

## 2. New role `context-engineer`

Depends on: 1.

- [ ] 2.1 Create `agent-factory/roles/context-engineer/` with the 7 files, modelled on `roles/librarian/` (same `tools:` shape) and written to `docs/role-authoring.md`. Content per `design.md` "The three roles" and the `context-engineer-role` spec. `AGENTS.md` <= 4096 B. `SOUL.md` and `SKILL.md` stay short; put long reference in `SKILL.md` sections only if over the 4000-byte skill rule.
- [ ] 2.2 Add `context-engineer` to `agent-factory/authored-roles.txt` (specialists block) and to `agent-factory/examples/core.yaml` with a header-comment line saying why it is in core; update that file's `description:` and the "All four" style counts in its comment.
- [ ] 2.3 Verify: `python3 agent-factory/compose.py --lint-roles`; `agent-factory/.venv/bin/python agent-factory/compose.py agent-factory/examples/core.yaml --target claude-code --check` is expected to report drift (new role) and is then composed into the worktree's own ignored output only to check it renders; the composed name is `core-context-engineer`.

Acceptance: lint exits 0; composed agent file exists with the description <= 250 chars.

## 3. Narrow ai-engineer, cross-awareness

Depends on: 2.

- [ ] 3.1 Edit `roles/ai-engineer/role.yaml` (`summary`, `description`, `owns`) and `AGENTS.md` (`## Scope`, routing table with a row for `context-engineer`); touch `SKILL.md`/`SOUL.md` only where they name a moved duty (`grep -n -i -E 'context|token budget|retrieval'`). `SOUL.md` must not grow.
- [ ] 3.2 Edit `roles/prompt-engineer/AGENTS.md` routing table only (split the row per the `ai-role-boundaries` spec).
- [ ] 3.3 Make `context-engineer`'s routing rows name both other roles with the "if not wired, tell the user" wording.
- [ ] 3.4 Verify: `wc -c` on the three `AGENTS.md`; `compose.py --lint-roles`; `git diff --stat roles/prompt-engineer` shows only its table.

Acceptance: each of the three routing tables names the other two; no duty is claimed by two roles.

## 4. tech-lead routing

Depends on: 3.

- [ ] 4.1 Edit `roles/tech-lead/AGENTS.md` `## Routing` per `design.md` (architecture bullet replaces the ADR bullet; one context-design bullet; pay for them by tightening the one-off-prompt and research bullets). Remove no Hard rule.
- [ ] 4.2 Verify: `wc -c roles/tech-lead/AGENTS.md` <= 5120; `compose.py --lint-roles`; `compose.py examples/grid.yaml --target claude-code --check` shows only expected drift; no `architect` role and `delegates_to` unchanged (`git diff examples/grid.yaml` is empty).

Acceptance: the `architect-routing` scenarios hold.

## 5. Counts, docs, generated files, budget

Depends on: 2, 3, 4.

- [ ] 5.1 Update every doc that names the core roster or the public role total. Find them with: `git grep -n -E 'platform-engineer.{0,60}tron|librarian, researcher|38 (composed )?(public )?roles|38 composed|7 orchestrators \+ 31|\| 5 \|' -- . ':(exclude)repos' ':(exclude)LOGS' ':(exclude)openspec' ':(exclude)dist' ':(exclude)plugins' ':(exclude)MAP.md'`. Known hits at spec time: `CLAUDE.md` (core roster x2, "38 composed public roles"), `README.md`, `agent-factory/README.md` (core row and role totals), `skills/grid-help/sections/orientation.md`, `baseline-submodules.example.txt` comment, `index.html`. Do not hand-edit `MAP.md`, `plugins/` or `.claude-plugin/marketplace.json`.
- [ ] 5.2 If `tests/test_docs_accuracy.bats` pins old wording (line 191 pinned `project:core` text at spec time), update the assertion together with the doc.
- [ ] 5.3 Regenerate: `python3 scripts/map.py`; `python3 scripts/build-plugins.py` (needs `agent-factory/.venv`); regenerate `dist/personas/` with whatever produces it (find the generator; do not hand-edit); `bash scripts/catalog.sh` only if the gate says `SKILLS.md` drifted.
- [ ] 5.4 Budget: `python3 scripts/budget.py --report` before and after; then `python3 scripts/budget.py --update-target --allow-raise` for the one raise; show both reports in the PR body.
- [ ] 5.5 Verify: `bash scripts/gate.sh` (full). Run it twice; the second run must change no file (`git status` clean).

Acceptance: gate passes, regenerated files are committed, no hand-edited generated file.

## 6. Open the PR, then HUMAN steps

Depends on: 5.

- [ ] 6.1 Push the branch and open one PR to `main`. Body: premise report, the Decided calls the reviewer must confirm (the `ai-engineer` split of contested duties), budget before/after, gate output. End with the attribution line the session instructs.
- [ ] 6.2 HUMAN: independent review of the PR (a second agent or the operator), then merge.
- [ ] 6.3 HUMAN (after merge, on each machine): `cd agent-factory && .venv/bin/python compose.py examples/core.yaml --target claude-code && .venv/bin/python compose.py examples/grid.yaml --target claude-code && cd .. && bash scripts/wire.sh`. Before composing, `ls agent-factory/projects/` must still list every project the machine's overlay gates (the private `research-desk` is NOT recomposed here).
- [ ] 6.4 Verify on the machine: `ls ~/.claude/agents | grep context-engineer` shows `core-context-engineer.md`; a second `wire.sh` run reports no changes; `bash scripts/wire.sh --check` exits 0.
- [ ] 6.5 Remove the worktree and local branch only after the PR is MERGED: `git worktree remove <path>`, `git branch -D <branch>` after confirming it is in `origin/main`; `git worktree prune`.

Acceptance: `core-context-engineer` is wired on the machine and the second wire run is a no-op.
