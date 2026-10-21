# Using the-grid

Setup is covered in [README.md](README.md) and [BOOTSTRAP.md](BOOTSTRAP.md). This
file is the other half: once it's wired, here's how you actually drive it in a
Claude Code session.

## Skills — slash commands

Every wired skill is a slash command in any Claude Code session, anywhere on the
machine — no per-project setup. Some examples:

```
/standup          — standup summary from recent git activity
/rubber-duck       — structured rubber duck debugging
/skill-scout       — find new skills to add to the-grid
/ponytail          — force the laziest solution that actually works
/handoff           — compact this conversation into a handoff doc
```

Full list: [SKILLS.md](SKILLS.md) (wired skills in detail, library repos as counts).
Don't remember the exact name? Ask Claude directly — "is there a skill for X?" — it
can see the wired set and will invoke the right one.

### Start here if you're lost

Three reference-card skills, each one-shot — they print and stop:

```
/grid-help        — which command or subagent do I want? how do the factories differ?
/openspec-help    — which of the 12 openspec skills? how do I add specs to a repo?
/ponytail-help    — which ponytail mode?
```

## Agents — orchestrators vs subagents

`agent-factory/` composes four public projects (plus any private desk you've
set up separately — composed the same way from `GRID_PRIVATE_ROLES_DIR`, see
CLAUDE.md). Two different invocation shapes:

| Form | Roles | How to invoke |
|------|-------|----------------|
| **Skill** (orchestrator) | `grid-ceo-orchestrator`, `grid-tech-lead`, `grid-growth-hacker`, `finance-desk-finance-manager`, `tron`, `morpheus`, `oracle` | Slash command, e.g. `/grid-tech-lead`. Transforms the session into that role for the rest of the conversation. |
| **Subagent** (specialist) | the other 32 roles | Not a slash command. Either delegate explicitly — *"use the grid-backend-dev subagent to implement this"* — or let an orchestrator hand off automatically once you've invoked it. |

Typical flow: `/grid-ceo-orchestrator` to scope a business goal → it delegates
to `grid-tech-lead` / `grid-product-manager` / `grid-growth-hacker` → those
delegate further down to specialists. You can also skip straight to a
specialist subagent for a narrow task without going through an orchestrator
at all.

Four composed projects, each independently wired and gated
(`project:<name>` in `baseline-submodules.txt` or a machine overlay):

- **`grid`** — the dev team (engineering, product, marketing).
- **`finance-desk`** — the personal finance pipeline
  (`finance-desk-finance-manager` → sentinel/analyst/strategist/risk-officer/
  scribe). Standalone, not part of the CEO's chain — invoke directly.
- **`core`** — cross-desk shared infra (`core-gh-triage`, `core-librarian`,
  `core-researcher`, `core-platform-engineer`, `core-context-engineer`, and
  `/tron`, the front door that
  recommends which skill or agent to use), meant to stay wired regardless
  of which desk-specific project a machine runs.
- **`learning-desk`** — the learning agents, all operator-triggered: `/morpheus`
  (Socratic tutor), `/oracle` (learns about you, privately) and `tank`
  (agent-to-agent lessons from the run log).

A task-specific machine can subtract a whole desk (`-project:grid` or
`-project:finance-desk`) via its overlay to cut clutter, while keeping `core`.

### Private projects

A fourth kind of project composes from roles that live **outside this repo**
entirely — `GRID_PRIVATE_ROLES_DIR` points `compose.py` at an external roles
directory, and the `project:<name>` gate goes in `machines/<host>.local.txt`,
which is gitignored. Neither the roles nor the gate enter this repo's history.

Composed output lands in `agent-factory/projects/` like any other project and
wires identically — orchestrator → slash command, specialists → subagents. The
mechanism is public; only the content is private.

```bash
GRID_PRIVATE_ROLES_DIR=~/path/to/private/roles \
  agent-factory/.venv/bin/python agent-factory/compose.py \
  ~/path/to/private/projects/<name>.yaml --target claude-code
bash scripts/wire.sh
```

> ⚠ `compose.py` overwrites `projects/<name>/` wholesale. Recomposing the public
> projects while a private project's roles are unreachable (repo not cloned, env
> var unset) destroys that project's composed output, and the next `wire.sh`
> removes its symlinks. Check `machines/<host>.local.txt` against
> `ls agent-factory/projects/` before recomposing.

## Specs — planning that outlives the session

Any repo can be spec-driven. Specs live in `openspec/` as plain markdown, and a
proposal gets reviewed **before** code exists.

```
/openspec-explore        — think through options, writes nothing
/openspec-propose        — create the change + all artefacts in one pass
/openspec-apply-change   — implement the tasks (after review)
/openspec-verify-change  — does the implementation match the spec?
/openspec-archive-change — fold the delta into specs/, move to archive/
```

Twelve skills in total — `/openspec-help` maps the rest. `/spec-scout` audits
adoption and reports spec↔code drift without writing anything.

Needs the CLI (`npm i -g @fission-ai/openspec@latest`, Node >= 20.19.0). `openspec
init` is optional — `openspec new change` bootstraps `openspec/` on its own.

Projects cut by `project-factory` get the convention automatically via
`_common/SPECS.md`, and composed agents check for it at boot — so in a
spec-driven repo they read the spec before implementing, and propose rather than
skipping to code.

## automation-factory — recurring unattended work

For work that should loop over a backlog without a human driving each turn (e.g.
working a repo's labelled GitHub issues), cut a pattern into the target repo instead
of running it ad hoc in a session. One command does the whole cut: it copies the
pattern into a tracked `loop/` folder, renders `loop/loop.conf` once, creates the
labels and runs `loop/setup.sh`:

```bash
bash scripts/instantiate.sh issue-loop <target-repo> --profile work --verify-cmd "<your gate>"
bash loop/run-issue.sh      # from the target repo: works ONE labelled issue, by hand
```

The loop opens pull requests and never merges; the runner runs your verify command
itself before it pushes anything. Full steps and the list of known gaps:
[automation-factory/patterns/issue-loop/README.md](automation-factory/patterns/issue-loop/README.md).

## project-factory — starting a brand-new project

```bash
bash ~/.the-grid/project-factory/scripts/cut-project.sh <template> <target-dir>
```

Seeds an empty `target-dir` or retrofits a non-empty one — same script either way,
never overwrites a file that already differs from the template. Available
templates and what each assumes: [project-factory/README.md](project-factory/README.md).
Composing an agent-factory persona, wiring skills, or adding an automation-factory
pattern into the new project all happen *after* the cut, as normal steps in that
repo.

## Context modes

Optional: start Claude Code already in a working mode (dev, research or review).
Add this line to `~/.zshrc` or `~/.bashrc`, then open a new shell:

```bash
source "$HOME/.the-grid/contexts/aliases.sh"
```

You then have `claude-dev`, `claude-research` and `claude-review`. Each is
`claude --append-system-prompt-file <mode file>`, so the mode text is added to
Claude Code's own prompt, not a replacement for it. Extra arguments pass through,
e.g. `claude-review "check PR 12"`. The mode files are in `contexts/` (each under
1200 bytes); edit them to taste.

## Growing what's wired

- **Found a useful skill in the library (or on the internet)?** Run `/skill-scout`
  to search and propose additions, or add the repo/skill name to
  `baseline-submodules.txt` (every machine) or `machines/<host>.txt` (this machine
  only) and re-run `bash scripts/wire.sh`.
- **Adding a whole new sibling repo?** `git submodule add <url> repos/<name>` — it
  lands as library-only until you promote it into one of the manifests above.
- **Writing an original skill?** Create `skills/<name>/SKILL.md` at the repo root
  (frontmatter needs `name:` + `description:`), then `bash scripts/wire.sh`.

## Keeping it healthy

```bash
bash scripts/check-grid.sh      # the full test suite (many minutes; the CI `gate` job that includes it ran 18-30 min in recent Actions runs) + broken-symlink scan
tests/lib/bats-core/bin/bats tests/   # the same test suite directly, without the symlink scan
bash scripts/sources.sh --check # link-check every submodule upstream URL
```

A `pre-commit` hook runs `scripts/gate.sh` (which includes the tests) automatically before
every commit in this repo (bypass with `git commit --no-verify` or `GRID_SKIP_HOOK=1`).

`sources.sh --check` is the rot detector: upstream repos get renamed, deleted, or
made private with no local symptom until a fresh machine tries to clone. Run it
occasionally, not every commit.

## Where to look next

- [SKILLS.md](SKILLS.md) — generated index of every wired + library skill.
- [docs/SOURCES.md](docs/SOURCES.md) — generated: upstream URL + tier per submodule.
- [docs/model-selection.md](docs/model-selection.md) — which model for which job:
  prices, independent benchmarks, worked cost maths, and what's *not* known.
- [TODO.md](TODO.md) — map of the open issues (GitHub Issues is the source of truth).
- [LEARNINGS.md](LEARNINGS.md) — durable lessons mined from project history.
- [CLAUDE.md](CLAUDE.md) — full technical context, for Claude sessions and for you.
