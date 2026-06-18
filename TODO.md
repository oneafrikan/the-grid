# the-grid TODO

**Current focus:** `agent-factory/` composes AI dev-team agents from a single config. The **Claude Code** delivery target is done — all **18 roles** (expanded from 12: +seo, +security-reviewer, +designer, +data-scientist, +project-manager, +researcher) compose to CC skills (orchestrators) + subagents (specialists) and wire live via `wire.sh` (2026-06-16). Next: OpenClaw + Paperclip targets, stack overlays, machine manifest, skills population (deferred to OpenClaw work). See `LOGS/2026-06-16-handoff-agent-factory.md` + `agent-factory/docs/role-skill-map.md`.

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

- [x] **1. Scaffold the factory** — `agent-factory/` structure (`_core/`, `roles/`, `stacks/`, `skills/`, `projects/`), `compose.py`, `factory.schema.yaml`. Done.
- [x] **2. Clarify `agent-factory/` vs `skills-factory/`** — resolved: two separate factories. `skills-factory/` builds skills (Karpathy loop, elsewhere) → dropped into `agent-factory/skills/`; `agent-factory/` composes teams.
- [x] **3. Port the Tech Lead role** — `roles/tech-lead/{SOUL,SKILL,MEMORY}.md`, stack-agnostic with `<!-- STACK: -->` injection points.
- [x] **3b. Flesh `compose.py`** — engine renders/merges/writes an agent idempotently; PyYAML in `.venv` (see `requirements.txt`).
- [x] **3c. Adopt the live 5-file agent model** — verified the running OpenClaw on guide-server uses SOUL/IDENTITY/AGENTS/USER/MEMORY + skills (playbook's 3-file model is outdated). Re-cut `_core` (added IDENTITY/AGENTS/USER bases) + Tech Lead to the 5-file form; round-trip re-proven OpenClaw-native with `examples/tech-lead.yaml`. Handoff = async signal files. See memory `live-openclaw-agent-model`.
- [ ] **4. Build emitters + wiring for all THREE delivery targets** (production + unattended; `compose.py` is the multi-target compiler, one 5-file source → emitter + wiring per target):
  - [x] **(b) Claude Code interactive** (wilderness) — DONE (2026-06-16, commits `875d84d`, `96b4dea`). `compose.py --target claude-code`: orchestrator → CC skill (`~/.claude/skills/`), specialist → CC subagent (`~/.claude/agents/`). `wire.sh` wires both. `/tech-lead` boots + runs e2e. Built first per Gareth's call (overrode "OpenClaw first").
  - [ ] **(a) OpenClaw** (guide-server): 5 files → workspace + `openclaw.json` wiring. Prove load with a NEW test workspace, never a live agent. Deferred.
  - [ ] **(c) Async & autonomous via Paperclip** (either runtime): wire the paperclip base skill (`paperclip: true`) into every agent; trigger via Paperclip heartbeat (OpenClaw, exists) or scheduled/headless CC run; handoff async (signal files / PR+webhook). Prove an unattended task pickup→run→handoff→exit.
  - Test each ACTUALLY loads/runs, not just renders — the real end-to-end "agent that runs".
- [x] **5. Port remaining roles** — DONE (2026-06-16, commit `96b4dea`). All 12 roles on the 5-file model: tech-lead, ceo-orchestrator, product-manager, backend-dev, frontend-dev, qa-engineer, devops, data-engineer, data-analyst, copywriter, ad-copy, growth-hacker. The 11 new ones written by parallel sub-agents off the tech-lead (orchestrator) + backend-dev (specialist) exemplars. `examples/full-team.yaml` composes all 12.
- [ ] **6. Machine manifest** — one file per machine (`machines/<host>`), shared baseline + per-machine overlay, listing BOTH wired skills and active agents. Bash-parseable (don't force YAML into wire.sh).
- [ ] **7. Flesh stack overlays** — `stacks/*` are `stack.yaml` stubs with empty `fragments`. Add LAMP + others. Overlays currently append to `AGENTS.md`; keyed inline injection is a later upgrade.
- [ ] **8. Pull skills from repos → `agent-factory/skills/`** — DEFERRED to the OpenClaw-target work (decided 2026-06-16). Mechanism chosen: **symlink** from the already-present `repos/` submodules (all reference-doc repos are now submodules). The per-role skill map is in `agent-factory/docs/role-skill-map.md §3`. Rationale for deferring: the live Claude Code subagents already get ecosystem skills via `wire.sh`; `agent-factory/skills/` only matters for compose-validation of declared bolt-ons + the OpenClaw target's by-name wiring.
- [x] **9. Update CLAUDE.md** — DONE (2026-06-16): documented the agent loading model (5-file source → CC skills/subagents) and `wire.sh` agent wiring (`AGENTS_DIR`). `machines/` conventions still pending the manifest (item 6).

---

## Known issues with the build prompt

> File: `prompts/2026-06-13-openclaw-lamp-team-prompt.md`
> The LAMP content generation task is correct. Four architectural gaps need surgical fixes before using this prompt in a fresh session.
>
> **NOTE (2026-06-16): likely superseded.** Role content was NOT generated via this
> monolithic prompt — it was ported role-by-role via sub-agents off the tech-lead +
> backend-dev exemplars, with async-only handoff enforced. Keep this only if the
> prompt is still wanted for a from-scratch LAMP run; otherwise it can be retired.

- [ ] **ACP missing** — prompt tells Opus to write SKILL.md files targeting Claude Code as runtime. Skills should target the ACP surface (Claude Code today, OpenCode/Codex tomorrow). Add one sentence to the constraints section.
- [ ] **MEMORY.md wrong model** — prompt describes MEMORY.md as a flat markdown file. The-grid uses gbrain (queryable, shared, per-repo trust tiers). Reframe Opus output as a gbrain seed, or flag it as "Phase 3 — gbrain replaces this."
- [ ] **Handoff protocol wrong** — prompt references `sessions_spawn()` for agent-to-agent handoffs (live links). Grid handoff is PR + webhook, async. Direct contradiction; will produce wrong output.
- [ ] **LAMP isolation constraints missing** — parallel LAMP agents clash on ports and databases. Each worktree needs its own MySQL schema and port range. DevOps SKILL.md will be wrong without this.

---

## Open questions

- ~~Which agent to build first?~~ RESOLVED (2026-06-16): all 12 roles ported. Order was tech-lead → backend-dev → the rest in parallel.
- ~~Does wire.sh wire agent skills into `~/.claude/skills/`?~~ ANSWERED (2026-06-16): `wire.sh` wires orchestrator **skills** into `~/.claude/skills/` and specialist **subagents** into `~/.claude/agents/`, from `agent-factory/projects/*/_claude-code/` output. Open follow-up: a machine manifest to gate *which* composed agents wire per host (today it wires every composed project).
- `machines/wilderness.yaml` format — YAML assumed, not confirmed. TOML or another format?
- Manifest filename inside an agent folder — `agent.yaml` (OpenGAP convention) or something else?
- Add OpenGAP (`open-gitagent/opengap`) and soulspec (`clawsouls/soulspec`) as reference submodules now, or after the first agent is built?
- ~~`agent-factory/` vs `skills-factory/`~~ RESOLVED (see Now/Next #2): two separate factories. `agent-factory/` is built out and composes teams; `skills-factory/` builds skills elsewhere and drops them into `agent-factory/skills/`.

---

## Known issues

- [ ] **`repos/leoyeai` out of sync (2026-06-18, wilderness)** — working tree is a stale/divergent checkout (`8099077`, v0.14.0) with ~2,271/1,710 lines of *unreviewed* uncommitted edits (stripe/payment/amazon-checkout/siyuan/zyfai), some moving backwards (stripe HEARTBEAT 2.8.0→2.3.0). Grid HEAD records `4c6d5d4`. Deliberately NOT synced per Gareth ("not worried about it right now"). Do not `submodule update --force` it or discard the edits without asking. Until resolved, `wire.sh` on the affected machine shows a 1-line leoyeai count diff in SKILLS.md (harmless). See `LOGS/2026-06-18-context.md`.

## Backlog

- [ ] `bootstrap.sh` — clone the-grid, init submodules, run wire.sh in one command (document one-liner in README)
- [ ] `check-grid.sh` — quick health check: run bats suite and report broken symlinks without full bats output
- [ ] Pre-commit git hook — run bats before commit so bad skill format never lands in main
- [ ] Fix stale test count in BOOTSTRAP.md ("All 17 tests" → should be 30)
- [ ] ~~Commit the `wired-submodules.txt` comment-out tweak~~ OBSOLETE (2026-06-16): forge's commit `c012fde` rewrote the file to per-skill granularity, superseding the whole-repo comment-out. The old tweak is parked in `git stash@{0}` — `git stash drop` when confirmed.
