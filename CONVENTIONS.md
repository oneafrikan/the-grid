# CONVENTIONS.md: How We Do Things Here

Test: if the operator orders it and gives a reason, it is a rule (RULES.md); if something checks it and a breach is a hard stop, it is a guardrail (GUARDRAILS.md); if it is "we usually do it this way", it goes here.
What goes here: habits a newcomer should copy. What does not: orders, hard limits, one-off decisions (DECISIONS.md).

## Naming

<fill: files, directories, functions, branches, commit scopes.>

## Style

<fill: formatter and linter, comment habits, line length, anything not covered by tooling.>

## Git

<fill: branch model, commit message shape, how small a commit is, how a change gets reviewed.>

## Testing

<fill: where tests live, the command to run them, what must be tested before a change is done.>

<!-- moved from CLAUDE.md B080-5eaa..B082-ca85 -->
## Drift checks, the commit gate, and per-project agents

- `scripts/gate.sh` — the gate. A plain run is the heavy local gate (every drift check plus bats);
  `.githooks/pre-commit` runs only `gate.sh --pre-commit`, a FAST check of staged files (shellcheck on
  staged `.sh`/`.bash`, python syntax on staged `.py`, bats for staged `tests/*.bats` only; it aborts
  only if a staged `.bats` file also has unstaged edits). The script self-installs `core.hooksPath`
  on first run. Run `bash scripts/gate.sh` before readying code, script or test changes; markdown, text and config-only edits run just the one relevant `--check` (see `BEHAVIOUR.md`). `GRID_SKIP_HOOK=1` / `--no-verify` bypass it. Merges/rebases skip it.
  `--strict` fails on any skip not named in `GRID_GATE_EXPECT_SKIPPED`; `--lint` runs the shellcheck stage alone.
  CI (`.github/workflows/tests.yml`) is deliberately minimal. The one required job, `gate` (pull requests that are not drafts, and pushes to `main`), runs `check-personal.sh` and `gate.sh --strict --lint`: no submodules, no venv.
  The `bats` job (four shards, `gate.sh --strict --shard <name>`, files listed in `tests/shards.txt`) runs only nightly, on `v*` tags, on published releases and on demand; it is not part of `gate` and never runs per PR or per push to `main`.
  Drift checks (catalog, sources, map, counts, lock, budget, rules, plugins, compose) are not in CI: run their `--check` commands or a local full `bash scripts/gate.sh`. A new `tests/test_*.bats` file
  must be added to `tests/shards.txt`; `tests/test_gate.bats` fails otherwise.
  `catalog`, `sources` (`sources.sh --check-drift`) and `budget` run against the TRACKED `baseline-submodules.example.txt` BY DEFAULT (`catalog.sh`, `sources.sh` and `budget.py` use it when `GRID_BASELINE` is unset and print one stderr line if a personal baseline is being ignored; `wire.sh` and the gate still pass it explicitly), so SKILLS.md, docs/SOURCES.md and the ratchet are machine-independent; a personal baseline is never gated. To measure the personal set, set `GRID_BASELINE=baseline-submodules.txt` (for example `budget.py --report`); `wire.sh` and `scripts/grid` keep wiring from the personal baseline.
  It runs `check-personal.sh` as the `personal` check; with no private denylist on the
  machine (CI, forks) it passes and prints `gate: PASS (skipped: personal-denylist)`.
  It runs `audit.sh --gate --quiet` as the `audit` check (owned assets + the baseline's
  wired set; skipped loudly if `python3` or `scripts/audit.sh` is absent). If a baseline
  submodule is uninitialised, `audit.sh --gate` exits 2 ("wired set NOT scanned") unless
  `--allow-partial` is given; `gate.sh` passes it only when `CI` is unset and then lists
  `audit-wired` as skipped, so CI stays strict.
- Read-only drift detectors (exit 1 on drift, write nothing): `catalog.sh --check`,
  `wire.sh --check`, `agent-factory/compose.py <cfg> --target claude-code --check`,
  `compose.py --lint-roles` (every role; stable `E_*` codes; `roles/_retired/` is an
  archive that is never linted/composed/deployed).

<!-- moved from CLAUDE.md B103-1125..B105-c285 -->
## Running tests

```bash
tests/lib/bats-core/bin/bats tests/
```

Write portable shell and tests: read `docs/portability.md` first (helpers `file_mode`, `sed_i`, `mktemp_canon`; avoid `coproc`, `grep -P`, `stat -c`, bare `mktemp`). All tests must stay green (run `bash scripts/gate.sh` for the full commit gate: shellcheck, `catalog.sh --check`, role lint (`compose.py --lint-roles`), `compose.py --check` per composed project (local only: composed output is gitignored, so CI runs the lint and lists the uncomposed projects as `compose-<name>` skips), `check-personal.sh`, bats). Tests use temp dirs — they never touch the real `~/.claude/skills/` or `~/.claude/agents/`. Venv-gated tests (`agent-factory/.venv` with PyYAML) skip on a plain `bats` run, but FAIL when `GRID_REQUIRE_VENV=1` or `CI=true` (the gate sets the former). In a `@test`, write `! cmd || false` and one `[ ]` per line: a bare mid-test `! cmd` or `[ A ] && [ B ]` can never fail (`test_repo_health.bats` lints this).

## Docs

<fill: which docs a change must touch, where new docs go, how they are kept short.>

## Common tasks

<fill: the commands for the tasks done most often, one line each, e.g. run locally, add a dependency, cut a release.>

<!-- moved from CLAUDE.md B064-96fb..B077-316d -->
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
   examples/finance-desk.yaml --target claude-code && .venv/bin/python compose.py
   examples/learning-desk.yaml --target claude-code`. (Four public projects,
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

Step 3 (recompose agents safely) is in `CLAUDE.md`, under "Recompose agents safely".

<!-- moved from CLAUDE.md B079-bb4b -->
4. Refresh skills (and agents, and `SKILLS.md`) in one go: `bash scripts/wire.sh`.
   Always safe to run, always run it last.

<!-- moved from CLAUDE.md B090-d6f5..B102-6cc7 -->
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
git config -f .gitmodules submodule.repos/<name>.shallow true
git submodule update --init
bash scripts/wire.sh
```

A newly added submodule is **library by default** (indexed, not wired). To wire its
skills live everywhere, add its `repos/<name>` dir name to `baseline-submodules.txt`
(or to a single machine's `machines/<host>.txt` overlay) and re-run
`bash scripts/wire.sh`. This keeps `~/.claude/skills/` small even as the-grid indexes
thousands of ecosystem skills.

**Submodules are shallow.** `bootstrap.sh` clones each not-yet-initialised submodule at
`--depth 1` (pinned commit only); `.gitmodules` carries `shallow = true` for every entry (a
bats guard enforces it). Existing full checkouts are never truncated by a normal run;
`bash scripts/bootstrap.sh --reshallow` converts them on purpose (opt-in, skips dirty or
off-pin ones, restores on failure). A maintainer on shallow submodules must run
`git -C repos/<x> fetch --unshallow origin` before `grid lock` on a repo whose pin they bump,
because the lock proves the pin is on the upstream ref and that needs history.

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
moves them aside so the-grid owns the slot, then re-wires. It learns the names from
a dry wire into a throwaway home (`GRID_DRY_HOME`), so it never hardcodes names.

```bash
bash scripts/reconcile.sh          # dry run — list shadowing dirs
bash scripts/reconcile.sh --force  # move them to a dated backup dir (audit gate first, sudo only where needed) + re-wire
```

Idempotent: a fully-wired machine reports "Nothing to reconcile".
