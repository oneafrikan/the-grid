<!-- charter-trailhead -->
## Start here

- Session start: read `PURPOSE.md` and `MAP.md`.
- Before acting (editing, committing, opening a PR): read `GUARDRAILS.md`.
- Recording a claim or filing a signal: read `signals/README.md` (stages, warrant rule, file format).
- Before building a new capability or adding a dependency: read `RELATED.md` if it exists.
- Everything else: find it through `MAP.md` ("Read when" column); do not read what it does not point you to.
<!-- /charter-trailhead -->

# the-grid — Claude context

the-grid is Gareth's wiring hub for the AI-agent ecosystem — Claude / OpenClaw /
Paperclip / Hermes / opencode and friends. **It is not skills-only**: skills are
the first asset type it wires, but the remit is broader (commands, agents, MCP
servers, plugins, configs may follow). It owns some assets directly and pulls many
more from sibling repos via git submodules.

## Adding a skill

Create `skills/<name>/SKILL.md` (a skill dir at the repo root is not wired). Frontmatter requires `name:` and `description:`. Then run `bash scripts/wire.sh`.

A `SKILL.md` over 4,000 bytes is split: keep the purpose and step skeleton, move reference detail into `sections/<topic>.md` (plain markdown, no frontmatter, <= 6,000 bytes, kebab-case).
Index each file in a `## Sections` block of `SKILL.md`, one `- sections/<file>: read when ...` line per file; `wire.sh` symlinks the whole skill dir, so `sections/` travels with it.
`python3 scripts/budget.py --check` (part of the gate) fails on an unindexed or missing section, a section over 6,000 bytes, or a `SKILL.md` over `skill_body_max_bytes`.

## Canon is never merged on green

**A PR that changes any path under `knowledge/canon/` is never merged under the standing approval to merge on green CI plus independent QA; a human merges it** (`GUARDRAILS#G7`).
Before merging, the QA agent or session runs `git diff --name-only origin/main...HEAD -- knowledge/canon` (the same command as the PR template checkbox).
Non-empty output means a human merges: stop and leave the PR open.

## Worktree hygiene

Agents and sessions must not leave stale worktrees or local branches behind.

- Remove what you created before finishing, once its PR is merged or abandoned: `git worktree remove <path>`.
- Delete the branch with `git branch -D <branch>` only after confirming the PR is MERGED or the branch is fully contained in `origin/main`.
- Never leave scratch worktrees under `.claude/worktrees` or `/tmp` registered in `git worktree list`; run `git worktree prune`.
- Session start: run `git worktree list`, report and prune stale entries. Session end: list any worktree left open and why.
- Untracked `__pycache__` is not a reason to keep a worktree.
- A markdown-only change needs no worktree and no submodule init (`BEHAVIOUR.md`). A fresh worktree (code, scripts, tests, CI) has empty submodule dirs and no `agent-factory/.venv`. The pre-commit hook inits `tests/lib/bats-core` itself; any other submodule a test needs (for example `repos/ecc`) and the venv (`cd agent-factory && python3 -m venv .venv && .venv/bin/pip install -r requirements.txt`) are yours to set up. Venv-gated tests skip on a plain `bats` run but fail under the gate (`GRID_REQUIRE_VENV=1`). To commit without either, use `GRID_SKIP_HOOK=1` and run the gate before readying the branch.

## Recompose agents safely
3. Refresh agents — but only if the pull touched anything under
   `agent-factory/` (composed output there is git-ignored, so a pull alone
   never updates it). Check with:
   `git diff --stat HEAD@{1} HEAD -- agent-factory/`.
   If it shows changes: `cd agent-factory && .venv/bin/python compose.py
   examples/core.yaml --target claude-code && .venv/bin/python compose.py
   examples/grid.yaml --target claude-code && .venv/bin/python compose.py
   examples/finance-desk.yaml --target claude-code && .venv/bin/python compose.py
   examples/learning-desk.yaml --target claude-code && cd ..` (recompose all
   four public projects — cheap even if only one actually changed).
   If it shows nothing: skip this step.

   > ⚠ **Recompose every private project too, in the same pass.** A change to
   > `agent-factory/_core/` or `compose.py` affects *all* projects, but only the
   > four public configs are listed above. `compose.py` **overwrites**
   > `projects/<name>/` wholesale — so recomposing the public set while a
   > private project's roles are unreachable (repo not cloned,
   > `GRID_PRIVATE_ROLES_DIR` unset) silently destroys that project's composed
   > output, and the next `wire.sh` tears down its symlinks. This has already
   > happened once. Check `ls agent-factory/projects/` against
   > `machines/<host>.local.txt` **before** recomposing; if a `project:` gate
   > there has no matching config you can reach, stop and fix that first.

## Read when
- `CONVENTIONS.md` before writing code, tests or a commit (gate, tests, machine update, catalogue, sibling repos, reconcile); `DESIGN.md` before changing structure, `wire.sh`, a factory or the key-files list.
- `LEARNINGS.md` and `DECISIONS.md` before repeating a past mistake or reopening a settled choice; `UNSORTED.md` holds text the retrofit could not place; the original CLAUDE.md is in `docs/archive/`.
