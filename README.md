# the-grid

Centralised skill management for Claude Code, inspired by Tron.

Skills are directories containing a `SKILL.md`. This repo owns some directly and pulls others in from sibling repos via git submodules. A single script (`wire.sh`) symlinks everything into `~/.claude/skills/` so Claude picks them up automatically.

```
~/.the-grid/
  standup/          ← skill owned by the-grid
    SKILL.md
  rubber-duck/
    SKILL.md
  repos/            ← sibling repos as git submodules
    gstack/         (each contains skill dirs)
    gbrain/
  tests/
    test_wiring.bats
    test_skill_format.bats
    test_repo_health.bats
    helpers/setup.bash
    lib/bats-core/  ← test runner (submodule, no install needed)
  wire.sh           ← creates ~/.claude/skills/ symlinks
  TODO.md
```

## Bootstrap (new machine)

```bash
git clone git@github.com:gkwilderness/the-grid.git ~/.the-grid
cd ~/.the-grid
git submodule update --init --recursive
bash wire.sh
```

That's it. Skills are live immediately.

## Adding a skill directly to the-grid

```bash
mkdir ~/.the-grid/my-skill
cat > ~/.the-grid/my-skill/SKILL.md <<'EOF'
---
name: my-skill
description: One-line description and trigger phrases.
---

# My Skill
...
EOF
bash ~/.the-grid/wire.sh
```

## Adding a sibling repo as a submodule

```bash
cd ~/.the-grid
git submodule add git@github.com:gkwilderness/some-skill-repo.git repos/some-skill-repo
git submodule update --init
bash wire.sh
```

Any skill directories (containing `SKILL.md`) found one level deep inside `repos/` are wired automatically.

## Running tests

```bash
cd ~/.the-grid
tests/lib/bats-core/bin/bats tests/
```

Tests cover: symlink creation, idempotency, stale cleanup, skill format validation (required frontmatter), submodule health, and broken symlink detection.

## How wire.sh works

1. Removes symlinks in `~/.claude/skills/` that point into the-grid but whose source no longer exists.
2. Creates symlinks for each skill at the root of this repo (skipping `repos/`, `tests/`, `.git`).
3. Creates symlinks for each skill found inside `repos/*/`.
4. Leaves symlinks pointing to other locations untouched.

Override paths via env vars (used by tests):

```bash
GRID_DIR=/path/to/grid SKILLS_DIR=/path/to/skills bash wire.sh
```
