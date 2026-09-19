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
  subtracts entries. wire.sh unions baseline + overlay. Both are **personal
  curation, not tracked in this repo** (see #24) — each machine keeps its own,
  seeded from `baseline-submodules.example.txt` / `machines/example.txt`.
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
  composed projects via `project:<name>` entries. Delete the file to wire everything
  (legacy). **Gitignored, not tracked** (#24) — personal curation. A fresh machine
  seeds its own from the tracked `baseline-submodules.example.txt`; edit the local
  copy, not the example, for day-to-day changes.
- `machines/<hostname>.txt` — per-machine overlay layered on the baseline (`hostname -s`).
  Adds (`repo`, `repo/skill`, `project:<name>`) or subtracts (`-repo`, `-repo/skill`,
  `-project:<name>`) for that host only. Absent overlay → baseline as-is. **Gitignored,
  not tracked** (#24) — seed from `machines/example.txt` on a new machine.
- `LOGS/` — dev journal (handoffs/context from the `handoff` skill). **Gitignored,
  not tracked** (#24/#39) — personal and not useful to a fork. On machines that want
  it, it's a symlink into a separate private repo; nothing in the-grid requires it
  to exist.
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
3. Seed your wiring manifest (gitignored, personal — see #24): `cp
   baseline-submodules.example.txt baseline-submodules.txt && cp
   machines/example.txt machines/"$(hostname -s)".txt`, then edit both to
   taste. Skip a file that already exists.
4. Wire skills: `bash scripts/wire.sh` — skills are live now.
5. Set up install identity — **only if `agent-factory/user.yaml` doesn't
   already exist** (once per install, not once per session): copy it from
   `agent-factory/user.yaml.example`, then **ask the human** who the
   operator is (name + contact), what channels they're reachable on, and
   any other field the template asks for — don't guess, don't leave it
   silently blank, and don't skip asking just because every field is
   technically optional. Write their answers into `agent-factory/user.yaml`.
   This is install-level config: it lands on every composed agent's
   IDENTITY nameplate (see agent-factory section below). `machine` alone
   can be left blank — it falls back to the local hostname.
6. Build the agent teams: `cd agent-factory && python3 -m venv .venv &&
   .venv/bin/pip install -r requirements.txt && .venv/bin/python compose.py
   examples/core.yaml --target claude-code && .venv/bin/python compose.py
   examples/grid.yaml --target claude-code && .venv/bin/python compose.py
   examples/finance-desk.yaml --target claude-code`. (Three public projects,
   composed independently — a private desk, if you have one, composes the
   same way with `GRID_PRIVATE_ROLES_DIR` set; see the agent-factory section
   below.)
7. Wire again from the repo root: `bash scripts/wire.sh` — agents are live now.

(Steps 2, 3, 4, 6, and 7 — everything except the optional identity config in
step 5, which needs a human to fill it in — are exactly what `scripts/bootstrap.sh
--with-agents` does in one shot.)

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

### ⚠ Pending: LOGS history rewrite + personal-manifest untracking (2026-09-11)

Part of the de-Gareth audit (#24, folded in #39). Three changes landed in one
push, and the first one rewrote history:

1. **`git filter-repo --path LOGS --invert-paths`** stripped every `LOGS/*`
   file from every commit (LOGS/ is personal dev journal, moved to a private
   repo — see the `LOGS/` entry under "Key files" above). This rewrote every
   commit hash on `main` and force-pushed. **Does not** touch the residual
   fringe-researcher-role-name mentions still sitting in `agent-factory/examples/grid.yaml`'s
   history — left alone deliberately, judged not worth a second rewrite.
2. `baseline-submodules.txt` and `machines/{forge,guide-server,scout,wilderness}.txt`
   were untracked (still present on disk, `wire.sh` unaffected) — personal
   curation, not framework. History left as-is (low sensitivity, not worth a
   rewrite) — only the *forward* tracking changed.
3. `skills/setup-gareth-skills` renamed to `setup-repo-skills` (cosmetic —
   it was never actually personal).

**If you're a session on a machine in the checklist below**: the rewrite means
your clone's history has diverged from `origin/main`. Back up or commit any
local work first, then:

```bash
git fetch origin
git reset --hard origin/main
```

**Correction (found on scout 2026-09-12): the claim above is wrong for any
machine other than wilderness.** `reset --hard` deletes a file that was
tracked in your old HEAD and is absent from `origin/main`'s tree, regardless
of `.gitignore` — untracking only leaves the working-tree file alone on the
machine that *made* that commit (its working copy already matched). On every
other machine, `baseline-submodules.txt` and `machines/<host>.txt` **will be
deleted** by the reset. Before running it, save them:

```bash
cp baseline-submodules.txt /tmp/baseline-submodules.txt.bak
cp machines/"$(hostname -s)".txt /tmp/"$(hostname -s)".txt.bak
```

If you already ran the reset and lost them, recover from reflog instead of
re-seeding from `.example`:

```bash
git show HEAD@{1}:baseline-submodules.txt > baseline-submodules.txt
git show HEAD@{1}:machines/"$(hostname -s)".txt > machines/"$(hostname -s)".txt
```

(`HEAD@{1}` is the pre-reset tip — check `git reflog` if another op happened
in between.) Also recreate the `LOGS` symlink, which the reset removes
outright since it's not a symlink in `origin/main`'s tree:

```bash
ln -s ~/.the-grid-private/LOGS LOGS
```

That requires `~/.the-grid-private` cloned and pulled first
(`git@github.com:oneafrikan/the-grid-private.git`) — it now carries `LOGS/`
as of its `f0e310e` commit.

Then confirm `bash scripts/wire.sh` still reports `setup-repo-skills`, not
`setup-gareth-skills`, and run the test suite. Delete your machine's line
below and commit that edit. **Once the checklist is empty, delete this
entire subsection** (including this sentence) and commit that too.

Machines with a the-grid clone still on the pre-rewrite history:

- [x] wilderness — done 2026-09-11 (ran the rewrite + force-push from here);
      verified zero `LOGS` paths/blobs in history, `setup-repo-skills` wired,
      38/38 tests green
- [x] scout — done 2026-09-12; reset deleted `baseline-submodules.txt` and
      `machines/scout.txt` as described in the correction above, recovered
      both from `HEAD@{1}` via reflog; recreated the `LOGS` symlink into
      `~/.the-grid-private` (pulled first — it was 2 commits behind and had
      the 2026-09-11 wilderness handoff notes); `setup-repo-skills` wired,
      38/38 tests green
- [x] forge — done 2026-09-12, hit the same data loss as scout (reset deleted
      `wired-submodules.txt`) but from further back: forge's clone was 3
      months stale, pre-dating the per-machine `machines/<host>.txt` split
      entirely, so there was no `baseline-submodules.txt`/`machines/forge.txt`
      to lose — only the legacy single-file `wired-submodules.txt`. Recovered
      its content from the pre-reset tip (`git show HEAD@{1}:wired-submodules.txt`)
      and split it into `baseline-submodules.txt` (from the new tracked
      example) + a `machines/forge.txt` overlay for the entries the shared
      baseline doesn't carry. `~/.the-grid-private` didn't exist on forge at
      all yet (never set up here before) — cloned it fresh and symlinked
      `LOGS`. `setup-repo-skills` wired, `setup-gareth-skills` gone, 38/38
      tests green.
- [x] guide-server — done 2026-09-19; diverged 157 ahead / 144 behind. Backed up
      `baseline-submodules.txt`, `machines/guide-server.txt` and the tracked
      `LOGS/` dir first (plus a local `backup/pre-rewrite-2026-09-19` branch),
      then `reset --hard origin/main`, restored both manifests, cloned
      `~/.the-grid-private` (every local LOGS file was already there) and
      symlinked `LOGS`. Recomposed core/grid/finance-desk, `setup-repo-skills`
      wired, no pre-split names remain, 38/38 tests green.

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
work. See `agent-factory/README.md`.

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
- A composed role's own bundled `SKILL.md` ("its operating procedure") can
  share a bare name with an unrelated wired ecosystem skill (e.g. the
  `security-reviewer` role's procedure vs. jeffallan's wired `security-reviewer`
  skill) — that's a naming coincidence, not a relationship, and reads as one
  in prose ("lives in its `security-reviewer` skill") unless a role's AGENTS.md
  says explicitly which one it means. Check for this collision whenever a role
  name and a wired skill name match.
- Before pointing a role at a wired skill for some capability, check whether
  another wired skill already covers the same ground — `jeffallan/debugging-wizard`
  and `superpowers/systematic-debugging` both do hypothesis-driven root-cause
  debugging, but they're not duplicates: `debugging-wizard` explicitly credits
  and incorporates `systematic-debugging`'s phase methodology as one of its own
  reference docs, adding stack-trace/log-correlation tooling and per-language
  debugger commands on top, while `systematic-debugging` is already the
  universal default everywhere via `superpowers`' `using-superpowers` skill —
  so neither needs a role-specific routing note on its own.

## About

the-grid is Gareth's brainchild — a personal, evolving system for organising and
wiring up his Claude skills. Intended to eventually be a public repo. Treat it as
an extension of how Gareth thinks and works, and keep it tidy as it grows.
