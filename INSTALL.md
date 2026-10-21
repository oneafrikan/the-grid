# Install

Short guide for a new machine. [BOOTSTRAP.md](BOOTSTRAP.md) is the full reference
(updating, precedence, troubleshooting).

## Prerequisites

- `git`, `bash` and Claude Code.
- `python3`, only for the agent teams (`--with-agents`), plus its `venv` module.
  On Debian/Ubuntu: `sudo apt install python3-venv`, because
  `bootstrap.sh --with-agents` runs `python3 -m venv`.
- Node >= 20.19, only for the `openspec-*` skills (see below).

## Install

Fork first if you plan to customise: the clone URL below is read-only for you.

One command, clone then `bootstrap.sh` (syncs submodules, wires skills):

```bash
git clone https://github.com/oneafrikan/the-grid.git ~/.the-grid \
  && bash ~/.the-grid/scripts/bootstrap.sh
```

Add `--with-agents` to also compose **and** wire the agent team in the same run:

```bash
bash ~/.the-grid/scripts/bootstrap.sh --with-agents
```

Prefer the manual steps? They're equivalent:

```bash
cd ~/.the-grid
git submodule update --init --recursive
bash scripts/wire.sh
```

Skills are live immediately. For the full sequence (including the agent-factory
compose step) see [BOOTSTRAP.md](BOOTSTRAP.md). For a machine that needs only the
curated skills, with no submodules, see its
[Install without submodules](BOOTSTRAP.md#install-without-submodules) section
(`grid install`).

## The `openspec-*` skills need a CLI

These skills shell out to a CLI that is *not* vendored; without it they dead-end:

```bash
npm install -g @fission-ai/openspec@latest   # needs Node >= 20.19.0
```

`openspec init` is optional: `openspec new change` bootstraps `openspec/` on its own.

## What it touches

Read `scripts/wire.sh` and `scripts/bootstrap.sh` before running them. Between
them they write:

- **`~/.claude/skills/`**: symlinks into this repo, one per wired skill.
- **`~/.claude/agents/`**: symlinks to the composed specialist subagents.
- **`~/.claude/settings.json`**: one generated auto-handoff SessionEnd hook entry,
  on by default. Your own hooks and keys are left alone; the first write
  reformats the file as 2-space-indented JSON. Opt out with `-hook:auto-handoff` in
  `baseline-submodules.txt` or `machines/<host>.txt`, then re-run `wire.sh`
  ([hooks/README.md](hooks/README.md)).
- **`~/.claude/rules/grid/`**: symlinks to coding-convention rule packs. Opt-in:
  nothing is written without a `rules:<pack>` entry ([docs/rules.md](docs/rules.md)).
- **Other harness directories** (such as `~/.agents/skills`): opt-in via
  `harness:<name>` entries, never replacing an entry that is already there
  ([docs/harnesses.md](docs/harnesses.md)).
- **Inside the clone**: `.wired.manifest`, `SKILLS.md`, and `baseline-submodules.txt`
  plus `machines/<host>.txt` (seeded from the examples when absent). `bootstrap.sh`
  also sets `core.hooksPath` to `.githooks` and, with `--with-agents`, builds
  `agent-factory/.venv` and `agent-factory/projects/`.

It never overwrites a real directory or a foreign symlink in those folders; it
only replaces symlinks that point into this repo. Neither script writes `~/.grid/`
(only `grid install` does).

## Reconciling a machine (removing stale shadows)

`wire.sh` won't clobber a real directory that shadows a grid skill (safety). On a fresh machine those shadows are often stale copies. `reconcile.sh` moves them aside so the-grid owns the slot, then re-wires.

```bash
bash scripts/reconcile.sh           # dry run — list shadowing dirs
bash scripts/reconcile.sh --force   # move them to a dated backup dir (audit gate first, sudo only where needed) + re-wire
```

Idempotent: a fully-wired machine reports "Nothing to reconcile".
