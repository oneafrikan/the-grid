## Purpose

Give every grid project the same small set of charter files so a cold agent knows what the project is for, what it must not do, and where to look next.

## ADDED Requirements

### Requirement: Charter file set
Every project cut by `project-factory/scripts/cut-project.sh` SHALL receive `PURPOSE.md`, `GUARDRAILS.md`, `BEHAVIOUR.md`, `scripts/map.py`, `.githooks/pre-commit`, `signals/README.md`, `knowledge/README.md` and `knowledge/canon/.gitkeep` from `templates/_common/`, and `MAP.md` generated after the copy. `MAP.md` SHALL NOT exist in `templates/_common/`. Seed and retrofit behave alike.

#### Scenario: Seed
- **WHEN** `cut-project.sh python-agents-base <empty dir>` runs with `python3` available
- **THEN** all eight source paths and the generated `MAP.md` exist in the target
- **AND** `templates/_common/MAP.md` does not exist
- **AND** the command exits 0

#### Scenario: Retrofit never overwrites
- **WHEN** the target already has a `PURPOSE.md` whose content differs from the template
- **THEN** that file is unchanged and appears in the SKIPPED list
- **AND** the other paths are still written if absent

#### Scenario: Re-run is a no-op
- **WHEN** the same cut runs a second time
- **THEN** no file changes and the summary reports 0 files written

### Requirement: PURPOSE.md shape
`PURPOSE.md` SHALL contain exactly the `##` headings Problem, Intended solution and Outcome, one line linking `GUARDRAILS.md`, and no guardrail entries, and SHALL be at most 40 lines.

#### Scenario: Template conforms
- **WHEN** the `_common` `PURPOSE.md` is checked
- **THEN** it has those three `##` headings in that order, a link to `GUARDRAILS.md`, no line matching `^- G[0-9]+:`, and at most 40 lines

### Requirement: GUARDRAILS.md entry format
Each guardrail in `GUARDRAILS.md` SHALL be one line of the form `- G<n>: <must-not> [check: <human|CI|hook|none>]` with an optional `: <how>` before the closing bracket, SHALL carry an ID unique in the file, and SHALL keep its ID for life: a withdrawn guardrail is rewritten as `- G<n>: (retired)`, never deleted or renumbered.

#### Scenario: Entries parse
- **WHEN** every line starting `- G` in the-grid `GUARDRAILS.md` is matched against `^- G[0-9]+: .+ \[check: (human|CI|hook|none)(: .+)?\]$` or `^- G[0-9]+: \(retired\)$`
- **THEN** every line matches and no ID repeats

#### Scenario: A CI or hook check is real
- **WHEN** a the-grid guardrail declares `check: CI` or `check: hook`
- **THEN** the named script or hook file exists in the repo

### Requirement: BEHAVIOUR.md holds additions only
`BEHAVIOUR.md` SHALL open with one line stating that grid-wide defaults live in `agent-factory/_core/AGENTS_base.md` and that the file lists this project's additions only, and SHALL NOT restate the stage vocabulary or the warrant rule.

#### Scenario: No duplication
- **WHEN** the the-grid `BEHAVIOUR.md` is searched for the six stage names together
- **THEN** they do not all appear

### Requirement: Signals and knowledge conventions seeded
`signals/README.md` and `knowledge/README.md` SHALL state the directory layout (`signals/` pending, `signals/done/` processed; `knowledge/` by stage, `knowledge/canon/` canonical only), that signals live in the project's own repo and contain no secrets or personal data, that `stage` and `claim` are the only entry frontmatter keys `scripts/map.py` reads, and whether a sweep exists. `signals/README.md` SHALL also restate the six stages and the warrant rule in at most 25 lines, because lean project agents do not receive `AGENTS_base.md`.

#### Scenario: Honest sweep status
- **WHEN** `signals/README.md` is read in a repo where `knowledge-signals` has not shipped
- **THEN** it says no sweep runs and signals are not processed

#### Scenario: Vocabulary restated
- **WHEN** `signals/README.md` is searched
- **THEN** it contains all six stage names and the sentence that `wip` is never promoted
- **AND** it is at most 25 lines in its vocabulary section

#### Scenario: Handoffs distinguished
- **WHEN** `signals/README.md` is read
- **THEN** it says files starting `→` are agent handoffs and are not knowledge signals

### Requirement: CLAUDE.md trailhead
The trailhead block in `project-factory/trailhead.md` SHALL tell the reader to read `PURPOSE.md` and `MAP.md` at session start, `GUARDRAILS.md` before editing, committing or opening a PR, `signals/README.md` before recording a claim or filing a signal, `RELATED.md` (if it exists) before building a new capability or adding a dependency, and to find everything else through `MAP.md`. The block SHALL be byte-identical, between `<!-- charter-trailhead -->` and `<!-- /charter-trailhead -->`, in the four template `CLAUDE.md` files and in the-grid `CLAUDE.md`.

#### Scenario: Blocks identical
- **WHEN** the block is extracted from each of those five files
- **THEN** all five equal `trailhead.md`

#### Scenario: Related line
- **WHEN** the trailhead block is read
- **THEN** it contains the line telling the reader to read `RELATED.md` if it exists before building a new capability or adding a dependency, and does not tell the reader to read it at session start

#### Scenario: Retrofit with an existing CLAUDE.md
- **WHEN** `cut-project.sh` runs against a target whose `CLAUDE.md` lacks the marker
- **THEN** that file is unchanged
- **AND** the output prints the trailhead block with an instruction to paste it at the top

### Requirement: Pre-commit gate in projects
`templates/_common/.githooks/pre-commit` SHALL be executable and SHALL run `python3 scripts/map.py --check` when `python3` and `scripts/map.py` exist, print a one-line skip notice when either is absent, and exit 1 printing `run: python3 scripts/map.py` when the check fails. A seed cut SHALL set `core.hooksPath=.githooks` in the new repo; a retrofit SHALL NOT change git config and SHALL print the command instead. No CI job SHALL be seeded.

#### Scenario: Stale map blocks a commit
- **WHEN** a seeded project with hooks enabled adds `CONTEXT.md` without regenerating and runs `git commit`
- **THEN** the commit is refused with `run: python3 scripts/map.py`

#### Scenario: Retrofit leaves git config alone
- **WHEN** `cut-project.sh` retrofits an existing repo
- **THEN** `git config core.hooksPath` is unchanged
- **AND** the output prints `git config core.hooksPath .githooks`

#### Scenario: No python3
- **WHEN** `python3` is not on PATH
- **THEN** the hook exits 0 with a skip notice

### Requirement: MAP.md created at cut time
`cut-project.sh` SHALL create `MAP.md` by running the target's seeded `scripts/map.py` when `MAP.md` was absent before the cut, and SHALL NOT run or write anything when `MAP.md` already existed.

#### Scenario: Fresh seed has a current map
- **WHEN** a seed cut finishes with `python3` available
- **THEN** `python3 scripts/map.py --check` run in the target exits 0

#### Scenario: Existing MAP.md untouched
- **WHEN** the target already has a `MAP.md`
- **THEN** its bytes are unchanged after the cut

#### Scenario: No python3
- **WHEN** `python3` is not on PATH during the cut
- **THEN** the cut still exits 0 and prints `run: python3 scripts/map.py`

### Requirement: Optional RELATED.md
`RELATED.md` SHALL NOT be in `templates/_common/` or any template and SHALL NOT be created by a default cut. `cut-project.sh --with-related` SHALL copy `project-factory/related.md` to `<target>/RELATED.md` under the copy-if-absent rule, in seed and retrofit mode alike. The template SHALL open with a header stating that the list is not exhaustive (search if unsure), that a repo names only repos at the same or greater privacy than itself, that a wrong entry is filed as a signal, and that cross-project requests are issues filed in the other repo, and SHALL define per entry the fields `repo`, `owns`, `provides to us / we provide to it`, `don't build here`, `reach` and `verified` (`YYYY-MM-DD`). The template SHALL be at most 25 lines. The privacy rule SHALL be documented as `check: human`; no gate or hook SHALL check `RELATED.md`.

#### Scenario: Default cut has none
- **WHEN** `cut-project.sh python-agents-base <empty dir>` runs without the flag
- **THEN** no `RELATED.md` exists in the target

#### Scenario: Offered with the flag
- **WHEN** `cut-project.sh --with-related python-agents-base <empty dir>` runs (flag before, between or after the positional arguments)
- **THEN** `RELATED.md` exists, equals `project-factory/related.md`, and has the six entry fields and the privacy sentence

#### Scenario: Retrofit never overwrites
- **WHEN** the target already has a `RELATED.md` whose content differs and the flag is given
- **THEN** that file is unchanged and appears in the SKIPPED list

#### Scenario: Re-run is a no-op
- **WHEN** the same cut with the flag runs twice
- **THEN** the second run writes 0 files

#### Scenario: the-grid has none
- **WHEN** the repo root is listed after this change
- **THEN** there is no `RELATED.md`

### Requirement: Dogfood on the-grid
The-grid repo SHALL carry `PURPOSE.md`, `GUARDRAILS.md`, `BEHAVIOUR.md`, `MAP.md`, `signals/README.md`, `knowledge/README.md`, `knowledge/canon/.gitkeep` and the trailhead at the top of `CLAUDE.md` before the project templates are changed, and its `GUARDRAILS.md` and `PURPOSE.md` text SHALL be approved by the operator.

#### Scenario: Gate passes with the files
- **WHEN** `bash scripts/gate.sh` runs on the branch
- **THEN** it passes, including `check-personal.sh` over the new files

### Requirement: Business-neutral and private-safe content
Charter templates and the-grid's own charter files SHALL contain no real business name, personal data or secret, and the template `signals/README.md` and `knowledge/README.md` SHALL say that a project's signals stay in that project's own repo.

#### Scenario: Neutral text
- **WHEN** `scripts/check-personal.sh` scans the new tracked files
- **THEN** it reports nothing
