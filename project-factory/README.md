# project-factory

The-grid's tier for **bootstrapping whole projects** — a sibling to
[`agent-factory/`](../agent-factory/) (composes AI personas) and [`automation-factory/`](../automation-factory/) (cuts
automation patterns into an existing repo).

## The template → project model

A `project-factory` template is a project **seed**: a standalone, self-contained
directory tree with no logic of its own — it doesn't run, wire into the-grid, or
depend on being inside `~/.the-grid/`. `cut-project.sh` copies `templates/_common/`
(see below) followed by the chosen template into a target directory to either:

- **Seed** a brand-new project (target is empty or doesn't exist yet), or
- **Retrofit** an existing project (target already has files) — additive only,
  never overwrites a file that already exists and differs from the source.

Both modes run through the same script and the same rule: never silently clobber.
Anything the retrofit can't safely place is reported at the end for manual review.

## `_common` — session-continuity scaffolding every project gets

Every project cut from this factory is assumed to end up with a GitHub issue
backlog and multiple agent sessions working it over time (the `issue-loop` is
an opt-in extra, off until you enable it) — so every project needs the same
context-management and handoff shape regardless of stack. That shape lives once, in
[`templates/_common/`](templates/_common/), not copy-pasted into each template:

- `CONTEXT.md` — cold-start summary (current state, next priority, binding decisions); decisions themselves go in `DECISIONS.md`.
- `LEARNINGS.md` — empty ledger; target for the `mine-learnings` skill.
- `SPECS.md` — the OpenSpec convention (see below).
- `handoffs/` — dated handoff+context docs between agent sessions (`TEMPLATE.md` is the format).
- `AGENTS-SETUP.md` — optional: how to deploy a lean set of grid agents into the
  project (`agent-factory/deploy.py`) and the CLAUDE.md block to adopt.
- `.grid/project.yaml` — commented skeleton for the project facts those agents get.
- `.claude/skills/project-review/SKILL.md` — a project-aware review skill seed: generic
  correctness + invariants passes, with this repo's own invariants left as `<fill>` markers.
- `loop/loop.conf.seed` and `loop/ENABLE.md` — the issue-loop is **opt-in and off**: the seed
  holds its defaults and `ENABLE.md` lists what to define before turning it on (`VERIFY_CMD`
  first: the loop refuses to run without one). Set `VERIFY_CMD` (and `SETUP_CMD`) there; the
  loop opens PRs and never merges. It does not make `loop/run-issue.sh` exist.
- `PURPOSE.md`, `GUARDRAILS.md`, `BEHAVIOUR.md` — the charter files (see below), as `<fill>` stubs.
- `signals/README.md`, `knowledge/README.md`, `knowledge/canon/.gitkeep` — the signal and knowledge conventions.
- `scripts/map.py` — generates `MAP.md`; a byte-identical mirror of the-grid's `scripts/map.py`.
- `.githooks/pre-commit` — a shim that runs `python3 scripts/map.py --check` (no CI job is seeded).

### Charter files — what a cold agent reads first

Every cut project gets a small set of files so an agent that knows nothing about the
project learns its purpose, limits and layout from about three short reads:

- `PURPOSE.md` is the problem, the intended solution and the outcome. `GUARDRAILS.md` lists
  the must-nots, one `G<n>` line each, with how each is checked. `BEHAVIOUR.md` lists only
  this project's additions to the grid-wide agent defaults.
- `MAP.md` is **generated, not copied**: `cut-project.sh` runs the target's own
  `scripts/map.py` after the copy, and only when `MAP.md` did not exist. If `python3` is
  missing it prints `run: python3 scripts/map.py` instead and still exits 0.
- A `CLAUDE.md` trailhead block (`trailhead.md`, between `<!-- charter-trailhead -->` markers)
  tells the agent what to read when. The four templates carry it. A retrofit never has its
  `CLAUDE.md` edited: if it lacks the marker, the block is printed for you to paste.
- A seed sets `core.hooksPath=.githooks` so the shim is armed. A retrofit never touches git
  config; it prints `git config core.hooksPath .githooks`.
- `scripts/map.py` is canonical in the-grid repo; the copy here is mirrored and a bats test
  compares them with `cmp`, so change the canonical one and copy it over.
- `RELATED.md` is optional and never seeded by default. `cut-project.sh --with-related`
  copies [`related.md`](related.md) (a short list of neighbouring projects) to `RELATED.md`
  under the same never-overwrite rule. Name only repos at the same or greater privacy; that
  rule is checked by a human, nothing here verifies it.

### Generic core docs (`--generic`) — the part with no grid vocabulary

`cut-project.sh --generic [--with a,b | --all-optional] <target-dir>` skips the stack
template and `_common`, and lays down only a standard, well-formed documentation set
(run by the `project-scaffold` skill). Same copy-if-absent rule: a differing file is
skipped and listed, a second run is a no-op.

- **Core** (`templates/_core/`, plus `PURPOSE.md` and `GUARDRAILS.md` shared with `_common`): `CLAUDE.md`
  (entry point and read-when table), `PURPOSE.md`, `RULES.md` (operator-owned standing orders),
  `GUARDRAILS.md`, `CONVENTIONS.md`, `DECISIONS.md`, `DOCS.md` (index of documentation to consult), `CHANGELOG.md` (what changed, newest first),
  and a generated `MAP.md` (with `scripts/map.py` so it can be regenerated).
- **Optional** (`templates/_optional/`, only with `--with` or `--all-optional`): `DESIGN`, `AGENTS`, `LOGS`,
  `HUMANS`, `CALCULATIONS`, `ASSUMPTIONS`, and `CONTEXT` (the cold-start summary, kept in `_common`).
  `--with` also works on a stack-template cut.
- Every file is a short stub: purpose line, a what-goes-here / what-does-not test, `<fill: ...>` markers.
  Filling them is the next step, not this script's job.
- **Grid-coupled `_common` content** (not part of the generic set): `SPECS.md`, `signals/`, `knowledge/`,
  `loop/`, `AGENTS-SETUP.md`, `.grid/`, the `project-review` skill, `.githooks/`, `handoffs/`, `BEHAVIOUR.md`,
  `LEARNINGS.md`, `scripts/knowledge.py`. Stack-template cuts still lay these down.

### Bootstrap — scaffold, then fill, then (optionally) the grid layer

Two layers, one script:

- **Generic layer** (`--generic`): structure that works anywhere. Stubs with `<fill: ...>` markers, no grid vocabulary.
- **Grid layer** (`--generic --grid`): also copies, by name and under the same never-overwrite rule, the grid-coupled `_common` files:
  `BEHAVIOUR.md`, `LEARNINGS.md`, `SPECS.md`, `AGENTS-SETUP.md`, `.grid/project.yaml`, `signals/`, `knowledge/` (with
  `scripts/knowledge.py`), `handoffs/`, `.claude/skills/project-review/`, `.githooks/pre-commit` and the opt-in `loop/` seed.
  Because `signals/` and `knowledge/` now exist, the generated `MAP.md` shows its Signals and Epistemology sections and
  `python3 scripts/map.py --check` passes. A seed also gets `core.hooksPath=.githooks`; a retrofit gets the command printed.
  Without `--grid` nothing changes. With a stack template `--grid` is a no-op (it prints a note): `_common` is already laid down.
- **Bootstrap** is the `project-bootstrap` skill: it asks the operator one batch of questions, runs the cut, fills the markers
  from the answers (never inventing a fact: anything not given stays `<fill: ...>` or `<unknown: ask the operator>`),
  optionally deploys a lean set of agents and hooks, then regenerates and checks the map. Wired by the next `bash scripts/wire.sh`.
  It wraps `cut-project.sh --generic [--with a,b] [--grid] <target-dir>`; `tests/test_project_bootstrap.bats` checks the flags it cites exist.

### Retrofit — move an existing project's docs onto the standard set, losing nothing

[`scripts/retrofit.py`](scripts/retrofit.py) (Python 3.8+, stdlib only) brings a project that already has a big `CLAUDE.md`,
notes or a TODO into the generic doc set. The design: **the model decides where each block goes, the script moves it
verbatim.** Nobody retypes source text, so nothing can be reworded or dropped on the way.

1. `survey <repo>` (read-only) lists candidate sources and which standard docs exist. Scaffold the missing docs first
   with `cut-project.sh --generic [--with ...]`.
2. `blocks <file>` numbers the file's markdown units as `B012-3fa9` (index plus 4 hex of a hash of the normalised text):
   headings, paragraphs, list items with their nested items, code fences, tables, comments, raw HTML blocks, quotes, front matter.
   The file can be rebuilt byte for byte from its blocks (`blocks <file> --rebuild`; also asserted on every parse).
   It also prints the plan header line `## source: CLAUDE.md sha256:<hash of the whole file>` to paste into the plan;
   run it from the repo root with a repo-relative path (an absolute path or one outside the repo is refused, exit 2).
3. A **plan** maps every block: `B012-3fa9 -> GUARDRAILS.md#Hard constraints`, a range `B004-91c2..B009-00ab -> CONVENTIONS.md`,
   `-> keep` (stays in the source) or `-> unsorted` (goes to `UNSORTED.md`). The parser is strict: no source section or no
   block lines, a source that changed since `blocks` (the whole-file sha256 pins it, so a middle-of-range edit is caught),
   unknown id, stale hash, a block not mentioned or mentioned twice, or a path leaving the repo (also via symlink) is an
   error with a line number and nothing is written. Destinations are existing `.md`/`.txt` text files: no dotfiles, no
   binaries, not the plan file, not another source of the plan.
4. `apply <plan>` is a dry run; `--yes` appends the blocks verbatim after a blank line and a `<!-- moved from ... -->`
   comment, never touches the source, and a second run adds nothing. Anchors are resolved against the destination as it
   was before the run, and runs into one heading land in plan order. Before writing anything it checks that every
   destination is writable and ends outside an unclosed fence, comment or raw HTML block (`<script>`, `<style>`, `<pre>`,
   `<textarea>`), and that every block would read back as itself.
   It has no revert command: commit or stash first and undo with git.
5. `check <plan> [--report]` is the no-judgement proof, **block by block**: the destination is parsed into blocks and each
   moved block must equal one of them (only CRLF and trailing blanks are ignored; text inside a fence, comment or raw HTML block never
   counts; one destination block satisfies one source block). Every `keep` block must still be in the live source, every
   `unsorted` block in `UNSORTED.md`. Exit 1 on any missing or altered block, a missing destination file included;
   `--report` writes `docs/archive/retrofit-<source>-<date>-coverage.md`.
6. `finalize <plan> --replace-with <slim.md>` runs only if `check` passes, the slim doc is at most `--max-lines N` lines
   (default 60, `0` = no limit) and every `keep` block is in it as a block of its own (`keep <plan>` prints them). It archives the original to `docs/archive/<name>.<date>.orig`, refuses an
   existing archive that differs (a byte-identical one from a failed replace is reused), refuses a source that is not
   tracked-and-clean in git without `--allow-dirty`, and prints the undo: `mv <archive> <source>`. Afterwards the same plan
   still checks, because the source text is then read from the archive whose sha256 matches, so a second source can be
   finalized with the same plan.

Exit codes: 0 ok, 1 coverage failure, 2 usage or plan error or a refusal; errors are one line, never a traceback. A hard
kill can leave a stray `.retrofit-*` temp file next to a destination; delete it. The `project-retrofit` skill drives this
flow with the operator approving the plan before `apply` and the slim doc before `finalize`;
`tests/test_project_retrofit.bats` covers it with synthetic fixtures.

### `SPECS.md` — spec-driven development, on by default

Every cut project gets [`SPECS.md`](templates/_common/SPECS.md): the
[OpenSpec](https://openspec.dev) convention — specs in `openspec/`, proposals
reviewed before code, deltas folded back on archive. It's in `_common` rather
than per-template on purpose: **spec-driven development is the default, not a
per-project decision someone has to remember to make.** A retrofit gets it too,
so the convention reaches old repos on the same pass as everything else.

`SPECS.md` is documentation and agent instructions only — it does **not** run
`openspec init`. `cut-project.sh` copies files; the `openspec` CLI owns the
directory tree it creates, and back-filling specs is a judgement call that
belongs to the first real change, not to scaffolding. `SPECS.md` spells out both
the greenfield and brownfield adoption paths and tells agents in the repo to
stop and propose rather than skip to code.

The 12 `openspec-*` skills are wired on every machine via the-grid's baseline,
but they shell out to the CLI — `npm i -g @fission-ai/openspec@latest`.

`_common` isn't a template itself (leading underscore, filtered out of
`cut-project.sh`'s template listing) — it's cut in before every template, using
the same copy-if-absent/skip-if-differs rule. A template's own `CLAUDE.md`
stays template-specific (stack conventions genuinely differ) and isn't part of
`_common`.

This is deliberately narrow in scope. `cut-project.sh` only scaffolds a directory
tree. It does not decide what AI personas, skills, or automations the project
uses — that composition happens **after** seeding, as a separate step, using the
other three factories exactly as you would in any other repo (wire in a skill,
compose an `agent-factory` persona for the project's own agent identity, cut an
`automation-factory` pattern like `issue-loop` once the repo has a GitHub issue
backlog). A seeded project is a completely normal repo from that point on — it
has no ongoing dependency on `project-factory` or the-grid.

## Templates

| Template | What it scaffolds |
|----------|--------------------|
| [`python-agents-base`](templates/python-agents-base/) | The default, generic Python AI agent-**team** scaffold (orchestrator + worker, not a single agent) — no domain-specific tools or logic. Start here for anything that doesn't fit a more specific template. |
| [`python-astro-content-agent`](templates/python-astro-content-agent/) | A single Python agent that reads markdown content and builds pages for an Astro site — genuinely single-purpose, stays singular. |
| [`lamp-agents-base`](templates/lamp-agents-base/) | Not a Python agent app — a PHP/MySQL/Apache project's agent-injection kit (`CLAUDE.md` + worktree DB/port isolation scripts, on top of `_common`), cut in retrofit mode against an existing LAMP repo most of the time. |
| [`finance-agents-base`](templates/finance-agents-base/) | A generic personal-finance agent-team scaffold: watcher/analyst/strategist/guardrail/scribe roles, a human approval gate, and a versioned policy-document convention — no thresholds or trading logic baked in. |

Naming convention: **`agents`, plural**, unless a template is genuinely
single-purpose (`python-astro-content-agent`) — any project with more than
one operational role should say so in its name and its `src/` shape.

Templates are **fully independent** — none inherit from each other or share
code; they fall into three families of shape (Python agent team, single
Python agent, LAMP agent-injection kit). Each is standalone and
self-contained, matching the model above.

## Anatomy of a template

```
templates/<name>/
  README.md          # what the seeded project is, tech choices, what to fill in
  src/agents/          # the team: one folder per role, plus shared/ for common execution/state/memory
  src/tools/           # tool definitions agents can call
  src/models/          # LLM client and model config
  src/prompts/          # system/agent prompt templates
  src/utils/             # helpers, logging, config parsing
  tests/                  # unit/integration tests
  content/ (or data/)      # sample input content / fixtures
  logs/                     # .gitkeep only — runtime output, gitignored
  main.py                    # entry point
  requirements.txt
  .env.example
  .gitignore
```

Not every template needs every folder — `python-agents-base` ships the full
shape (including `api/` and an optional `docker-compose.yml`) since it's the
generic default; `python-astro-content-agent` deliberately drops both (it's a
build tool, not a served API, and needs no external services) and collapses
`src/agents/` back to a single `src/agent/` since it's genuinely one agent.
Include only what the template's project actually needs; don't copy the full
shape by default. See each template's own `README.md` for what it includes
and why.

The anatomy above is specific to the Python-agents family.
`lamp-agents-base` is a different family — no `src/agents/`, no `main.py` —
see its own `README.md`.

## Usage

```bash
bash ~/.the-grid/project-factory/scripts/cut-project.sh [--with-related] [--with a,b | --all-optional] <template> <target-dir>
bash ~/.the-grid/project-factory/scripts/cut-project.sh --generic [--with a,b | --all-optional] [--grid] <target-dir>
```

Mode (seed vs. retrofit) is auto-detected from whether `<target-dir>` already has
files — no flag to remember. Safe to re-run: re-running after a partial retrofit
only adds whatever's still missing. Flags are optional and may sit anywhere among the
arguments (`--with-related`: see Charter files above; `--generic`, `--with`, `--all-optional`: see above).

## Roadmap

- **Placeholder-fill** (project name, description) — not yet implemented; v1
  ships structural stubs only.
- **Shared boilerplate within the Python-agents family** — `python-agents-base`,
  `python-astro-content-agent`, and `finance-agents-base` still duplicate
  `src/models/`, `src/prompts/`, `src/utils/`, test scaffolding between
  themselves. Deliberately accepted for now — independence over inheritance
  for stack-specific code — but worth revisiting if it gets painful to
  maintain. (Session-continuity scaffolding, the other kind of duplication, is
  already factored out into `_common`.)
- **More templates** — Node/TS stacks, multi-agent structures, and templates
  that pair with a specific `agent-factory` role are candidates once there's a
  concrete next use.
