# Bootstrap Guide

How to get the-grid running on any machine — new or existing.

---

## New machine (fresh Claude Code install)

```bash
# 1. Clone the-grid
git clone https://github.com/<your-username>/the-grid.git ~/.the-grid

# 2. Pull all skill submodules
cd ~/.the-grid && git submodule update --init --recursive

# 3. Wire skills into Claude
bash ~/.the-grid/scripts/wire.sh

# 4. Build the composed agent team and wire agents into Claude
cd ~/.the-grid/agent-factory
python3 -m venv .venv && .venv/bin/pip install -r requirements.txt
.venv/bin/python compose.py examples/grid.yaml --target claude-code
cd ~/.the-grid && bash scripts/wire.sh
```

Skills are live after step 3. Agents (subagents + orchestrator skills) are live after step 4.
No restart needed — Claude picks up symlinks immediately (open a fresh session for new agents/skills).

---

## Updating an existing machine (after `git pull`)

When you pull the-grid on a machine that's already set up:

```bash
cd ~/.the-grid
git pull                                    # 1. latest the-grid (source of truth)
git submodule update --init --recursive     # 2. sync submodule pointers

# 3. If ANYTHING under agent-factory/ changed (roles, compose.py, or a compose
#    config), recompose — projects/ is git-ignored, so a pull alone does NOT
#    refresh the composed agents/rosters on this machine:
cd agent-factory
.venv/bin/python compose.py examples/grid.yaml --target claude-code
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
- If `agent-factory/projects/` is empty, compose hasn't been run — see step 4 above
- Re-running `bash scripts/wire.sh` is always safe (idempotent)
