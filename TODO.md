# the-grid TODO

> **Open work now lives in GitHub Issues** — they are the current state of play.
> Browse: `gh issue list --repo oneafrikan/the-grid` (or the repo's Issues tab).
> This file keeps only the **issue map** (below) + the **Done** history (a log of
> what shipped, not a tracker). Add new work as an issue, not here.

**Current focus (2026-08-04):** the-grid is being shared with other people. That
makes **#24** (De-Gareth audit: split framework from personal config) and **#25**
(public-facing README + quickstart) the gating work — everything else is
downstream of the repo being usable by someone who isn't Gareth.

Behind that: `agent-factory` is a multi-target compiler with the **Claude Code**
target shipped. The next targets (**#31** opencode, **#33** Codex, **#32** Gemini,
**#30** Cursor) are scoped from the 2026-07-24 portability research but not
built. OpenClaw/Paperclip emitters (**#3**, **#4**) remain the deeper lift.

---

## Open issues (map)

Regenerate with:
`gh issue list --state open --limit 50 --json number,title,labels`

### Public-readiness (gating)

| # | Title | Labels |
|---|-------|--------|
| [#24](https://github.com/oneafrikan/the-grid/issues/24) | De-Gareth audit: split framework from personal config | ready-for-human, severity:medium |
| [#25](https://github.com/oneafrikan/the-grid/issues/25) | Public-facing README + adopt-the-grid quickstart | docs, ready-for-agent |
| [#37](https://github.com/oneafrikan/the-grid/issues/37) | 22 submodules use SSH clone URLs — fresh-machine bootstrap can fail | wiring, infra, ready-for-agent |

### agent-factory — new compose targets

| # | Title | Labels |
|---|-------|--------|
| [#31](https://github.com/oneafrikan/the-grid/issues/31) | New compose.py target: opencode | ready-for-agent |
| [#33](https://github.com/oneafrikan/the-grid/issues/33) | New compose.py target: OpenAI Codex CLI | ready-for-human |
| [#32](https://github.com/oneafrikan/the-grid/issues/32) | New compose.py target: Gemini CLI | ready-for-human |
| [#30](https://github.com/oneafrikan/the-grid/issues/30) | Cursor: validate zero-cost reuse of claude-code subagent output | ready-for-agent |
| [#36](https://github.com/oneafrikan/the-grid/issues/36) | New compose.py target: portable single-file personas for chat-UI Projects | ready-for-human |
| [#34](https://github.com/oneafrikan/the-grid/issues/34) | Amp: verify custom-agent mechanism before scoping a target | deferred, needs-info |
| [#35](https://github.com/oneafrikan/the-grid/issues/35) | Continue: decide skip or reframe — doesn't map to the roster model | deferred, question |
| [#3](https://github.com/oneafrikan/the-grid/issues/3) | agent-factory target: OpenClaw emitter (guide-server) | needs-info |
| [#4](https://github.com/oneafrikan/the-grid/issues/4) | agent-factory target: async/autonomous via Paperclip | needs-info, severity:medium |

Implementation plan for #3/#4, scoped to a curated orchestrator roster (not a
full-roster port) and chunked into single-session specialist work:
`agent-factory/docs/openclaw-paperclip-targets-plan.md`.

### agent-factory — everything else

| # | Title | Labels |
|---|-------|--------|
| [#5](https://github.com/oneafrikan/the-grid/issues/5) | agent-factory: flesh stack overlays (LAMP + others) | needs-info |
| [#6](https://github.com/oneafrikan/the-grid/issues/6) | agent-factory: populate `skills/` from repos submodules | needs-human |
| [#13](https://github.com/oneafrikan/the-grid/issues/13) | Optional: deepen growth-hacker to marketing-director orchestrator | backlog |
| [#20](https://github.com/oneafrikan/the-grid/issues/20) | Inject LEARNINGS.md into composed agents at compose time | ready-for-human |
| [#23](https://github.com/oneafrikan/the-grid/issues/23) | compose.py golden-output conformance tests | ready-for-agent |

### Feedback loops & dogfooding

| # | Title | Labels |
|---|-------|--------|
| [#18](https://github.com/oneafrikan/the-grid/issues/18) | skill-scout autonomy: scheduled scout → PR proposals against baseline | ready-for-agent |
| [#19](https://github.com/oneafrikan/the-grid/issues/19) | Close the learnings loop: mine-learnings output → candidate skills | ready-for-agent |
| [#16](https://github.com/oneafrikan/the-grid/issues/16) | Create agent self-improving capability | needs-info |
| [#21](https://github.com/oneafrikan/the-grid/issues/21) | Factory chain e2e: one command from idea → staffed, looping project | ready-for-human |
| [#22](https://github.com/oneafrikan/the-grid/issues/22) | Dogfood milestone: ship one real feature via /grid-ceo-orchestrator | needs-info |

### Specs, docs, backlog

| # | Title | Labels |
|---|-------|--------|
| [#38](https://github.com/oneafrikan/the-grid/issues/38) | Evaluate OpenSpec stores for cross-repo planning (+ steal `--remote`) | deferred, ready-for-human |
| [#7](https://github.com/oneafrikan/the-grid/issues/7) | Decide fate of the LAMP build prompt (likely superseded) + 4 gaps | docs, ready-for-human |
| [#12](https://github.com/oneafrikan/the-grid/issues/12) | Add OpenGAP + soulspec as reference submodules | ready-for-human |
| [#29](https://github.com/oneafrikan/the-grid/issues/29) | finance-agents-base: implement Layer-1 guardrail/rules.py (hard-limit veto) | ready-for-human, severity:medium |

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
- [x] **project-factory: `lamp-agent-base` template** — DONE 2026-07-03. Third template, a different family from the two Python agent apps: an agent-injection kit for an *existing* PHP/MySQL/Apache repo, cut in retrofit mode. `CLAUDE.md` (stack conventions) + working, idempotent `scripts/worktree-{setup,teardown}.sh` + `db-migrate.sh` that give each git worktree its own MySQL schema + port (deterministic from worktree path) — closes the "LAMP isolation missing" gap from issue #7.
- [x] **project-factory: `_common/` session-continuity layer** — DONE 2026-07-03. Refactored `CONTEXT.md`/`LEARNINGS.md`/`handoffs/`/the issue-loop pairing prompt out of `lamp-agent-base` into `templates/_common/`, cut into every template by `cut-project.sh` (common pass, then template pass — same copy-if-absent/skip-if-differs rule; `_common` filtered out of the template picker via leading underscore). Assumes every cut project ends up with a GitHub issue backlog, an `issue-loop` instance, and cross-session handoffs, so that shape is now written once instead of per-template. Added the missing `CLAUDE.md` to `python-agent-base` and `python-astro-content-agent` too (previously had none). Verified seed mode for all three templates, plus a retrofit collision check (`_common`'s `CONTEXT.md` correctly left a pre-existing one untouched). Caught and avoided a footgun: a `_common/README.md` would have collided with every template's own root `README.md` (common copies first) — documented `_common` in `project-factory/README.md` instead.
- [x] **project-factory: `agents` naming convention + `finance-agents-base` template** — DONE 2026-07-03. Renamed `python-agent-base` → `python-agents-base` and `lamp-agent-base` → `lamp-agents-base` (any real project ends up with more than one operational agent — the name and the `src/` shape should say so); restructured `python-agents-base`'s `src/agent/` into `src/agents/{orchestrator,worker,shared}/`. Left `python-astro-content-agent` singular — genuinely one agent, one job. Fourth template, `finance-agents-base`: a generic personal-finance agent-team scaffold (watcher/analyst/strategist/guardrail/scribe roles, a human approval gate, a versioned `POLICY.template.md`), assessed against an OpenClaw portfolio-monitoring design doc and deliberately generalized rather than templating that doc verbatim — it was one specific instance (retirement portfolio monitoring, OpenClaw-native), not a reusable base; no thresholds or trading logic baked in, `guardrail/rules.py` is pure code loaded from `POLICY.md`. Caught one design mistake before committing: `.gitignore`d `POLICY.md` at first, then corrected it — a version-controlled policy document is the whole point (auditability), unlike `.env`. Verified all four templates seed cleanly (0 skipped) after the rename.
- [x] **OpenSpec adoption** — DONE 2026-08-03/04 (`f0d3d3f`, `c8d1d1f`, `05d6986`, `ad41cc4`). Tracked `Fission-AI/openspec` as a submodule and wired its 12 workflow skills baseline-wide (whole-repo entry minus the maintainer-only `release-openspec`; `catalog.sh` gained subtraction support so `SKILLS.md` stops advertising skills `wire.sh` won't link). Deliberately **no fifth factory** — OpenSpec already is the spec factory, so the-grid adds two thin layers instead: `project-factory/templates/_common/SPECS.md` (convention + agent instructions, on every seed *and* retrofit, so spec-driven is the default rather than a per-project decision) and a boot-sequence check in `agent-factory/_core/AGENTS_base.md` (one edit → every composed agent, conditional so non-spec repos are untouched). Added `spec-scout` (adoption + drift audit, survey-only) and `openspec-help` (reference card for all 12). CLI installed and verified end-to-end. Two assumptions corrected by testing: `openspec init` is optional (`openspec new change` bootstraps `openspec/` itself), and the `core` profile gates which skills `init` scaffolds locally, not which CLI commands work.
- [x] **`scripts/sources.sh` + `docs/SOURCES.md`** — DONE 2026-08-03 (`c8d1d1f`). Generated one-line-per-submodule upstream index with tier from the baseline, deterministic like `catalog.sh`. `--check` HEADs every URL as a rot detector (non-zero exit, CI-gateable) — caught `nowork-studio/toprank` renamed to `NotFair` on its first run (fixed `076f0d3`) and surfaced that 22 of 32 submodules use SSH clone URLs (issue **#37**).
- [x] **`docs/model-selection.md`** — DONE 2026-08-03 (`c8d1d1f`). Decision-first "which model for which job", prices verified against provider primaries, worked cost maths, dated expiry watchlist, explicit known-gaps section. Three findings worth keeping: SWE-bench Verified is contaminated and 100% vendor-self-reported (use Terminal-Bench 2.1 / SWE-bench Pro); the "cheap models burn more turns" thesis has **no** published cross-model study behind it; break-even on the worked example is ~4 retries, not 2. `mine-learnings` now routes model-routing learnings into that doc, since real-history observations are the only data the-grid will ever have on that gap.
- [x] **Doc resync for sharing** — DONE 2026-08-04 (`ad41cc4`). README/USAGE/BOOTSTRAP brought current: OpenSpec, private projects, help skills, roadmap separating shipped targets from scoped-but-unbuilt ones, and a status section setting fork-don't-depend expectations. BOOTSTRAP gained a prerequisites table (Node >= 20.19.0 was undocumented) and the openspec CLI as an explicit step. Does **not** close #24/#25.
- [x] **Private-project mechanism documented + hardened** — DONE 2026-08-04. `compose.py` overwrites `projects/<name>/` wholesale, so recomposing the public projects while a private project's roles are unreachable destroys its composed output and the next `wire.sh` removes its symlinks. This happened for real this session. Warning now in CLAUDE.md, README, USAGE and BOOTSTRAP; mechanism documented publicly, names never.
- [x] **#24/#39 de-Gareth audit: LOGS/ + personal manifests** — DONE 2026-09-11. `LOGS/` (dev journal) moved to a separate private repo (`~/.the-grid-private/LOGS/`), symlinked back locally, stripped from this repo's git history entirely (`git filter-repo --path LOGS --invert-paths`, force-pushed). `baseline-submodules.txt` and `machines/{forge,guide-server,scout,wilderness}.txt` untracked going forward (still present on disk; seeded on a new machine from the now-tracked `baseline-submodules.example.txt` / `machines/example.txt`) — history left as-is, judged low-sensitivity. `setup-gareth-skills` renamed to `setup-repo-skills` (cosmetic, never actually personal). `BOOTSTRAP.md`/`scripts/bootstrap.sh`/`CLAUDE.md` updated to match; 38/38 tests green. Every other the-grid clone (forge, scout, guide-server) needs `git fetch && git reset --hard origin/main` before its next commit — tracked in `CLAUDE.md`'s pending-migration checklist. Not yet done: closing #24/#39 on GitHub (separate explicit step).
