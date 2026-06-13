# the-grid TODO

**Current focus:** evolving the-grid from a skills-wiring hub into a full agent-composition / factory hub — building `agent-factory/` so a single compose config can produce a complete LAMP team.

---

## Status: Done

- [x] Write README.md and CLAUDE.md
- [x] Audit and scrub repo for personal info before going public (BOOTSTRAP.md, README.md)
- [x] Restructure into `skills/`, `agents/`, `machines/`, `scripts/`
- [x] Move wire.sh, catalog.sh, reconcile.sh into `scripts/`; update GRID_DIR detection, inter-script calls, all test references
- [x] 30/30 tests green; pushed to `oneafrikan/the-grid`
- [x] Research agent-as-folder prior art (OpenGAP, soulspec); design agent architecture
- [x] Document factory folder structure (`docs/architect-agent-factory`) and compose config example (`docs/architect-agent-composition.yaml`)

---

## Now / Next — build the factory

- [ ] **1. Scaffold the factory** — create `agent-factory/` folder structure: `_core/`, `roles/`, `stacks/`, `skills/`, `projects/`; add stub `compose.py` and `factory.schema.yaml`. No agent content yet — get the mechanics in place.
- [ ] **2. Clarify `agent-factory/` vs `skills-factory/`** — two empty dirs exist at root (`agent-factory/`, `skills-factory/`); docs describe a single `agent_factory/`. Decide: one factory or two? Merge or keep separate? (See Open Questions.)
- [ ] **3. Port the Tech Lead role** — most complex and most reusable; once it works the other roles are variations. Add `roles/tech-lead/` with SOUL.md, IDENTITY.md, AGENTS.md, USER.md stubs.
- [ ] **4. Add LAMP stack overlay** — `stacks/lamp/` with PHP/MySQL/Apache/WordPress constraints. Validate that compose output is valid for OpenClaw.
- [ ] **5. Add agents iteratively** — one role at a time; test compose output before moving to the next.
- [ ] **6. Pull skills from repos** — once factory structure is solid, pull skill files from GitHub repos in `docs/reference-repos.md` into `agent-factory/skills/`.
- [ ] **7. Create `machines/wilderness.yaml`** — declare which agents are active on this machine (agree with Gareth which agent to build first).
- [ ] **8. Stub first agent in `agents/`** — four soulspec files (SOUL.md, IDENTITY.md, AGENTS.md, USER.md) + `tools/` and `skills/` subdirs.
- [ ] **9. Update CLAUDE.md** — document `agents/`, `machines/`, `scripts/` conventions and the new agent loading model.

---

## Known issues with the build prompt

> File: `prompts/2026-06-13-openclaw-lamp-team-prompt.md`
> The LAMP content generation task is correct. Four architectural gaps need surgical fixes before using this prompt in a fresh session.

- [ ] **ACP missing** — prompt tells Opus to write SKILL.md files targeting Claude Code as runtime. Skills should target the ACP surface (Claude Code today, OpenCode/Codex tomorrow). Add one sentence to the constraints section.
- [ ] **MEMORY.md wrong model** — prompt describes MEMORY.md as a flat markdown file. The-grid uses gbrain (queryable, shared, per-repo trust tiers). Reframe Opus output as a gbrain seed, or flag it as "Phase 3 — gbrain replaces this."
- [ ] **Handoff protocol wrong** — prompt references `sessions_spawn()` for agent-to-agent handoffs (live links). Grid handoff is PR + webhook, async. Direct contradiction; will produce wrong output.
- [ ] **LAMP isolation constraints missing** — parallel LAMP agents clash on ports and databases. Each worktree needs its own MySQL schema and port range. DevOps SKILL.md will be wrong without this.

---

## Open questions

- Which agent to build first — QA engineer, backend dev, or writer? (Gareth to decide before step 7 above.)
- Does wire.sh wire agent skills into `~/.claude/skills/`? Or is agent loading a separate mechanism (e.g. SOUL.md injected into system prompt at session start)?
- `machines/wilderness.yaml` format — YAML assumed, not confirmed. TOML or another format?
- Manifest filename inside an agent folder — `agent.yaml` (OpenGAP convention) or something else?
- Add OpenGAP (`open-gitagent/opengap`) and soulspec (`clawsouls/soulspec`) as reference submodules now, or after the first agent is built?
- **`agent-factory/` vs `skills-factory/`** — two empty dirs at root; `docs/architect-agent-factory` describes a single `agent_factory/`. Are these two separate factories, or one? If one, which name wins and what does the other do?

---

## Backlog

- [ ] `bootstrap.sh` — clone the-grid, init submodules, run wire.sh in one command (document one-liner in README)
- [ ] `check-grid.sh` — quick health check: run bats suite and report broken symlinks without full bats output
- [ ] Pre-commit git hook — run bats before commit so bad skill format never lands in main
- [ ] Fix stale test count in BOOTSTRAP.md ("All 17 tests" → should be 30)
- [ ] Commit the `wired-submodules.txt` changes (anthropic, jeffallan, superpowers commented out) — excluded from last session's commits deliberately; needs a decision first
