# Bootstrap Guide

How to get the-grid running on any machine — new or existing.

---

## Prerequisites

| Need | For | Check |
|---|---|---|
| `git` | everything | `git --version` |
| `python3` | `agent-factory` compose step | `python3 --version` |
| **Node >= 20.19.0** | the `openspec` CLI below | `node --version` |

---

## Install without submodules

For a machine that only needs the curated skill set, not a maintainer checkout.
`scripts/grid` fetches the commits pinned in `grid.lock` straight into
`repos/<source>/` (partial clone + sparse checkout, no submodules) and runs
`wire.sh`. Every skill is scanned by the vetting audit before it is placed.

Prerequisites: `python3` 3.8+, `git` 2.25+. On macOS both come from the Xcode
Command Line Tools (`xcode-select --install`); `/usr/bin/python3` without them
opens an installer prompt.

`scripts/grid` exists on the `next` branch only until `next` is promoted to `main`.
Until then add `--branch next` to the clone. Using your own fork? Put its URL in
place of `oneafrikan/the-grid`.

```bash
# 1. Clone without blobs (the skill repos are fetched separately by grid)
git clone --filter=blob:none --branch next https://github.com/oneafrikan/the-grid.git ~/.the-grid

# 2. Look before you place anything: prints the plan, no network access, no writes
python3 ~/.the-grid/scripts/grid install --dry-run

# 3. Install and wire
python3 ~/.the-grid/scripts/grid install
```

Day to day, all as `python3 ~/.the-grid/scripts/grid <command>`:

| Command | Does |
|---|---|
| `grid doctor` | read-only check of the manifest, the ledger, the placed directories and the links; exit 1 on any finding |
| `grid repair` | re-fetch what doctor reports missing, stale or absent, then re-wire (`--dry-run` previews; `--force` replaces an edited directory; `--prune` drops directories the lock no longer selects) |
| `grid uninstall` | prints what it would remove; `--yes` removes the placed directories, their links and the ledger |
| `grid audit --wired` | vetting scan of what `wire.sh` would link on this machine |
| `grid schedule install` | writes the weekly drift-report schedule files for this OS and prints the activation command; it never activates anything (`grid schedule remove` deletes them) |

Notes:

- Skills sit under `repos/<source>/<path>`, the same place the maintainer path
  puts them. The record of what `grid` placed is `~/.grid/installed.manifest`
  (`GRID_STATE_DIR` relocates it).
- `grid install` seeds `baseline-submodules.txt` and `machines/<host>.txt` from
  the examples (step 3 of the maintainer path). `grid` reads only untyped
  entries; typed entries (`project:`, `rules:`, `harness:`) are left to `wire.sh`.
- Composed agents (`project:` entries) are **not** part of `grid install`. They
  still need the `compose.py` venv (step 6 of the maintainer path).
- Repos that need a runtime (gstack) are skipped with a notice; use the
  maintainer path for them.
- Re-wiring on such a machine is `GRID_NO_CATALOG=1 bash ~/.the-grid/scripts/wire.sh`.
  The variable skips the `SKILLS.md` refresh, which would otherwise rewrite a
  tracked file from a partial set.
- `git submodule update --init` refuses a `repos/<source>` that `grid` populated.
  To switch to the maintainer path, run
  `python3 ~/.the-grid/scripts/grid uninstall --yes` first.
- `grid uninstall --yes` and `grid repair` also run `wire.sh` (with
  `GRID_NO_CATALOG=1`) to refresh the links and `.wired.manifest`.
- Use `grid` as a single writer: it takes no lock, so do not run two `grid`
  commands that write at the same time (a scheduled `grid drift` only reads).
- The ledger is trusted same-user state, not an authenticated record:
  `grid uninstall --force` removes any directory under `repos/<source>/` that a
  ledger row names. Keep `~/.grid` writable only by you.
- `grid` runs git without your user or system gitconfig (so a URL rewrite there
  cannot redirect what it fetches). Behind a corporate proxy or credential
  helper set `GRID_GIT_FORWARD_CONFIG=1` to forward your git environment.
  `GRID_AUDIT_TIMEOUT=<seconds>` (default 300) bounds each `audit.py` run.
- A damaged ledger is reported by `grid doctor` with its path. Restore a backup,
  or delete the file and re-run `grid install`, which adopts directories that
  still match `grid.lock`.
- `grid schedule` needs a clone path (and `HOME`, and the state dir) made only of
  `A-Z a-z 0-9 _ . / @ + -`. A path with a space is refused and nothing is written.

---

## Maintainer path: new machine (submodules, fresh Claude Code install)

```bash
# 1. Clone the-grid (your fork's URL works too)
git clone https://github.com/oneafrikan/the-grid.git ~/.the-grid

# 2. Pull all skill submodules
cd ~/.the-grid && git submodule update --init --recursive

# 3. Seed your wiring manifest — baseline-submodules.txt and machines/<host>.txt
#    are personal curation, not tracked in the repo (see #24). Skip any file
#    that already exists.
cp ~/.the-grid/baseline-submodules.example.txt ~/.the-grid/baseline-submodules.txt
cp ~/.the-grid/machines/example.txt ~/.the-grid/machines/"$(hostname -s)".txt
# then edit both to taste — or leave the baseline as-is and the overlay empty

# 4. Wire skills into Claude
bash ~/.the-grid/scripts/wire.sh

# 5. Set your identity — appears on every composed agent's IDENTITY
#    nameplate (Machine/Operator/Channels). Skip if user.yaml already exists.
cp ~/.the-grid/agent-factory/user.yaml.example ~/.the-grid/agent-factory/user.yaml
# then edit agent-factory/user.yaml

# 6. Build the composed agent teams (four public projects) and wire into Claude
cd ~/.the-grid/agent-factory
python3 -m venv .venv && .venv/bin/pip install -r requirements.txt
.venv/bin/python compose.py examples/core.yaml --target claude-code
.venv/bin/python compose.py examples/grid.yaml --target claude-code
.venv/bin/python compose.py examples/finance-desk.yaml --target claude-code
.venv/bin/python compose.py examples/learning-desk.yaml --target claude-code
cd ~/.the-grid && bash scripts/wire.sh

# 7. External CLI the wired openspec skills depend on
npm install -g @fission-ai/openspec@latest

# 8. If wire.sh printed "runtime MISSING: <repo>" (a wired repo whose skills
#    need its own setup, e.g. gstack's browse daemon), run the wrapper. It needs
#    `bun`, downloads a browser, and aborts (exit 3) if setup changed your
#    Claude settings file, so read the repo's map first: scripts/lib/runtimes.txt.
#    Dry run prints the command without running it:
bash ~/.the-grid/scripts/runtime-setup.sh gstack --dry-run
bash ~/.the-grid/scripts/runtime-setup.sh gstack
```

Skills are live after step 4. Agents (subagents + orchestrator skills) are live after step 6.

`wire.sh` also adds one generated auto-handoff SessionEnd hook to
`~/.claude/settings.json`, on by default. Put `-hook:auto-handoff` in your baseline
or machine overlay (`machines/<host>.txt`) and re-wire to switch it off; see
[hooks/README.md](hooks/README.md).
No restart needed — Claude picks up symlinks immediately (open a fresh session for new agents/skills).

**Step 3 is what decides which skills actually load.** Without it, `wire.sh`'s
legacy fallback wires every repo in `repos/` — harmless but noisy. Copying the
example baseline gives you the curated starting set from this repo's own
`baseline-submodules.txt` instead.

**Step 5 applies to every composed project, present and future** — `user.yaml`
is install-level config, not per-project. Edit it once; recompose (step 6)
after any change to pick it up.

**A Claude session running this step should ask, not fill in silently or
skip it as "just optional."** If `agent-factory/user.yaml` doesn't already
exist, ask the human who the operator is (name + contact), what channels
they're reachable on, and any other field the template asks for, then write
the answers in. This is asked once per install — check whether `user.yaml`
already exists before asking again.

**Step 7 is not optional if you want the spec workflow.** the-grid wires 12
`openspec-*` skills on every machine, and every one of them declares
`allowed-tools: Bash(openspec:*)` and pulls its real instructions from the CLI at
runtime. Without the binary they load and dead-end on the first step. Verify with
`openspec --version` — it should match `repos/openspec/package.json`.

Nothing else in the-grid needs it, so skip step 7 if you're not using specs;
the rest of the wired skills are unaffected.

### Private projects (optional)

If you compose a project whose roles live outside this repo, do it after step 6
and before the final `wire.sh`:

```bash
cd ~/.the-grid/agent-factory
GRID_PRIVATE_ROLES_DIR=~/path/to/private/roles \
  .venv/bin/python compose.py ~/path/to/private/projects/<name>.yaml --target claude-code
cd ~/.the-grid && bash scripts/wire.sh
```

Gate it with `project:<name>` in `machines/<host>.local.txt` — gitignored, so
neither the roles nor the gate enter this repo's history.

---

## Updating an existing machine (after `git pull`)

When you pull the-grid on a machine that's already set up:

```bash
cd ~/.the-grid
git pull                                    # 1. latest the-grid (source of truth)
git submodule sync --recursive              # 2. only if the pull changed .gitmodules (URLs)
git submodule update --init --recursive     #    sync submodule pointers

# 3. If ANYTHING under agent-factory/ changed (roles, compose.py, or a compose
#    config), recompose — projects/ is git-ignored, so a pull alone does NOT
#    refresh the composed agents/rosters on this machine. Recompose all four
#    public projects (cheap even if only one actually changed):
cd agent-factory
.venv/bin/python compose.py examples/core.yaml --target claude-code
.venv/bin/python compose.py examples/grid.yaml --target claude-code
.venv/bin/python compose.py examples/finance-desk.yaml --target claude-code
.venv/bin/python compose.py examples/learning-desk.yaml --target claude-code
cd ..

bash scripts/wire.sh                         # 4. re-wire skills + agents, regenerate SKILLS.md
```

**Why step 3 matters.** The composed output under `agent-factory/projects/*` is
**git-ignored** (regenerable, not tracked). The tracked artefacts are the *source*:
`compose.py`, `roles/*`, and the compose configs in `agent-factory/examples/`. So a
change to a roster or the delegation topology (who an orchestrator delegates to)
reaches this machine **only after you recompose, then wire** — `git pull` alone is
not enough. If your pull touched nothing under `agent-factory/`, skip step 3;
`wire.sh` on its own is sufficient.

> Not sure if agent-factory changed? `git diff --stat HEAD@{1} HEAD -- agent-factory/`
> after a pull shows it. When in doubt, recomposing is cheap and idempotent.

> ⚠ **Recompose private projects in the same pass.** A change under
> `agent-factory/_core/` or to `compose.py` affects *every* project, but only the
> four public configs are listed above. `compose.py` **overwrites**
> `projects/<name>/` wholesale — so recomposing the public set while a private
> project's roles are unreachable (repo not cloned, `GRID_PRIVATE_ROLES_DIR`
> unset) silently destroys that project's composed output, and the next
> `wire.sh` tears down its symlinks. This has already happened once. Before
> recomposing, check every `project:` gate in `machines/<host>.local.txt` has a
> config you can actually reach.

---

## Existing machine (already has skills in ~/.claude/skills/)

You may have skills as real directories that pre-date the-grid. First wire, then reconcile:

```bash
bash ~/.the-grid/scripts/wire.sh        # wire all grid skills (skips real-dir shadows — safe)
bash ~/.the-grid/scripts/reconcile.sh   # dry run — lists real dirs shadowing a grid skill
```

wire.sh will **skip** any real directory that shadows a grid skill — it only manages
symlinks, so nothing is clobbered. `reconcile.sh` then shows exactly which shadows remain.

To make the machine match the-grid exactly, remove those shadows and re-wire:

```bash
bash ~/.the-grid/scripts/reconcile.sh --force   # moves shadows to a dated backup dir (audit gate first, sudo only where needed) + re-wires
```

`reconcile.sh` only ever removes a path that is a **real dir** (never a symlink) and that
wire.sh itself flagged as shadowing a grid skill — so it can't delete anything custom that
the-grid doesn't already provide. It's idempotent: a clean machine reports "Nothing to reconcile".

> If a shadow is a skill you customised and want to keep, move it into `~/.the-grid/` first
> (`mv ~/.claude/skills/<name> ~/.the-grid/<name>`) so it becomes a grid-owned skill before
> reconciling.

---

## How precedence works

wire.sh wires skills in two passes:

1. **Repo skills first** (alphabetical, later wins on a name clash: anthropic, gstack, jeffallan, mattpocock, superpowers)
2. **Skills in `skills/` second** — your own skills in `~/.the-grid/skills/`, which override any same-named repo skill

So if you've modified mattpocock's `tdd` and put it in `~/.the-grid/skills/tdd/`, your version
wins. If you haven't touched it, mattpocock's version is served directly from the submodule.

---

## Adding a new skill (yours)

```bash
mkdir ~/.the-grid/skills/my-skill
cat > ~/.the-grid/skills/my-skill/SKILL.md <<'EOF'
---
name: my-skill
description: What it does and when to use it.
---

# My Skill
...
EOF
bash ~/.the-grid/scripts/wire.sh
```

---

## Overriding a repo skill

To customise e.g. mattpocock's `tdd`:

```bash
cp -r ~/.the-grid/repos/mattpocock/skills/engineering/tdd ~/.the-grid/skills/tdd
# edit ~/.the-grid/skills/tdd/SKILL.md
bash ~/.the-grid/scripts/wire.sh   # your version now takes precedence
```

---

## Adding a new skill repo

```bash
cd ~/.the-grid
git submodule add <repo-ssh-url> repos/<name>
git submodule update --init
bash scripts/wire.sh
git add .gitmodules repos/<name>
git commit -m "feat: add <name> skills submodule"
```

---

## Keeping submodules up to date

```bash
cd ~/.the-grid
git submodule update --remote   # pull latest from all upstream repos
bash scripts/wire.sh            # re-wire in case new skills were added
git add repos/
git commit -m "chore: update skill submodules"
```

---

## Running the test suite

```bash
cd ~/.the-grid
tests/lib/bats-core/bin/bats tests/
```

This is the full suite (many minutes; roughly 15 on CI), and every test should be
green. If one is not, something is misconfigured.

---

## Troubleshooting

**Symlink is broken:**
```bash
bash ~/.the-grid/scripts/wire.sh   # re-running is always safe
```

**Skill not showing up in Claude:**
- Check it has a `SKILL.md` with `name:` and `description:` fields
- Check `~/.claude/skills/<skill-name>` exists and is a symlink (not a real dir)
- Re-run `bash ~/.the-grid/scripts/wire.sh`

**Submodule directory is empty:**
```bash
cd ~/.the-grid && git submodule update --init --recursive
```

**Agents not showing up in Claude:**
- Check `~/.claude/agents/` contains `.md` symlinks pointing into `agent-factory/projects/`
- If `agent-factory/projects/` is empty, compose hasn't been run — see step 6 above
- Re-running `bash scripts/wire.sh` is always safe (idempotent)
