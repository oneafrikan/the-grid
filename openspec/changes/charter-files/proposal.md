## Why

Agents in a grid project start cold. There is no single place that says what the project is for, what must never happen, or what already exists; the only memory is `CLAUDE.md` (569 lines in the-grid today), an 85-line `LEARNINGS.md` read on demand, and per-role prose. Four evidence vocabularies exist side by side (RAN/READ/UNTESTED in `agent-factory/docs/role-authoring.md:48`, STATED/OBSERVED/INFERRED in `roles/oracle/AGENTS.md:30`, H/M/L in `roles/researcher/SKILL.md:153`, librarian `tier` in `roles/librarian/SKILL.md:71`) and nothing says how they relate. This change lays the foundation: small charter files in every project, a generated map, and one compact vocabulary in the shared agent boot text. It builds no signal flow; `knowledge-signals` (A2) builds on it.

## What Changes

- New files in every project repo, seeded and retrofitted by `project-factory/templates/_common` with the existing never-overwrite rule: `PURPOSE.md`, `GUARDRAILS.md`, `BEHAVIOUR.md`, `scripts/map.py`, `signals/README.md`, `knowledge/README.md`, `knowledge/canon/.gitkeep`, and a pre-commit shim `.githooks/pre-commit`. `MAP.md` is NOT shipped in `_common`: `cut-project.sh` generates it after the copy.
- `scripts/map.py` generates `MAP.md` (ontology, topology, epistemology, "read when" column, canon one-liners) with no volatile data: no stage or pending-signal counts. `map.py status` prints those counts and is not checked. `--check` fails on drift only, in the style of `catalog.sh --check`, and stays green across signal and sweep commits. It is added to `scripts/gate.sh` (the-grid) and to the pre-commit shim (project templates; no CI job).
- `CLAUDE.md` trailhead block: read PURPOSE.md and MAP.md at session start, GUARDRAILS.md before acting, MAP.md for the rest. Added to the four template `CLAUDE.md` files, printed (never applied) by `cut-project.sh` for a retrofit whose `CLAUDE.md` differs, and prepended to the-grid's own `CLAUDE.md`.
- `agent-factory/_core/AGENTS_base.md` gains three short sections (1670 bytes, cap 2000): stage vocabulary + warrant rule, always-in-context memory rules, and how to file a knowledge signal. This change owns the whole block; `knowledge-signals` does not edit it. Lean project agents do not receive the base, so `signals/README.md` restates the vocabulary and the trailhead points to it. No new compose fragment, no `compose.py` change.
- Optional `RELATED.md`: a short view of neighbouring projects so an agent does not search widely or build what another project owns. Not seeded by default; `cut-project.sh --with-related` offers it from `project-factory/related.md`. The trailhead gets one line (read it before building a new capability or adding a dependency); MAP.md lists it only when present. The-grid itself gets none in this change.
- Dogfood first: the-grid gets the files itself before the templates are cut.

## Capabilities

### New Capabilities

- `project-charter-files`: the file set, templates, seeding/retrofit, trailhead, dogfooding, the optional `RELATED.md`.
- `repo-map`: `MAP.md` content contract and `scripts/map.py` generation and `--check` (registry includes `RELATED.md` when present).
- `agent-boot-vocabulary`: stage vocabulary, warrant rule, signal-filing instructions and memory rules in `AGENTS_base.md`.

### Modified Capabilities

None exist to modify: `openspec/specs/` is absent on this branch. The coupling with the other staged changes is real, though:

- `knowledge-signals` (A2) defines the signal fields and claimable stages that `agent-boot-vocabulary` restates; a later change to a field edits `agent-boot-vocabulary`, not `AGENTS_base.md` alone.
- `epistemic-enforcement` (A3) extends what `repo-map` `--check` validates; it carries a MODIFIED delta of the `repo-map` "Drift check" requirement, which here is drift-only.
- A3 and A2 touch `project-charter-files` only through `signals/README.md` and `knowledge/README.md` text.

## Impact

- New: `PURPOSE.md`, `GUARDRAILS.md`, `BEHAVIOUR.md`, `MAP.md`, `signals/README.md`, `knowledge/README.md`, `knowledge/canon/.gitkeep`, `scripts/map.py`, `tests/test_map.bats`, `tests/test_charter_files.bats`, `project-factory/trailhead.md`, `project-factory/related.md` (opt-in template, outside `templates/` so it is never copied by default), `project-factory/templates/_common/{PURPOSE,GUARDRAILS,BEHAVIOUR}.md`, `.../_common/.githooks/pre-commit`, `.../_common/scripts/map.py` (byte-identical mirror), `.../_common/signals/README.md`, `.../_common/knowledge/{README.md,canon/.gitkeep}`.
- Edited: `scripts/gate.sh` (check `map`; shellcheck list gains the shim), `tests/test_gate.bats`, `CLAUDE.md`, `project-factory/scripts/cut-project.sh`, `project-factory/README.md`, the four `project-factory/templates/*/CLAUDE.md`, `agent-factory/_core/AGENTS_base.md`, `tests/test_project_factory.bats`.
- Regenerated (gate drift checks): composed agents (`compose.py --check`), `dist/personas/`, `plugins/`.
- Depends on nothing unbuilt. Does not touch `instincts` (existing change; `learning: on`), `mine-learnings` or `LEARNINGS.md`.
- Use case for the new asset types: one session-start map for any agent in any project, so a cold agent knows purpose, limits and layout from about 3 small files.
- Sequencing: `front-door` task 2.6b requires every top-level tracked directory and every tracked script (here `signals/`, `knowledge/`, `scripts/map.py`) to appear in `docs/architecture.md`. Every new script or top-level directory this change adds is listed there in the same PR (task 6.3); if `docs/architecture.md` does not exist yet, the PR description hands the list to `front-door` task 2.3. UNVERIFIED which lands first.

## Business-tier fit

- The business repo `the-grid-<business>` is a project repo (docs/business-tier, PR #280), so it is seeded with the same charter files by the same `cut-project.sh` path.
- Its `PURPOSE.md` is where the business problem and outcome are stated; its `GUARDRAILS.md` is where business must-nots live. Neither belongs in the public grid.
- Its `RELATED.md` (opt-in) lists the public grid as its factory (this is where "this capability lives in the grid" is stated) and its sibling business repos. A business repo may name only repos at the same or greater privacy than itself; the public grid qualifies. Whether Cowork users can file issues in a neighbour repo is UNVERIFIED (pilot).
- Colleagues on Cowork read `PURPOSE.md`/`MAP.md` through the `CLAUDE.md` trailhead if Cowork loads `CLAUDE.md` (UNVERIFIED; pilot).
- Not designed here: the business tier itself.

## Non-goals

- No signal file format (the field list in `AGENTS_base.md` restates A2's), sweep, `knowledge/` entry format beyond the two fields `map.py` reads (`claim`, and `stage` for `status`), or `gh-triage` change (A2). No `knowledge.py` (A2 creates and mirrors it).
- No CI job in project templates; only the pre-commit shim.
- No `RELATED.md` for the-grid itself, no auto-generated cross-repo index, no staleness lint (needs network), no machine check of the privacy rule, and no `AGENTS_base.md` text for it (trailhead only; lean project agents get the trailhead).
- No lint beyond `map.py --check` drift; no stage-enum or address validation, no Stop hook, no CODEOWNERS, no eval cases (A3).
- No merge of `LEARNINGS.md` into `knowledge/`; `mine-learnings` unchanged.
- No file-tree index in `MAP.md`; it indexes charter files, roles, skills and knowledge only.
- No trimming of the-grid's 569-line `CLAUDE.md` (the trailhead is prepended only).
- No renaming of the existing agent handoff protocol (`signals/→<agent>.md`); see Open assumption 3.
- No deletion or edit of any of the four existing evidence vocabularies.
- No new compose fragment, no `compose.py` change, no new role.
- No separate OS user, sudo step, App token or session isolation.

## Open assumptions

The operator can veto any of these; each is a "Decided:" in design.md.

1. **Vocabulary mapping.** Stage for knowledge claims; RAN/READ/UNTESTED for completion claims; the other three map as below. Nothing is deleted or rewritten in this change.

   | Vocabulary (where) | Axis | Maps to (assumed) |
   |---|---|---|
   | RAN / READ / UNTESTED (`role-authoring.md:48`, platform-engineer, finance-analyst) | how a completion claim was checked | RAN or READ = warrant present; UNTESTED = no warrant, handled as `wip` |
   | STATED / OBSERVED / INFERRED (`oracle`) | where an operator-profile fact came from | STATED, OBSERVED = warrant present; INFERRED = no warrant, handled as `wip`. Oracle data is private and outside the knowledge flow; the mapping applies only if it is ever filed |
   | H / M / L (`researcher`, `librarian` `confidence`) | how sure the author is | Not a stage. Carried inside the `warrant` text; never raises a stage |
   | librarian `tier` | source quality, values set by the filing source (UNVERIFIED: the value set is not in this repo) | Not mapped. Carried inside `warrant`; never raises a stage |

   The stage an agent files is a proposal (any claimable stage); `canonical`, supersession and contradiction are decided by a human, and `established` needs a different filer's own warrant. No stage is derived from these vocabularies.

2. **Single map script, mirrored.** `scripts/map.py` is canonical; `_common/scripts/map.py` is a byte-identical copy checked by a bats test. Alternative rejected: a symlink.
3. **`signals/` name collision.** `AGENTS_base.md` "Signal Protocol (handoff)" and every role AGENTS.md use `signals/→<agent>.md` for agent-to-agent handoffs. Knowledge signals reuse the directory name. Assumed: both coexist in `signals/`; knowledge signals never start with `→`; the handoff section is left untouched; `map.py status` counts only non-`→` files. Operator decision D9: coexist, no rename.
4. **Charter file text is a `<fill>` stub in templates; the-grid's own text is drafted by the implementer and approved by the operator (HUMAN task).**
5. **MAP.md budget.** At most 150 lines and 12 000 bytes; over that `map.py` exits 2. No volatile data in MAP.md (D1).
6. **Agent boot has no new boot-sequence step.** The trailhead in `CLAUDE.md` carries the read order; `AGENTS_base.md` carries vocabulary only. Subagents in a project load that project's `CLAUDE.md` from cwd (UNVERIFIED headless; `issue-loop-v2` tests it).
7. **Lean project agents miss `AGENTS_base.md`.** Verified in `compose.py` (lean profile drops the base). Assumed fix without touching `compose.py`: the trailhead points to `signals/README.md`, which restates the stages and warrant rule. Alternative the operator may prefer: change the lean profile to keep one named base section (a `compose.py` change, so a separate decision).

8. **Per-agent injected cost (vetoable).** The `AGENTS_base.md` block adds 1670 bytes (cap 2000) to every full-profile composed agent, about 1.5-2 KB each, on top of a 2907-byte base. `openspec/config.yaml` says: "anything that injects text into context or calls a model must be opt-in and budgeted." This block is not opt-in (it is in every agent, whether or not the repo has charter files) and its budget is the 2000-byte cap. Accepted by the operator (D8); veto here means dropping the sections from `AGENTS_base.md` and relying on `signals/README.md` plus the trailhead for all agents.
9. **Project templates get a pre-commit gate only (D12).** A bypassable hook (`--no-verify`) running `map.py --check`; no CI job.
10. **`RELATED.md` is opt-in, offered by a flag.** Smallest mechanism that fits `cut-project.sh` (copy-if-absent, positional args): a `--with-related` flag copies `project-factory/related.md` to `RELATED.md` under the same never-overwrite rule. Alternative rejected: a prompt (the script is non-interactive). The privacy rule (same or greater privacy) is `check: human`; nothing verifies it. Cross-repo requests are GitHub issues in the neighbour's repo; an agent never pushes into another repo and the loop works only in its own.

## Open questions (not decided here)

- Can Cowork commit and push? Pilot check.
- Who may file a signal from a non-terminal environment?
