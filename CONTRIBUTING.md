# Contributing

## How the author works

- Issues only. Discussions are off: there is no capacity to moderate a second channel.
- Branch from `main` and land on `main`.
- Run `bash scripts/gate.sh` before a change is considered ready. It is the full
  commit gate (shellcheck, catalog, role lint, composed output, tests) and takes a
  long time; run it once, not per edit.
- Non-trivial changes are spec-driven; see "Spec-driven development (OpenSpec)" below.

## Rules

- Every new asset type or pack names its use case.
- No sponsored content.
- No personal data (names, emails, hostnames, home paths, tokens).
- Never add a paid product or a dependency on one.

## Spec-driven development (OpenSpec)

Non-trivial changes start as a spec. The convention and agent instructions are in
`project-factory/templates/_common/SPECS.md`.
OpenSpec is wired on every machine; the CLI install note is in [INSTALL.md](INSTALL.md).

the-grid wires [OpenSpec](https://openspec.dev) ([Fission-AI/openspec](https://github.com/Fission-AI/openspec), MIT)
on every machine: 12 `openspec-*` skills covering
`explore → propose → apply → verify → archive`. Specs live in the repo as plain
markdown, so a plan survives the session that produced it.

OpenSpec already *is* the spec factory, so the-grid adds only two thin layers:

- `project-factory/templates/_common/SPECS.md` — the convention plus agent
  instructions, laid down on **every** cut project, seed or retrofit. Spec-driven
  is the default rather than a per-project decision someone has to remember.
- `agent-factory/_core/AGENTS_base.md` — a boot-sequence check for `SPECS.md` /
  `openspec/`. One edit reaches every composed agent. Conditional: repos without
  those markers are untouched.

`/openspec-help` is the reference card; `/spec-scout` audits adoption and
reports spec↔code drift.

The skills shell out to a CLI that is not vendored; see
[INSTALL.md](INSTALL.md#the-openspec--skills-need-a-cli) for the
`npm install` note.

## Checking grid health

```bash
bash scripts/check-grid.sh
```

Runs the full bats suite (one-line PASS/FAIL — full output only on failure; it takes
many minutes; the CI `gate` job that includes it ran 18 to 30 minutes in recent Actions runs) and scans for broken grid-owned symlinks. Exits
non-zero if anything's wrong, so it works as a CI / pre-push gate. A `pre-commit`
hook (in `.githooks/`, activated by `bootstrap.sh`) runs `scripts/gate.sh` before
every commit; bypass with
`git commit --no-verify` or `GRID_SKIP_HOOK=1`.

Link rot is checked separately — upstream repos get renamed, deleted, or made
private with no local symptom until a fresh machine tries to clone:

```bash
bash scripts/sources.sh --check    # HEADs every submodule URL, non-zero on failure
```

> **Already set up, just pulled new changes?** See BOOTSTRAP.md →
> *Updating an existing machine*. Key gotcha: `agent-factory/projects/*` is
> git-ignored, so changes to composed agents/rosters need a **recompose** then
> re-wire — `git pull` alone won't refresh them.

## Adding a skill directly to the-grid

Skills owned by the-grid (original work or deliberate forks) live in `skills/`.

```bash
mkdir ~/.the-grid/skills/my-skill
cat > ~/.the-grid/skills/my-skill/SKILL.md <<'EOF'
---
name: my-skill
description: One-line description and trigger phrases.
---

# My Skill
...
EOF
bash ~/.the-grid/scripts/wire.sh
```

Root-level skills win over any same-named skill in a submodule — that's the escape hatch for an edited fork. Don't copy an upstream skill here just to use it; add the repo as a submodule and wire it instead.

## Adding a sibling repo as a submodule

```bash
cd ~/.the-grid
git submodule add <repo-url> repos/some-skill-repo
git submodule update --init
bash scripts/wire.sh
```

A newly added submodule is **library-only** by default (indexed in `SKILLS.md`, not symlinked). To wire its skills live on every machine, add its name to `baseline-submodules.txt` (or to a single machine's `machines/<host>.txt` overlay) and re-run `bash scripts/wire.sh`.

## Running tests

```bash
tests/lib/bats-core/bin/bats tests/
```

Tests cover: symlink creation, idempotency, stale cleanup, skill format validation (required frontmatter), submodule health, broken symlink detection, the role contract and its lint, per-project agent deploys, the run record, and the golden-case runner (against a stub, never a real model). All tests use temp dirs and never touch the real `~/.claude/skills/`. `bash scripts/gate.sh` runs the full commit gate.
