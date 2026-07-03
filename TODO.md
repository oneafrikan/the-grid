# the-grid TODO

> **Open work now lives in GitHub Issues** — they are the current state of play.
> Browse: `gh issue list --repo oneafrikan/the-grid` (or the repo's Issues tab).
> This file keeps only the **issue map** (below) + the **Done** history (a log of
> what shipped, not a tracker). Add new work as an issue, not here.

**Current focus:** `agent-factory/` composes AI dev-team agents from a single
config. The **Claude Code** target is done. Next, in Gareth's sequencing:
per-machine manifests (**#1**) + agent naming (**#2**) **before** the OpenClaw /
Paperclip emitter targets (**#3**, **#4**).

---

## Open issues (map)

| # | Title | Labels |
|---|-------|--------|
| [#1](https://github.com/oneafrikan/the-grid/issues/1) | Per-machine manifests: gate wired skills + composed projects by hostname | agent-factory, wiring |
| [#2](https://github.com/oneafrikan/the-grid/issues/2) | Composed-agent naming: project-slug prefix for `/` discoverability | agent-factory |
| [#3](https://github.com/oneafrikan/the-grid/issues/3) | agent-factory target: OpenClaw emitter (guide-server) | agent-factory |
| [#4](https://github.com/oneafrikan/the-grid/issues/4) | agent-factory target: async/autonomous via Paperclip | agent-factory |
| [#5](https://github.com/oneafrikan/the-grid/issues/5) | agent-factory: flesh stack overlays (LAMP + others) | agent-factory |
| [#6](https://github.com/oneafrikan/the-grid/issues/6) | agent-factory: populate `skills/` from repos submodules | agent-factory |
| [#7](https://github.com/oneafrikan/the-grid/issues/7) | Decide fate of the LAMP build prompt (likely superseded) + 4 gaps | docs |
| [#8](https://github.com/oneafrikan/the-grid/issues/8) | repos/leoyeai out of sync on wilderness (deferred — do not force-sync) | deferred |
| [#12](https://github.com/oneafrikan/the-grid/issues/12) | Add OpenGAP + soulspec as reference submodules | backlog |
| [#13](https://github.com/oneafrikan/the-grid/issues/13) | Optional: deepen growth-hacker to marketing-director orchestrator | agent-factory, backlog |
| [#15](https://github.com/oneafrikan/the-grid/issues/15) | automation-factory: `instantiate.sh` — machine-profiled deployment of issue-loop | automation-factory |

---

## Status: Done (history — not a tracker)

- [x] Write README.md and CLAUDE.md
- [x] Audit and scrub repo for personal info before going public
- [x] Restructure into `skills/`, `agents/`, `machines/`, `scripts/`
- [x] Move wire.sh, catalog.sh, reconcile.sh into `scripts/`; update all references
- [x] 30/30 tests green; pushed to `oneafrikan/the-grid`
- [x] Research agent-as-folder prior art (OpenGAP, soulspec); design agent architecture
- [x] Document factory folder structure + compose config example
- [x] **1. Scaffold the factory** — `agent-factory/` structure, `compose.py`, `factory.schema.yaml`
- [x] **2. Clarify `agent-factory/` vs `skills-factory/`** — two separate factories
- [x] **3. Port the Tech Lead role** — stack-agnostic with injection points
- [x] **3b. Flesh `compose.py`** — idempotent render/merge/write
- [x] **3c. Adopt the live 5-file agent model** (SOUL/IDENTITY/AGENTS/USER/MEMORY + skills)
- [x] **4(b). Claude Code interactive target** — DONE 2026-06-16 (`875d84d`, `96b4dea`). `/tech-lead` boots + runs e2e.
- [x] **5. Port remaining roles** — all 12 roles on the 5-file model (`examples/full-team.yaml`)
- [x] **9. Update CLAUDE.md** — agent loading model + `wire.sh` agent wiring
- [x] **Roster generation** — DONE 2026-06-19 (`ab1b6e4`). Rosters generated from `delegates_to`, injected at `{{ROSTER_TABLE}}`, symmetrically validated. growth-hacker promoted to 3rd orchestrator. Doc sweep (`f08b193`).
- [x] Fix stale test count in BOOTSTRAP.md (now "All 30 tests")
- [x] **#1 Per-machine manifests** — already shipped (baseline + `machines/<host>.txt` overlays + `project:` gating in wire.sh). Closed as stale 2026-06-29.
- [x] **#14 stash drop** — stash already empty; closed as moot 2026-06-29.
- [x] **#9/#10/#11 infra scripts** — DONE 2026-06-29 (`876fe4b`). `bootstrap.sh` (one-command setup), `check-grid.sh` (fast health check), `.githooks/pre-commit` (bats gate, activated via core.hooksPath). README updated.
- [x] **project-factory scaffolded** — DONE 2026-07-03. Fourth factory (sibling to `skills-factory/`, `agent-factory/`, `automation-factory/`): `scripts/cut-project.sh` seeds a new project or retrofits an existing one from a template, auto-detecting mode from whether the target is empty (never overwrites a differing file either way). Two independent starter templates, both structural stubs only — business logic is a later, separate pass: `python-agent-base` (generic default) and `python-astro-content-agent` (markdown -> Astro pages).
