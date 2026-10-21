# Architecture

How the-grid is put together: the factories that produce its assets, how `wire.sh` links
them into place, and where everything lives in the repo. For installing, see
[INSTALL.md](../INSTALL.md); for contributing, see [CONTRIBUTING.md](../CONTRIBUTING.md).

Counts of skills, roles and agents are generated, not typed here: see
[SKILLS.md](../SKILLS.md) for the current numbers.

## The factories

Everything the README describes is produced by one of the rows below, each owning a
different asset type:

| Factory | Produces | Deployed via |
|---------|----------|---------------|
| `agent-factory/` | Composed AI agents (`role × stack × skills`): the public projects (`core`, `grid`, `finance-desk`, `learning-desk`; roles and orchestrators are listed in [SKILLS.md](../SKILLS.md)) plus any private desk composed separately | `scripts/wire.sh` (Claude Code target; opt-in `harness:<name>` entries add Codex, OpenCode, Gemini CLI and others) |
| `automation-factory/` | Reusable automation patterns (e.g. `issue-loop`) | `bash scripts/instantiate.sh issue-loop <repo> --profile work`: cut into a target repo's tracked `loop/` folder; in the default `pr` mode the loop opens draft PRs for a human to merge |
| `project-factory/` | Whole new project scaffolds from a template | `project-factory/scripts/cut-project.sh` (seed or retrofit) |
| Skill wiring | the curated skill set (`skills/` plus the `repos/` submodules) | `scripts/wire.sh`, steered by `baseline-submodules.txt` and `machines/<host>.txt` |

There is deliberately **no factory for specs**: OpenSpec already fills that role; see
the "Spec-driven development (OpenSpec)" section of [CONTRIBUTING.md](../CONTRIBUTING.md).

The README architecture diagram (mermaid) and the inline SVG in `index.html` show the
same nodes. Edit them together, or one will drift from the other (see
[Hand-synced copies](#hand-synced-copies)).

## Wired vs library tiers

Skills are split into two tiers:

- **Wired** — repos in the manifest: a shared `baseline-submodules.txt` (every machine) plus an optional per-machine overlay `machines/<host>.txt` (keyed on `hostname -s`) that adds/subtracts entries. Their skills are symlinked live into `~/.claude/skills/`.
- **Library** — everything else: indexed in `SKILLS.md` and searchable via `skill-scout`, but not symlinked. Keeps the active skill set sane even as the-grid indexes thousands of ecosystem skills.

## How wire.sh works

On each run, `scripts/wire.sh`:

0. Runs the vetting audit (`scripts/audit.sh --wired`) before touching anything. A high-severity finding, a missing `policy.yaml` or a missing `python3` blocks the run (exit 3) with nothing changed.
1. Checks that every directory it will write is resolvable and writable, then tears down all grid-owned symlinks (anything whose target resolves into this repo). An exit trap restores removed links if the run fails or is interrupted before it completes.
2. Re-wires skills from the manifest (baseline + this machine's overlay + the gitignored `machines/<host>.local.txt`), discovered at any nesting depth, and links the runtime roots listed in `scripts/lib/runtimes.txt`.
3. Wires `skills/` last — root skills override any same-named repo skill.
4. Wires composed **agents** from `agent-factory/projects/*/_claude-code/` — orchestrator skills into `~/.claude/skills/`, specialist subagents into `~/.claude/agents/`. Gated per machine by `project:<name>` manifest entries.
5. Wires the root-owned `agents/*.md` into `~/.claude/agents/`, last, so a root-owned agent overrides a same-named composed one.
6. Wires opt-in rule packs (`rules:<pack>` manifest entries) into `~/.claude/rules/grid/<pack>/`.
7. Keeps one generated **auto-handoff** SessionEnd hook entry in `~/.claude/settings.json` (via `agent-factory/deploy_hooks.py --user`).
8. Wires opt-in non-Claude harnesses (`harness:<name>` entries or `GRID_HARNESS`), and delivers the rule packs into an active harness's instruction file if the operator created one.
9. Writes `.wired.manifest` in this repo (one row per decision; gitignored) and regenerates `SKILLS.md` via `catalog.sh`.

Symlinks pointing elsewhere, and real files or directories that share a grid name, are left untouched.

The hook is **on by default**: when a session ends it may run one headless Claude call
to write a handoff note. Your own hooks and keys in `settings.json` are left alone, but the first write reformats the file as 2-space-indented JSON. To switch the hook off, add `-hook:auto-handoff` to the baseline or
your machine overlay (`machines/<host>.txt`) and re-run `wire.sh`, which removes the
entry; details in [hooks/README.md](../hooks/README.md).

Opt-in coding-convention rule packs (`rules:<pack>` manifest entries) are documented in [rules.md](rules.md).

Step 4 wires whatever `compose.py` last produced. Because that output is
git-ignored, a freshly pulled machine must **recompose first** (see
[BOOTSTRAP.md](../BOOTSTRAP.md)) or `wire.sh` will wire a stale/empty agent set.

Override paths via env vars (used by tests):

```bash
GRID_DIR=/path/to/grid SKILLS_DIR=/path/to/skills bash scripts/wire.sh
```

The env vars `wire.sh` reads:

| Variable | Effect |
|---|---|
| `GRID_DIR` | Root of the repo (default: parent of `scripts/`) |
| `SKILLS_DIR` | Claude skills directory (default `~/.claude/skills`) |
| `AGENTS_DIR` | Claude subagents directory (default `~/.claude/agents`) |
| `RULES_DIR` | Claude rules directory (default `~/.claude/rules`); only `$RULES_DIR/grid/` is grid-owned |
| `CLAUDE_CONFIG_DIR` | Claude config dir whose `settings.json` receives the machine-level hook (default `~/.claude`) |
| `GRID_HOST` | Machine key for the overlay (default `hostname -s`) |
| `GRID_BASELINE` | Baseline manifest file (default `$GRID_DIR/baseline-submodules.txt`) |
| `GRID_HARNESS` | Comma list of non-Claude harnesses for this run only; replaces the manifest's `harness:` set |
| `GRID_HARNESS_HOME` | Base for every non-Claude harness dir (default `$HOME`) |
| `GRID_DRY_HOME` | Dry-run home: forces every home-derived target under it and writes nothing to the repo |
| `GRID_AUDIT=warn` | A failed audit prints a warning and wiring continues |
| `GRID_SKIP_AUDIT=1` | The only bypass of the pre-wire audit; prints a notice, not for everyday use |
| `GRID_SKIP_CATALOG=1` | Skip the `SKILLS.md` refresh and the `.wired.manifest` write (used by `--check`) |
| `GRID_NO_CATALOG=1` | Skip only the `SKILLS.md` refresh (set by `grid install`) |

## Repo layout

Derived from `git ls-files`. `repos/`, `openspec/`, `tests/`, `LOGS/` and the dot-directories
are summarised; every other top-level directory, and every file under `scripts/` and
`docs/`, is listed by name.

```
.                       the repo root (cloned to ~/.the-grid by default)
  skills/               ← skills owned by the-grid (original or forked)
  agents/               ← hand-authored root-owned agents (personas/behavior-modifiers)
  machines/             ← per-machine skill/project overlays
    example.txt         ← tracked starting point for an overlay
    <host>.txt          ← GITIGNORED overlay (adds/subtracts on the baseline)
    <host>.local.txt    ← GITIGNORED overlay — private project gates
  agent-factory/        ← composes AI agents (role × stack × skills); see agent-factory/README.md
  automation-factory/   ← reusable automation patterns (e.g. issue-loop), cut into target repos
  project-factory/      ← scaffolds brand-new projects from a template (project-factory/scripts/cut-project.sh)
  evals/                ← golden cases that check how agent roles behave
  hooks/                ← Claude Code guard hooks + the auto-handoff hook (hooks/README.md)
  rules/                ← path-scoped coding-convention rule packs, opt-in (rules.md)
  plugins/              ← GENERATED Claude Code plugin bundles (scripts/build-plugins.py; never hand-edit)
  contexts/             ← opt-in working-mode prompts and the aliases.sh snippet
  dist/                 ← GENERATED portable single-file personas (scripts/build-personas.sh)
  assets/               ← site assets published with index.html (favicon; scripts/build-site-assets.sh)
  signals/              ← claims filed for the knowledge flow, plus agent handoffs (signals/README.md)
  knowledge/            ← recorded claims by stage; canon/ is human-approved (knowledge/README.md)
  _retired/             ← archive, not gated or deployed
  repos/                ← sibling repos as git submodules (each may contain many skill dirs)
  openspec/             ← OpenSpec changes (proposals, design, tasks) for the-grid itself
  tests/                ← bats suites; lib/bats-core/ is the runner (submodule, no install needed)
  .claude-plugin/       ← marketplace.json, generated by scripts/build-plugins.py
  .githooks/            ← pre-commit hook (runs the fast part of scripts/gate.sh)
  .github/              ← CI workflows, dependabot config, PR template
  scripts/
    grid                ← submodule-free install CLI (install, lock, doctor, repair, ...; BOOTSTRAP.md)
    bootstrap.sh        ← one-shot setup: submodules → wire (--with-agents: compose too)
    wire.sh             ← creates the ~/.claude symlinks (idempotent)
    catalog.sh          ← regenerates SKILLS.md
    sources.sh          ← regenerates docs/SOURCES.md; --check link-checks every URL
    reconcile.sh        ← moves stale skill shadows aside (dated backup dir) on a new machine
    check-grid.sh       ← full bats suite + broken-symlink scan (CI / pre-push gate)
    gate.sh             ← the commit gate: shellcheck, catalog, role lint, composed output, tests
    instantiate.sh      ← cuts an automation-factory pattern into a target repo
    audit.sh            ← chooses what to scan (--owned, --wired, --gate)
    audit.py            ← the offline vetting scanner that wire.sh runs before touching any link
    budget.py           ← measures and gates the skill/role description budget (docs/budget-target.json)
    build-plugins.py    ← generates plugins/ and .claude-plugin/marketplace.json
    build-personas.sh   ← regenerates dist/personas/
    build-site-assets.sh ← renders the landing-page images from one source PNG
    stage-site.sh       ← copies the files named in site-files.txt into the Pages artifact
    stamp-counts.py     ← restamps generated counts in the README and index.html
    check-personal.sh   ← scans the tracked tree for personal data
    personal-patterns.txt ← public generic rules for check-personal.sh
    personal-allow-paths.txt ← paths check-personal.sh skips, each with a reason
    personal-denylist.example.txt ← starting point for the private denylist
    compose-goldens.sh  ← golden-output check for compose.py
    map.py              ← generates MAP.md; `status` prints stage and signal counts
    rules.py            ← lints, lists and emits the rule packs (rules/)
    run-record.sh       ← appends one line per agent run to a local private log
    runtime-setup.sh    ← human-run setup for wired repos that need a runtime (e.g. gstack)
    prune-report.sh     ← read-only report of what to drop from the baseline
    instincts.sh        ← habit learning from your own sessions (docs/instincts.md)
    auto-handoff-preflight.sh ← live checks that gate the auto-handoff hook
    repo-metadata.sh    ← compares (and optionally sets) the GitHub description, homepage and topics
    instincts/          ← analyse.py, capture.py, evalcases.py, inject.py, lib.py, prompts/analyse-v1.md
    usage/              ← weekly usage job: extract.py, aggregate.py, prune_report.py, usage_schema.py, weekly.sh, install-schedule.sh, adapters/claude_code.py, adapters/__init__.py
    lib/                ← helpers shared by the scripts above
      baseline_wired.py   ← which skills the baseline would wire (used by budget.py)
      find-skill-mds.sh   ← lists SKILL.md files, tracked-only inside submodules (shared with catalog.sh)
      fmshape.py          ← shape check for SKILL.md / agent frontmatter
      fmyaml.py           ← deny-by-default reader for a frontmatter hooks block
      miniyaml.py         ← restricted-YAML reader for policy.yaml and grid.yaml
      skill_frontmatter.py ← reads a SKILL.md's name and description
      skill-portable.sh   ← sourced by wire.sh: portable-skill helpers
      harness.sh          ← sourced by wire.sh: non-Claude harness wiring
      harnesses.txt       ← registry of non-Claude harness dirs
      rules-markers.txt   ← marker lines of the managed rules block
      runtimes.txt        ← wired repos whose skills need a runtime root
      skill-excludes.txt  ← tracked skill paths wire.sh and catalog.sh skip
      render-schedule.sh  ← renders the launchd/systemd/cron schedule for the usage and instincts jobs
      private-git-guard.sh ← safety checks for the unattended jobs that commit to the private repo
  docs/
    architecture.md     ← this file
    PLUGINS.md          ← the generated Claude Code plugin bundles
    SOURCES.md          ← generated: upstream URL per submodule (never edit)
    agent-retro.md      ← review loop that starts from the run record
    harnesses.md        ← non-Claude harness targets and what is verified
    instincts.md        ← habit learning: capture, analysis, injection
    issue-loop-runbook.md ← operating runbook for the live issue-loop instance
    model-selection.md  ← which model for which job, with prices + benchmarks
    reference-repos.md  ← curated external repos
    reference-resources.md ← curated external references
    rules.md            ← the rule packs and how to opt in
    uplift-runbook.md   ← how uplift work is built and merged
    usage.md            ← the weekly usage job
    budget-target.json  ← the committed ratchet read by scripts/budget.py
    prune-keep.txt      ← names the prune report never proposes to drop
    architect-agent-composition.yaml ← sample compose config from the early design
    architect-agent-factory ← sketch of the early agent-factory tree
    business-tier/      ← design for a business repo published as a plugin marketplace
      README.md, SPEC.md, DECISIONS.md, RESEARCH.md, DELEGATION-GATE.md
  index.html            ← the GitHub Pages landing page
  site-files.txt        ← the paths GitHub Pages publishes (read by scripts/stage-site.sh)
  the-grid.png          ← source image for the landing-page assets
  the-grid.txt          ← the ASCII banner
  README.md             ← the front door
  INSTALL.md            ← short install guide
  CONTRIBUTING.md       ← how to contribute
  BOOTSTRAP.md          ← the full machine boot sequence and update/troubleshooting reference
  USAGE.md              ← walkthrough of the slash commands and factories
  CLAUDE.md             ← full project context for Claude sessions
  SKILLS.md             ← generated skill index (never edit by hand)
  MAP.md                ← generated session-start map (scripts/map.py; never edit by hand)
  PURPOSE.md, GUARDRAILS.md, BEHAVIOUR.md ← what the grid is for, its must-nots, its agent-behaviour additions
  CURATION.md           ← the human-readable trust record and audit allowlist
  LEARNINGS.md          ← durable lessons mined from project history
  THIRD-PARTY-NOTICES.md ← licences of bundled third-party material
  LICENSE               ← MIT
  TODO.md               ← issue map; open work lives in GitHub Issues
  policy.yaml           ← vetting policy read by scripts/audit.py
  grid.yaml, grid.lock  ← where wired skills come from, and the pinned commits (scripts/grid)
  baseline-submodules.example.txt ← tracked starting point; copy to baseline-submodules.txt
  baseline-submodules.txt ← GITIGNORED, personal — your own baseline allowlist
  .gitignore, .gitmodules, .nojekyll ← git and Pages housekeeping
```

`LOGS/` (a dev-journal convention some skills write to) is gitignored too —
nothing in the-grid requires it, and it isn't part of the layout above.

## Reference docs

Every `docs/*.md` file in the repo, so a reader can reach each from here:

- [PLUGINS.md](PLUGINS.md) — the generated Claude Code plugin bundles
- [SOURCES.md](SOURCES.md) — generated: upstream URL per submodule
- [agent-retro.md](agent-retro.md) — review loop that starts from the run record
- [harnesses.md](harnesses.md) — non-Claude harness targets
- [instincts.md](instincts.md) — habit learning from your own sessions
- [issue-loop-runbook.md](issue-loop-runbook.md) — operating runbook for the issue-loop
- [model-selection.md](model-selection.md) — which model for which job
- [reference-repos.md](reference-repos.md) — curated external repos
- [reference-resources.md](reference-resources.md) — curated external references
- [rules.md](rules.md) — rule packs
- [uplift-runbook.md](uplift-runbook.md) — uplift runbook
- [usage.md](usage.md) — the weekly usage job

Planned in this change, plain text until the files exist: [docs/roadmap.md](roadmap.md) (the roadmap
and model-routing note) and [docs/private-projects.md](private-projects.md) (composing a private desk).

## Hand-synced copies

Some text exists in more than one place and is kept in step by hand. Change one, change
them all:

- **Quickstart command:** `README.md`, `INSTALL.md`, `index.html` (`#install-cmd`) and `docs/demo/demo.tape`.
- **Hero sentence:** `README.md` and `index.html`.
- **Architecture diagram:** the mermaid block in `README.md` and the inline SVG in `index.html` (Pages cannot render mermaid without a CDN script, so the SVG is hand-authored with the same nodes).
