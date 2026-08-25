# the-grid — Claude context

the-grid is Gareth's wiring hub for the AI-agent ecosystem — Claude / OpenClaw /
Paperclip / Hermes / opencode and friends. **It is not skills-only**: skills are
the first asset type it wires, but the remit is broader (commands, agents, MCP
servers, plugins, configs may follow). It owns some assets directly and pulls many
more from sibling repos via git submodules.

`wire.sh` symlinks **skills** into `~/.claude/skills/` so Claude picks them up. It
also wires **composed agents** from `agent-factory/` (see below): orchestrator
skills into `~/.claude/skills/`, specialist subagents into `~/.claude/agents/`. To
keep the active set sane while still indexing the whole ecosystem, the-grid splits
submodules into two tiers:

- **Wired** — a small curated allowlist whose skills are symlinked live into
  `~/.claude/skills/`. The allowlist is **layered**: a shared
  `baseline-submodules.txt` (wired on every machine) plus an optional per-machine
  overlay at `machines/<hostname>.txt` (host = `hostname -s`) that adds or
  subtracts entries. wire.sh unions baseline + overlay.
- **Library** — everything else: indexed in `SKILLS.md` and searchable by
  `skill-scout`, but **not** wired (so a session isn't drowned in thousands of
  skills). Promote a library repo to wired by adding its name to the baseline.

## What lives where (ownership principle)

- **Root-level dirs are for skills Gareth owns or has edited for his own purposes.**
  Only put a skill at the repo root if it's original to the-grid, or if it's an
  upstream skill that's been deliberately forked/edited and must not track upstream.
- **Everything else is managed upstream** in `repos/*` submodules and wired on
  demand. Don't copy an upstream skill into the root just to use it — the submodule
  copy gets wired automatically.
- If a root skill is byte-identical to (or merely an older snapshot of) a submodule
  copy, it's redundant: delete the root dir and let the submodule own the slot.
- When root and submodule both provide the same skill name, **the root copy wins**
  (wire.sh wires repos first, root last). That's the escape hatch for an edited fork.

## Key files

- `BOOTSTRAP.md` — **full machine boot sequence**: clone → submodules → wire skills → compose agents → wire agents. Start here on a new machine.
- `scripts/wire.sh` — the wiring script. Idempotent. Tears down all grid-owned symlinks
  and rebuilds the wired set each run (so un-wiring a repo actually removes it).
- `baseline-submodules.txt` — the baseline allowlist of submodules whose skills are
  wired live on **every** machine. Anything not listed is library-only. Also gates
  composed projects via `project:<name>` entries. Delete the file to wire everything (legacy).
- `machines/<hostname>.txt` — per-machine overlay layered on the baseline (`hostname -s`).
  Adds (`repo`, `repo/skill`, `project:<name>`) or subtracts (`-repo`, `-repo/skill`,
  `-project:<name>`) for that host only. Absent overlay → baseline as-is.
- `scripts/catalog.sh` — regenerates `SKILLS.md`: wired skills in full detail, library
  repos as counts, reference (no-skill) repos in a footer. Deterministic output.
- `SKILLS.md` — generated index of the whole ecosystem. Never edit by hand.
- `scripts/sources.sh` — regenerates `docs/SOURCES.md` (one upstream URL per
  submodule, tier from the baseline). `--check` HEADs every URL as a rot detector,
  non-zero exit on failure. Deterministic; never edit `SOURCES.md` by hand.
- `docs/model-selection.md` — which model for which job, with prices, independent
  benchmarks, worked cost maths, and a dated expiry watchlist. Refreshed on demand
  via `/grid-researcher` using the brief at the bottom of the file.
- `tests/` — bats test suite. Run with `tests/lib/bats-core/bin/bats tests/`.
- `repos/` — sibling skill repos as git submodules. Each submodule may contain multiple skill dirs.
- `TODO.md` — current outstanding work.

## Getting a machine up to date

Plain-English sequence for the three things a machine needs: current
**submodules** (the sibling skill repos), current **skills** (symlinked into
`~/.claude/skills/`), current **agents** (composed subagents + orchestrator
skills, symlinked into `~/.claude/agents/`).

### New machine (never had the-grid before)

1. Clone the-grid to `~/.the-grid`.
2. Pull in submodules: `git submodule update --init --recursive`.
3. Wire skills: `bash scripts/wire.sh` — skills are live now.
4. Build the agent teams: `cd agent-factory && python3 -m venv .venv &&
   .venv/bin/pip install -r requirements.txt && .venv/bin/python compose.py
   examples/core.yaml --target claude-code && .venv/bin/python compose.py
   examples/grid.yaml --target claude-code && .venv/bin/python compose.py
   examples/finance-desk.yaml --target claude-code`. (Three public projects,
   composed independently — a private desk, if you have one, composes the
   same way with `GRID_PRIVATE_ROLES_DIR` set; see the agent-factory section
   below.)
5. Wire again from the repo root: `bash scripts/wire.sh` — agents are live now.

(Steps 2–5 are exactly what `scripts/bootstrap.sh --with-agents` does in one shot.)

### Existing machine (already set up, just did `git fetch && git pull`)

1. Pull the-grid itself — done (that's what triggered this).
2. Refresh submodules to match what the pull moved the pointers to:
   `git submodule update --init --recursive`.
3. Refresh agents — but only if the pull touched anything under
   `agent-factory/` (composed output there is git-ignored, so a pull alone
   never updates it). Check with:
   `git diff --stat HEAD@{1} HEAD -- agent-factory/`.
   If it shows changes: `cd agent-factory && .venv/bin/python compose.py
   examples/core.yaml --target claude-code && .venv/bin/python compose.py
   examples/grid.yaml --target claude-code && .venv/bin/python compose.py
   examples/finance-desk.yaml --target claude-code && cd ..` (recompose all
   three public projects — cheap even if only one actually changed).
   If it shows nothing: skip this step.

   > ⚠ **Recompose every private project too, in the same pass.** A change to
   > `agent-factory/_core/` or `compose.py` affects *all* projects, but only the
   > three public configs are listed above. `compose.py` **overwrites**
   > `projects/<name>/` wholesale — so recomposing the public set while a
   > private project's roles are unreachable (repo not cloned,
   > `GRID_PRIVATE_ROLES_DIR` unset) silently destroys that project's composed
   > output, and the next `wire.sh` tears down its symlinks. This has already
   > happened once. Check `ls agent-factory/projects/` against
   > `machines/<host>.local.txt` **before** recomposing; if a `project:` gate
   > there has no matching config you can reach, stop and fix that first.
4. Refresh skills (and agents, and `SKILLS.md`) in one go: `bash scripts/wire.sh`.
   Always safe to run, always run it last.

### ⚠ Pending: agent rename migration (2026-07-19)

`grid.yaml` was split into three sibling projects (`core`, `grid`,
`finance-desk`) — some agent names changed as a result:

| Old name | New name |
|---|---|
| `grid-librarian` | `core-librarian` |
| `grid-gh-triage` | `core-gh-triage` |
| `grid-finance-manager` (skill) | `finance-desk-finance-manager` |
| `grid-finance-sentinel` | `finance-desk-finance-sentinel` |
| `grid-finance-analyst` | `finance-desk-finance-analyst` |
| `grid-finance-strategist` | `finance-desk-finance-strategist` |
| `grid-finance-risk-officer` | `finance-desk-finance-risk-officer` |
| `grid-finance-scribe` | `finance-desk-finance-scribe` |
| `grid-researcher` | `core-researcher` (moved 2026-08-25) |

`baseline-submodules.txt` now gates three projects (`project:core`,
`project:grid`, `project:finance-desk`) instead of one — this machine's
manifest also needs a plain `git pull` to pick that up (it's a tracked file,
not gitignored output).

**2026-08-25 — `researcher` moved `grid` → `core`.** It's a domain-general
role, so it shouldn't vanish on a machine that subtracts `-project:grid`.
Tech Lead lost it as a delegate and now routes research to `core-researcher`
directly (see `roles/tech-lead/AGENTS.md`). Same migration action as the rows
above: recompose, re-wire, confirm `grid-researcher` is gone.

**If you're a session on a machine in the checklist below**: follow "Existing
machine" above (which now composes all three projects), confirm the old
names are gone from `~/.claude/agents` / `~/.claude/skills` and the new ones
resolve, then delete your machine's line from the checklist and commit that
edit. **Once the checklist is empty, delete this entire subsection**
(including this sentence) and commit that too — this is a one-time migration
flag, not permanent documentation.

Machines with a the-grid clone still on the pre-split names:

- [ ] forge
- [x] wilderness — done 2026-08-04 (split), 2026-08-25 (researcher move);
      verified `core-*` / `finance-desk-*` / `core-researcher` resolve
- [ ] guide-server

## Adding a skill

Create a directory at the repo root with a `SKILL.md` inside it. Frontmatter requires `name:` and `description:`. Then run `bash scripts/wire.sh`.

## Regenerating the skill catalogue

```bash
bash scripts/catalog.sh        # rewrites SKILLS.md from every SKILL.md's frontmatter
```

`scripts/wire.sh` calls `scripts/catalog.sh` automatically as its final step, so wiring and
`SKILLS.md` never drift — you rarely need to run it by hand. Output is sorted and
timestamp-free, so an unchanged skill set yields an identical file (clean diffs).
A repo-root `SKILL.md` (gstack marker) is excluded, matching wire.sh.

## Adding a sibling repo

```bash
git submodule add <repo-url> repos/<name>
git submodule update --init
bash scripts/wire.sh
```

A newly added submodule is **library by default** (indexed, not wired). To wire its
skills live everywhere, add its `repos/<name>` dir name to `baseline-submodules.txt`
(or to a single machine's `machines/<host>.txt` overlay) and re-run
`bash scripts/wire.sh`. This keeps `~/.claude/skills/` small even as the-grid indexes
thousands of ecosystem skills.

### Reference submodules (indexes, not skill collections)

Some submodules are awesome-lists / indexes with **no `SKILL.md` files** (e.g.
`repos/voltagent` — VoltAgent's `awesome-openclaw-skills`, a categorised index of
OpenClaw-ecosystem skills). These are kept for browsing and as a source for
`skill-scout`, not for wiring. They need no special config: wire.sh wires nothing
from them (no skills to find), and catalog.sh auto-detects the empty case and lists
them under "Reference submodules" in `SKILLS.md` instead of an empty skill section.
Refresh one with `git submodule update --remote repos/<name>`.

## Reconciling a machine (removing stale shadows)

`wire.sh` won't clobber a *real* directory that shadows a grid skill (safety).
On a fresh machine those shadows are often stale, root-owned copies. `reconcile.sh`
removes them so the-grid owns the slot, then re-wires. It parses wire.sh's own
`skip (real dir, not managed)` output, so it never hardcodes names.

```bash
bash scripts/reconcile.sh          # dry run — list shadowing dirs
bash scripts/reconcile.sh --force  # remove them (sudo only where needed) + re-wire
```

Idempotent: a fully-wired machine reports "Nothing to reconcile".

## Running tests

```bash
tests/lib/bats-core/bin/bats tests/
```

All 38 tests must stay green. Tests use temp dirs — they never touch the real `~/.claude/skills/` or `~/.claude/agents/`.

## wire.sh contract

- `GRID_DIR` env var overrides the repo root (default: script's own directory).
- `SKILLS_DIR` env var overrides the skills target (default: `~/.claude/skills/`).
- `AGENTS_DIR` env var overrides the subagents target (default: `~/.claude/agents/`).
- Only manages symlinks that point into `GRID_DIR` — never touches foreign symlinks.
- Skills in `repos/*/` are discovered at **any depth** via `find` (flat, `skills/`,
  `skills/<category>/`, etc.) — wire.sh symlinks each dir containing a `SKILL.md`,
  skipping a `SKILL.md` sitting at a repo root.
- Only submodules in the manifest (`baseline-submodules.txt` + `machines/<host>.txt`
  overlay) are wired; the rest are library-only. If no manifest exists, all repos are
  wired (legacy fallback). `catalog.sh` reads the **baseline only** (machine-agnostic,
  deterministic `SKILLS.md`).
- **Machine key:** `GRID_HOST` env var overrides the overlay host (default `hostname -s`).
- **Composed agents:** wire.sh also wires `agent-factory/projects/*/_claude-code/`
  output — orchestrator skills into `SKILLS_DIR`, specialist subagents into
  `AGENTS_DIR`. Gated per machine by `project:<name>` manifest entries; with no
  `project:` entry anywhere, every composed project wires (legacy). The baseline
  currently pins `project:core`, `project:grid`, and `project:finance-desk` (see
  `agent-factory/` and issue #1) — a task-specific machine can subtract
  `-project:grid` or `-project:finance-desk` via its overlay to trim clutter,
  but `project:core` (gh-triage, librarian, researcher) is meant to stay on
  every machine.
- **Root-owned agents:** `agents/*.md` at the repo root wires directly into
  `AGENTS_DIR`, same ownership model as root-level `skills/` — for hand-authored
  subagents that aren't a compose.py role (no `delegates_to`, not a team
  position; e.g. a ported persona/behavior-modifier like `grid-ponytail`).
  Wired last, so a root-owned agent overrides a same-named composed one.

## agent-factory (composed agents)

`agent-factory/` composes AI dev-team agents from a single config
(`role × stack × skills`). `compose.py` is a multi-target compiler: one source (the
live OpenClaw 5-file identity model — SOUL/IDENTITY/AGENTS/USER/MEMORY + skills)
emits to different runtimes via `--target`. The **Claude Code** target is built and
wired live: orchestrator roles (`role.yaml orchestrator: true`) → CC **skills**
(invoke with `/<role>`); specialist roles → CC **subagents** (delegate to them, or
an orchestrator hands off). OpenClaw + Paperclip (autonomous) targets are the next
work. See `agent-factory/README.md` and `LOGS/2026-06-16-handoff-agent-factory.md`.

**Orchestrator rosters are generated, not hand-written.** Each orchestrator declares
its reports via `delegates_to:` in the compose config (the delegation topology lives
with the team, the single source of truth). `compose.py` renders a roster table from
that list and injects it at the `{{ROSTER_TABLE}}` token in the role's `AGENTS.md`
(`owns` text = `role.yaml owns:` override, else the summary's first sentence). Validation
is symmetric and loud: a token with no `delegates_to` (or vice-versa), or a delegate not
on the team, is a hard compose error — so a roster can never silently drift out of sync
with the team. grid topology: `ceo → tech-lead, product-manager, growth-hacker`;
`tech-lead → eng + data`; `growth-hacker → the marketing arm` (a player-coach
orchestrator). `examples/grid.yaml` is the **dev-team project** — 19 roles: 3
orchestrators → CC skills, 16 specialists → CC subagents.

Two sibling public projects, same repo, composed and gated independently:
`examples/finance-desk.yaml` — `finance-manager → the finance desk pipeline`
(sentinel → analyst → strategist → risk-officer → scribe), a **standalone**
top-level orchestrator, deliberately never under the CEO's `delegates_to` — a
personal desk, not a dev-team initiative. `examples/core.yaml` — cross-desk
shared infra with no delegation chain (`gh-triage`, `librarian`,
`researcher` — the general-purpose investigator, domain-general on purpose
and gated here so it survives `-project:grid`), gated
`project:core` and meant to stay wired on every machine regardless of which
desk-specific project (`grid`, `finance-desk`, or a private desk) that
machine actually runs — the three projects split apart specifically so a
task-specific machine can subtract a whole desk via its overlay
(`-project:grid`, `-project:finance-desk`) without losing the other two. A
private desk (e.g. a personal research vertical) can be composed the same
way, sourcing roles from `GRID_PRIVATE_ROLES_DIR` — never committed to this
repo; see compose.py's `role_dir()`.

> **Rollout note:** `agent-factory/projects/*` is git-ignored (regenerable output). A
> machine picks up roster/topology changes only after `git pull` **then re-running
> `compose.py`** (BOOTSTRAP step 4) and `wire.sh` — pulling alone is not enough.

## Spec-driven development (OpenSpec)

the-grid wires [OpenSpec](https://openspec.dev) (`repos/openspec`, MIT) on every
machine — 12 `openspec-*` workflow skills, gated as a whole-repo baseline entry
minus the maintainer-only `release-openspec`. **They shell out to a CLI that is
not vendored**: `npm i -g @fission-ai/openspec@latest` (Node >= 20.19.0). Without
it every one of those skills is inert.

There is deliberately **no fifth "spec-factory"**. OpenSpec already is the spec
factory; what the-grid adds is two thin layers:

- `project-factory/templates/_common/SPECS.md` — the convention, both adoption
  paths (greenfield `openspec init`; brownfield = specs grow per-change, never
  big-bang back-filled), and agent instructions. In `_common`, so **every** cut
  project gets it, seed or retrofit — spec-driven is the default, not a
  per-project decision someone has to remember. It documents only; the CLI owns
  the `openspec/` tree it creates.
- `agent-factory/_core/AGENTS_base.md` — a boot-sequence check for `SPECS.md` /
  `openspec/`. One edit reaches all 28 composed agents across the three projects.
  Conditional: repos without the markers are untouched.

`skills/spec-scout/` audits adoption and reports spec↔code drift (survey-only,
mirroring `skill-scout` — never runs `openspec init`, never writes specs).

## project-factory (project bootstrapping)

`project-factory/` scaffolds whole new projects from a template — a different job
from `skills/` (wired), `agent-factory/` (composes personas), and
`automation-factory/` (cuts a pattern into an existing repo's `.claude/`-adjacent
`loop/`). A `project-factory` template is standalone: no logic of its own, doesn't
run, doesn't depend on the-grid once cut. `scripts/cut-project.sh <template>
<target-dir>` either **seeds** a brand-new project (empty target) or **retrofits**
an existing one (non-empty target) — same script, same rule either way: never
overwrite a file that already exists and differs from the template; anything
skipped is reported for manual review. Composition (which `agent-factory`
persona, which skills, which `automation-factory` pattern) happens *after*
seeding, as a normal step in the resulting repo — `project-factory` itself stays
out of that decision. See `project-factory/README.md`.

## Learnings

Durable lessons mined from project history — full context and sources in
`LEARNINGS.md` (generated/maintained by the `mine-learnings` skill).

- Scripts whose output is committed/diffed across machines (like `catalog.sh`)
  must pin locale (`LC_ALL=C`) and compute counts from a controlled pre-pass,
  not a raw `find`/`wc` sweep — see LEARNINGS.md ("Cross-machine scripts must
  pin locale...").
- Skills that write files from multiple machines (like `handoff`) must scope
  filenames by hostname and verify target directory names rather than assume
  them — see LEARNINGS.md ("Handoff output paths...").
- Library-tier submodules churn independently and can inflate curated counts;
  keep headline skill totals derived only from wired/root-owned skills, and
  don't casually `--remote` update noisy library repos — see LEARNINGS.md
  ("Library submodules can churn...").
- When writing role/`SKILL.md` instructions for a rule that must never be
  violated (e.g. gh-triage skip logic), state it as an explicit imperative
  block — don't rely on step ordering to imply it — see LEARNINGS.md ("Agent
  instructions that must never be skipped...").
- Don't write bash-style unquoted-`$var` word-splitting in ad-hoc shell
  commands — Gareth's machines may run zsh, which doesn't word-split by
  default — see LEARNINGS.md ("zsh doesn't word-split...").
- A cron-driven, non-delegating role (e.g. `gh-triage`) doesn't need a project
  of its **own** — but a shared `core` project for cross-desk infra (roles no
  single desk owns, meant to survive that desk being subtracted on a
  task-specific machine) is a real category, not project-proliferation for
  its own sake. `gh-triage`, `librarian` and `researcher` all live there now.
- A role only looks team-owned until you ask what happens when that team is
  gated off. `researcher`'s method was always domain-agnostic — only its
  membership in `grid.yaml` made it look like a dev-team role. Moving it to
  `core` cost one `delegates_to` edit and a routing note in the orphaned
  orchestrator; the role content didn't change at all.
- Splitting a desk (e.g. `finance-desk`) out of a larger composed project is
  free when that desk's orchestrator was already standalone (not in anyone's
  `delegates_to`) — the delegation topology doesn't change, only which
  compose config file it's read from.

## About

the-grid is Gareth's brainchild — a personal, evolving system for organising and
wiring up his Claude skills. Intended to eventually be a public repo. Treat it as
an extension of how Gareth thinks and works, and keep it tidy as it grows.
