# Retrofit coverage: CLAUDE.md

- Date: 2026-11-20
- Result: PASS (168 of 168 blocks accounted)
- Source sha256: 162d9ef87cf31dedfa9e2fba6d04901ebb3aebf2f7b509d05f18cdc5509aa14f
- Checked block by block: each source block must equal a block of its destination, ignoring only CRLF and trailing blanks.

| Block | Lines | Kind | Preview | Went to | Status |
|---|---|---|---|---|---|
| B001-d420 | 1-1 | comment | <!-- charter-trailhead --> | keep | ok |
| B002-aaa8 | 2-2 | heading | ## Start here | keep | ok |
| B003-ba14 | 4-4 | item | - Session start: read `PURPOSE.md` and `MAP.md`. | keep | ok |
| B004-bfbc | 5-5 | item | - Before acting (editing, committing, opening a PR): read... | keep | ok |
| B005-129e | 6-6 | item | - Recording a claim or filing a signal: read `signals/REA... | keep | ok |
| B006-d334 | 7-7 | item | - Before building a new capability or adding a dependency... | keep | ok |
| B007-66b2 | 8-8 | item | - Everything else: find it through `MAP.md` ("Read when" ... | keep | ok |
| B008-922d | 9-9 | comment | <!-- /charter-trailhead --> | keep | ok |
| B009-4487 | 11-11 | heading | # the-grid — Claude context | keep | ok |
| B010-8f98 | 13-17 | para | the-grid is Gareth's wiring hub for the AI-agent ecosyste... | keep | ok |
| B011-8441 | 19-23 | para | `wire.sh` symlinks **skills** into `~/.claude/skills/` so... | DESIGN.md | ok |
| B012-8fc0 | 25-31 | item | - **Wired** — a small curated allowlist whose skills are ... | DESIGN.md | ok |
| B013-a51c | 32-34 | item | - **Library** — everything else: indexed in `SKILLS.md` a... | DESIGN.md | ok |
| B014-a259 | 36-36 | heading | ## What lives where (ownership principle) | DESIGN.md | ok |
| B015-f56f | 38-41 | item | - **`skills/<name>/` is for skills Gareth owns or has edi... | DESIGN.md | ok |
| B016-1964 | 42-44 | item | - **Everything else is managed upstream** in `repos/*` su... | DESIGN.md | ok |
| B017-9caf | 45-46 | item | - If a `skills/` copy is byte-identical to (or merely an ... | DESIGN.md | ok |
| B018-9081 | 47-49 | item | - When `skills/` and a submodule both provide the same sk... | DESIGN.md | ok |
| B019-32cc | 51-51 | heading | ## Key files | DESIGN.md | ok |
| B020-f541 | 53-53 | item | - `BOOTSTRAP.md` — **full machine boot sequence**: clone ... | DESIGN.md | ok |
| B021-ba2a | 54-55 | item | - `scripts/wire.sh` — the wiring script. Idempotent. Tear... | DESIGN.md | ok |
| B022-eae6 | 56-56 | item | - `scripts/uninstall.sh` — the kill switch: removes what ... | DESIGN.md | ok |
| B023-98be | 57-62 | item | - `baseline-submodules.txt` — the baseline allowlist of s... | DESIGN.md | ok |
| B024-9baf | 63-66 | item | - `machines/<hostname>.txt` — per-machine overlay layered... | DESIGN.md | ok |
| B025-7bb6 | 67-77 | item | - `LOGS/` — dev journal (handoffs/context from the `hando... | DESIGN.md | ok |
| B026-3095 | 78-78 | item | - `scripts/budget.py` + `docs/budget-target.json` — measu... | DESIGN.md | ok |
| B027-5db4 | 79-79 | item | - `scripts/usage/weekly.sh` + `scripts/usage/install-sche... | DESIGN.md | ok |
| B028-f339 | 80-80 | item | - `scripts/prune-report.sh` (wraps `scripts/usage/prune_r... | DESIGN.md | ok |
| B029-4176 | 81-85 | item | - `scripts/catalog.sh` — regenerates `SKILLS.md`: wired s... | DESIGN.md | ok |
| B030-412f | 86-86 | item | - `SKILLS.md` — generated index of the whole ecosystem. N... | DESIGN.md | ok |
| B031-1d17 | 87-87 | item | - `scripts/build-plugins.py` + `plugins/` + `docs/PLUGINS... | DESIGN.md | ok |
| B032-3dcf | 88-88 | item | - `scripts/translate-readme.sh` + `scripts/check-translat... | DESIGN.md | ok |
| B033-34ce | 89-92 | item | - `site-files.txt` + `scripts/stage-site.sh` — define wha... | DESIGN.md | ok |
| B034-9b77 | 93-95 | item | - `scripts/sources.sh` — regenerates `docs/SOURCES.md` (o... | DESIGN.md | ok |
| B035-23f0 | 96-100 | item | - `rules/` + `scripts/rules.py` — path-scoped rule packs ... | DESIGN.md | ok |
| B036-d36e | 101-111 | item | - `scripts/check-personal.sh` — scans the **tracked** tre... | DESIGN.md | ok |
| B037-113f | 112-114 | item | - `docs/model-selection.md` — which model for which job, ... | DESIGN.md | ok |
| B038-1ec8 | 115-117 | item | - `docs/business-tier/` — design for giving non-terminal ... | DESIGN.md | ok |
| B039-b63b | 118-118 | item | - `evals/` + `agent-factory/run_evals.py` — golden cases ... | DESIGN.md | ok |
| B040-3c74 | 119-119 | item | - `scripts/instantiate.sh` + `automation-factory/patterns... | DESIGN.md | ok |
| B041-5806 | 120-120 | item | - `_retired/` — archive, not gated, linted or deployed; r... | DESIGN.md | ok |
| B042-e26e | 121-121 | item | - `scripts/instincts.sh` — habit learning from your own s... | DESIGN.md | ok |
| B043-6f3d | 122-122 | item | - `scripts/run-record.sh` — appends one JSON line per age... | DESIGN.md | ok |
| B044-9583 | 123-123 | item | - `policy.yaml` — vetting policy read by `scripts/audit.p... | DESIGN.md | ok |
| B045-d585 | 124-124 | item | - `CURATION.md` — the human-readable trust record: a `###... | DESIGN.md | ok |
| B046-6b9a | 125-125 | item | - `scripts/audit.sh` / `scripts/audit.py` — the offline, ... | DESIGN.md | ok |
| B047-79c8 | 126-126 | item | - `agent-factory/models.yaml` — the one tier-to-model map... | DESIGN.md | ok |
| B048-85f9 | 127-127 | item | - `hooks/` + `agent-factory/deploy_hooks.py` — Claude Cod... | DESIGN.md | ok |
| B049-5feb | 128-128 | item | - `scripts/compose-goldens.sh` — golden-output check for ... | DESIGN.md | ok |
| B050-0d9a | 129-129 | item | - `agent-factory/user.public.yaml` — tracked neutral iden... | DESIGN.md | ok |
| B051-a144 | 130-130 | item | - `contexts/` — opt-in working-mode prompts (`dev.md`, `r... | DESIGN.md | ok |
| B052-6473 | 131-131 | item | - `tests/` — bats test suite. Run with `tests/lib/bats-co... | DESIGN.md | ok |
| B053-3f38 | 132-132 | item | - `repos/` — sibling skill repos as git submodules. Each ... | DESIGN.md | ok |
| B054-3640 | 133-133 | item | - `scripts/grid` — the submodule-free install CLI (`insta... | DESIGN.md | ok |
| B055-d996 | 134-134 | item | - `grid.yaml` — where wired skills come from: one `url` p... | DESIGN.md | ok |
| B056-db21 | 135-135 | item | - `grid.lock` — generated by `python3 scripts/grid lock` ... | DESIGN.md | ok |
| B057-d043 | 136-136 | item | - `~/.grid/installed.manifest` — machine-local ledger of ... | DESIGN.md | ok |
| B058-61fc | 137-137 | item | - `scripts/map.py` + `MAP.md` — `MAP.md` is the generated... | DESIGN.md | ok |
| B059-4118 | 138-138 | item | - `scripts/knowledge.py` — the signal/knowledge helper: `... | DESIGN.md | ok |
| B060-844b | 139-139 | item | - `scripts/stamp-counts.py` — counts in `README*.md` / `i... | DESIGN.md | ok |
| B061-0ee2 | 140-140 | item | - `PURPOSE.md` — what the-grid is for (problem, intended ... | DESIGN.md | ok |
| B062-b8df | 141-141 | item | - `signals/` + `knowledge/` — the per-repo conventions fo... | DESIGN.md | ok |
| B063-6658 | 142-142 | item | - `TODO.md` — current outstanding work. | DESIGN.md | ok |
| B064-96fb | 144-144 | heading | ## Getting a machine up to date | CONVENTIONS.md | ok |
| B065-79a9 | 146-149 | para | Plain-English sequence for the three things a machine nee... | CONVENTIONS.md | ok |
| B066-9d54 | 151-151 | heading | ### New machine (never had the-grid before) | CONVENTIONS.md | ok |
| B067-ec87 | 153-153 | item | 1. Clone the-grid to `~/.the-grid`. | CONVENTIONS.md | ok |
| B068-6a8a | 154-154 | item | 2. Pull in submodules: `git submodule update --init --rec... | CONVENTIONS.md | ok |
| B069-af11 | 155-158 | item | 3. Seed your wiring manifest (gitignored, personal — see ... | CONVENTIONS.md | ok |
| B070-c923 | 159-159 | item | 4. Wire skills: `bash scripts/wire.sh` — skills are live ... | CONVENTIONS.md | ok |
| B071-aec2 | 160-169 | item | 5. Set up install identity — **only if `agent-factory/use... | CONVENTIONS.md | ok |
| B072-bb89 | 170-178 | item | 6. Build the agent teams: `cd agent-factory && python3 -m... | CONVENTIONS.md | ok |
| B073-2d58 | 179-179 | item | 7. Wire again from the repo root: `bash scripts/wire.sh` ... | CONVENTIONS.md | ok |
| B074-2eb2 | 181-183 | para | (Steps 2, 3, 4, 6, and 7 — everything except the optional... | CONVENTIONS.md | ok |
| B075-35ce | 185-185 | heading | ### Existing machine (already set up, just did `git fetch... | CONVENTIONS.md | ok |
| B076-4d05 | 187-187 | item | 1. Pull the-grid itself — done (that's what triggered this). | CONVENTIONS.md | ok |
| B077-316d | 188-189 | item | 2. Refresh submodules to match what the pull moved the po... | CONVENTIONS.md | ok |
| B078-df1d | 190-211 | item | 3. Refresh agents — but only if the pull touched anything... | keep | ok |
| B079-bb4b | 212-213 | item | 4. Refresh skills (and agents, and `SKILLS.md`) in one go... | CONVENTIONS.md | ok |
| B080-5eaa | 215-215 | heading | ## Drift checks, the commit gate, and per-project agents | CONVENTIONS.md | ok |
| B081-58f5 | 217-234 | item | - `scripts/gate.sh` — the gate. A plain run is the heavy ... | CONVENTIONS.md | ok |
| B082-ca85 | 235-238 | item | - Read-only drift detectors (exit 1 on drift, write nothi... | CONVENTIONS.md | ok |
| B083-54fd | 239-242 | item | - **Role authoring contract:** `agent-factory/docs/role-a... | DESIGN.md | ok |
| B084-8521 | 243-245 | item | - **Private roles:** `compose.py` reads `GRID_PRIVATE_ROL... | DESIGN.md | ok |
| B085-2f3b | 246-247 | item | - `wire.sh` writes `.wired.manifest` (gitignored; kind/na... | DESIGN.md | ok |
| B086-d74b | 248-255 | item | - **Per-project agents:** `agent-factory/deploy.py <proje... | DESIGN.md | ok |
| B087-2214 | 257-257 | heading | ## Adding a skill | keep | ok |
| B088-6221 | 259-259 | para | Create `skills/<name>/SKILL.md` (a skill dir at the repo ... | keep | ok |
| B089-be7f | 261-263 | para | A `SKILL.md` over 4,000 bytes is split: keep the purpose ... | keep | ok |
| B090-d6f5 | 265-265 | heading | ## Regenerating the skill catalogue | CONVENTIONS.md | ok |
| B091-7958 | 267-269 | fence | ```bash | CONVENTIONS.md | ok |
| B092-722b | 271-274 | para | `scripts/wire.sh` calls `scripts/catalog.sh` automaticall... | CONVENTIONS.md | ok |
| B093-4dea | 276-276 | heading | ## Adding a sibling repo | CONVENTIONS.md | ok |
| B094-0d54 | 278-283 | fence | ```bash | CONVENTIONS.md | ok |
| B095-85a6 | 285-289 | para | A newly added submodule is **library by default** (indexe... | CONVENTIONS.md | ok |
| B096-6382 | 291-297 | para | **Submodules are shallow.** `bootstrap.sh` clones each no... | CONVENTIONS.md | ok |
| B097-e896 | 299-299 | heading | ### Reference submodules (indexes, not skill collections) | CONVENTIONS.md | ok |
| B098-ebc1 | 301-307 | para | Some submodules are awesome-lists / indexes with **no `SK... | CONVENTIONS.md | ok |
| B099-3189 | 309-309 | heading | ## Reconciling a machine (removing stale shadows) | CONVENTIONS.md | ok |
| B100-5580 | 311-314 | para | `wire.sh` won't clobber a *real* directory that shadows a... | CONVENTIONS.md | ok |
| B101-ea89 | 316-319 | fence | ```bash | CONVENTIONS.md | ok |
| B102-6cc7 | 321-321 | para | Idempotent: a fully-wired machine reports "Nothing to rec... | CONVENTIONS.md | ok |
| B103-1125 | 323-323 | heading | ## Running tests | CONVENTIONS.md | ok |
| B104-b7dc | 325-327 | fence | ```bash | CONVENTIONS.md | ok |
| B105-c285 | 329-329 | para | Write portable shell and tests: read `docs/portability.md... | CONVENTIONS.md | ok |
| B106-f074 | 331-331 | heading | ## Canon is never merged on green | keep | ok |
| B107-65b4 | 333-335 | para | **A PR that changes any path under `knowledge/canon/` is ... | keep | ok |
| B108-fff6 | 337-337 | heading | ## Worktree hygiene | keep | ok |
| B109-3af3 | 339-339 | para | Agents and sessions must not leave stale worktrees or loc... | keep | ok |
| B110-9a94 | 341-341 | item | - Remove what you created before finishing, once its PR i... | keep | ok |
| B111-18fe | 342-342 | item | - Delete the branch with `git branch -D <branch>` only af... | keep | ok |
| B112-c8a3 | 343-343 | item | - Never leave scratch worktrees under `.claude/worktrees`... | keep | ok |
| B113-fdc7 | 344-344 | item | - Session start: run `git worktree list`, report and prun... | keep | ok |
| B114-2234 | 345-345 | item | - Untracked `__pycache__` is not a reason to keep a workt... | keep | ok |
| B115-f706 | 346-346 | item | - A markdown-only change needs no worktree and no submodu... | keep | ok |
| B116-670f | 348-348 | heading | ## wire.sh contract | DESIGN.md | ok |
| B117-ef28 | 350-350 | item | - `GRID_DIR` env var overrides the repo root (default: sc... | DESIGN.md | ok |
| B118-559e | 351-351 | item | - `SKILLS_DIR` env var overrides the skills target (defau... | DESIGN.md | ok |
| B119-c18c | 352-352 | item | - `AGENTS_DIR` env var overrides the subagents target (de... | DESIGN.md | ok |
| B120-2fb1 | 353-353 | item | - Only manages symlinks that point into `GRID_DIR` — neve... | DESIGN.md | ok |
| B121-5e35 | 354-360 | item | - Skills in `repos/*/` are discovered at **any depth** vi... | DESIGN.md | ok |
| B122-c7ae | 361-365 | item | - **Exclusion rule (same helper):** even tracked paths ar... | DESIGN.md | ok |
| B123-1cb5 | 366-369 | item | - Only submodules in the manifest (`baseline-submodules.t... | DESIGN.md | ok |
| B124-0e38 | 370-370 | item | - **Machine key:** `GRID_HOST` env var overrides the over... | DESIGN.md | ok |
| B125-c904 | 371-381 | item | - **Audit before wiring (step 0):** before any teardown `... | DESIGN.md | ok |
| B126-667c | 382-386 | item | - **Manifest problems are announced:** a missing baseline... | DESIGN.md | ok |
| B127-03f5 | 387-396 | item | - **Runtime map:** `scripts/lib/runtimes.txt` (`repo \| li... | DESIGN.md | ok |
| B128-8f25 | 397-400 | item | - **Baseline override:** `GRID_BASELINE` env var replaces... | DESIGN.md | ok |
| B129-7474 | 401-408 | item | - **Teardown scope:** teardown removes only links whose t... | DESIGN.md | ok |
| B130-63fa | 409-414 | item | - **Failure safety (no lock):** registry dirs are resolve... | DESIGN.md | ok |
| B131-7e5e | 415-423 | item | - **Machine hooks:** wire.sh keeps one generated `auto-ha... | DESIGN.md | ok |
| B132-ab97 | 424-428 | item | - **Dry home:** `GRID_DRY_HOME=<dir>` forces every home-d... | DESIGN.md | ok |
| B133-591b | 429-433 | item | - **Rule packs:** `rules:<pack>` / `-rules:<pack>` manife... | DESIGN.md | ok |
| B134-a8f6 | 434-442 | item | - **Harnesses:** `harness:<name>` / `-harness:<name>` man... | DESIGN.md | ok |
| B135-4cbd | 443-452 | item | - **Composed agents:** wire.sh also wires `agent-factory/... | DESIGN.md | ok |
| B136-5f49 | 453-457 | item | - **Root-owned agents:** `agents/*.md` at the repo root w... | DESIGN.md | ok |
| B137-12a4 | 458-461 | item | - **No-catalog mode:** `GRID_NO_CATALOG=1` skips only the... | DESIGN.md | ok |
| B138-b3e2 | 462-464 | item | - **Typed entries:** `scripts/grid` ignores typed manifes... | DESIGN.md | ok |
| B139-b8b8 | 466-466 | heading | ## agent-factory (composed agents) | DESIGN.md | ok |
| B140-a4d9 | 468-475 | para | `agent-factory/` composes AI dev-team agents from a singl... | DESIGN.md | ok |
| B141-b2b6 | 477-489 | para | **Orchestrator rosters are generated, not hand-written.**... | DESIGN.md | ok |
| B142-0834 | 491-509 | para | Four public projects (`grid` above; `finance-desk`, `core... | DESIGN.md | ok |
| B143-d4d9 | 511-522 | para | `examples/learning-desk.yaml` — the learning agents, all ... | DESIGN.md | ok |
| B144-265d | 524-526 | quote | > **Rollout note:** `agent-factory/projects/*` is git-ign... | DESIGN.md | ok |
| B145-1c18 | 528-528 | heading | ## Spec-driven development (OpenSpec) | DESIGN.md | ok |
| B146-2b78 | 530-534 | para | the-grid wires [OpenSpec](https://openspec.dev) (`repos/o... | DESIGN.md | ok |
| B147-d1b8 | 536-537 | para | There is deliberately **no fifth "spec-factory"**. OpenSp... | DECISIONS.md | ok |
| B148-21d1 | 539-544 | item | - `project-factory/templates/_common/SPECS.md` — the conv... | DESIGN.md | ok |
| B149-1f3b | 545-547 | item | - `agent-factory/_core/AGENTS_base.md` — a boot-sequence ... | DESIGN.md | ok |
| B150-1df9 | 549-550 | para | `skills/spec-scout/` audits adoption and reports spec↔cod... | DESIGN.md | ok |
| B151-9a4a | 552-552 | heading | ## project-factory (project bootstrapping) | DESIGN.md | ok |
| B152-3051 | 554-565 | para | `project-factory/` scaffolds whole new projects from a te... | DESIGN.md | ok |
| B153-a15c | 567-567 | heading | ## Learnings | LEARNINGS.md | ok |
| B154-8624 | 569-570 | para | Durable lessons mined from project history — full context... | LEARNINGS.md | ok |
| B155-51b7 | 572-575 | item | - Scripts whose output is committed/diffed across machine... | LEARNINGS.md | ok |
| B156-6d14 | 576-578 | item | - Skills that write files from multiple machines (like `h... | LEARNINGS.md | ok |
| B157-fd49 | 579-582 | item | - Library-tier submodules churn independently and can inf... | LEARNINGS.md | ok |
| B158-5cc4 | 583-586 | item | - When writing role/`SKILL.md` instructions for a rule th... | LEARNINGS.md | ok |
| B159-3491 | 587-589 | item | - Don't write bash-style unquoted-`$var` word-splitting i... | LEARNINGS.md | ok |
| B160-b526 | 590-594 | item | - A cron-driven, non-delegating role (e.g. `gh-triage`) d... | LEARNINGS.md | ok |
| B161-d98f | 595-599 | item | - A role only looks team-owned until you ask what happens... | LEARNINGS.md | ok |
| B162-5180 | 600-603 | item | - Splitting a desk (e.g. `finance-desk`) out of a larger ... | LEARNINGS.md | ok |
| B163-30f6 | 604-610 | item | - A composed role's own bundled `SKILL.md` ("its operatin... | LEARNINGS.md | ok |
| B164-7952 | 611-619 | item | - Before pointing a role at a wired skill for some capabi... | LEARNINGS.md | ok |
| B165-036f | 620-623 | item | - Claude Desktop's two surfaces wire differently: the Cod... | LEARNINGS.md | ok |
| B166-248b | 624-627 | item | - After an upstream history rewrite, `git cherry`/patch-i... | LEARNINGS.md | ok |
| B167-68b6 | 629-629 | heading | ## About | UNSORTED.md | ok |
| B168-a0b0 | 631-633 | para | the-grid is Gareth's brainchild — a personal, evolving sy... | UNSORTED.md | ok |
