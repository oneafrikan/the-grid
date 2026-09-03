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

## New machine (fresh Claude Code install)

```bash
# 1. Clone the-grid
git clone https://github.com/<your-username>/the-grid.git ~/.the-grid

# 2. Pull all skill submodules
cd ~/.the-grid && git submodule update --init --recursive

# 3. Wire skills into Claude
bash ~/.the-grid/scripts/wire.sh

# 4. Set your identity — appears on every composed agent's IDENTITY
#    nameplate (Machine/Operator/Channels). Skip if user.yaml already exists.
cp ~/.the-grid/agent-factory/user.yaml.example ~/.the-grid/agent-factory/user.yaml
# then edit agent-factory/user.yaml

# 5. Build the composed agent teams (three public projects) and wire into Claude
cd ~/.the-grid/agent-factory
python3 -m venv .venv && .venv/bin/pip install -r requirements.txt
.venv/bin/python compose.py examples/core.yaml --target claude-code
.venv/bin/python compose.py examples/grid.yaml --target claude-code
.venv/bin/python compose.py examples/finance-desk.yaml --target claude-code
cd ~/.the-grid && bash scripts/wire.sh

# 6. External CLI the wired openspec skills depend on
npm install -g @fission-ai/openspec@latest
```

Skills are live after step 3. Agents (subagents + orchestrator skills) are live after step 5.
No restart needed — Claude picks up symlinks immediately (open a fresh session for new agents/skills).

**Step 4 applies to every composed project, present and future** — `user.yaml`
is install-level config, not per-project. Edit it once; recompose (step 5)
after any change to pick it up.

**A Claude session running this step should ask, not fill in silently or
skip it as "just optional."** If `agent-factory/user.yaml` doesn't already
exist, ask the human who the operator is (name + contact), what channels
they're reachable on, and any other field the template asks for, then write
the answers in. This is asked once per install — check whether `user.yaml`
already exists before asking again.

**Step 6 is not optional if you want the spec workflow.** the-grid wires 12
`openspec-*` skills on every machine, and every one of them declares
`allowed-tools: Bash(openspec:*)` and pulls its real instructions from the CLI at
runtime. Without the binary they load and dead-end on the first step. Verify with
`openspec --version` — it should match `repos/openspec/package.json`.

Nothing else in the-grid needs it, so skip step 6 if you're not using specs;
the other ~209 skills are unaffected.

### Private projects (optional)

If you compose a project whose roles live outside this repo, do it after step 5
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
git submodule update --init --recursive     # 2. sync submodule pointers

# 3. If ANYTHING under agent-factory/ changed (roles, compose.py, or a compose
#    config), recompose — projects/ is git-ignored, so a pull alone does NOT
#    refresh the composed agents/rosters on this machine. Recompose all three
#    public projects (cheap even if only one actually changed):
cd agent-factory
.venv/bin/python compose.py examples/core.yaml --target claude-code
.venv/bin/python compose.py examples/grid.yaml --target claude-code
.venv/bin/python compose.py examples/finance-desk.yaml --target claude-code
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
> three public configs are listed above. `compose.py` **overwrites**
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
bash ~/.the-grid/scripts/reconcile.sh --force   # removes shadows (sudo only where needed) + re-wires
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

1. **Repo skills first** (mattpocock, superpowers, gstack, jeffallan, anthropic)
2. **Root-level skills second** — your skills in `~/.the-grid/` directly, which override any same-named repo skill

So if you've modified mattpocock's `tdd` and put it in `~/.the-grid/tdd/`, your version
wins. If you haven't touched it, mattpocock's version is served directly from the submodule.

---

## Adding a new skill (yours)

```bash
mkdir ~/.the-grid/my-skill
cat > ~/.the-grid/my-skill/SKILL.md <<'EOF'
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

To customise e.g. mattpocock's `caveman`:

```bash
cp -r ~/.the-grid/repos/mattpocock/skills/productivity/caveman ~/.the-grid/caveman
# edit ~/.the-grid/caveman/SKILL.md
bash ~/.the-grid/scripts/wire.sh   # your version now takes precedence
```

---

## Adding a new skill repo

```bash
cd ~/.the-grid
git submodule add <repo-ssh-url> repos/<name>
git submodule update --init
bash wire.sh
git add .gitmodules repos/<name>
git commit -m "feat: add <name> skills submodule"
```

---

## Keeping submodules up to date

```bash
cd ~/.the-grid
git submodule update --remote   # pull latest from all upstream repos
bash wire.sh                    # re-wire in case new skills were added
git add repos/
git commit -m "chore: update skill submodules"
```

---

## Running the test suite

```bash
cd ~/.the-grid
tests/lib/bats-core/bin/bats tests/
```

All 36 tests should be green. If they're not, something is misconfigured.

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
- If `agent-factory/projects/` is empty, compose hasn't been run — see step 5 above
- Re-running `bash scripts/wire.sh` is always safe (idempotent)
