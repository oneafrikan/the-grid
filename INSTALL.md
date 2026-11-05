# Install

Short guide for a new machine. [BOOTSTRAP.md](BOOTSTRAP.md) is the full reference
(updating, precedence, troubleshooting). Using the Claude Desktop app? See
[Claude Code (terminal and the Desktop Code tab)](#claude-code-terminal-and-the-desktop-code-tab)
and [Claude Cowork (Desktop app)](#claude-cowork-desktop-app).

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

## Claude Code (terminal and the Desktop Code tab)

The terminal and the Desktop app's Code tab share `~/.claude`, so one install
covers both. Detail: [docs/PLUGINS.md](docs/PLUGINS.md#claude-desktop-code-tab-and-cowork).

Pick **one** route per machine. Doing both lists every agent twice.

**Route 1, full (clone):** follow [Install](#install) above (`bootstrap.sh`, or
`wire.sh`). Skills are live immediately.

**Route 2, no clone (plugins):**

1. Open a terminal.
2. Add the marketplace:
   ```bash
   claude plugin marketplace add oneafrikan/the-grid
   ```
3. Install the two plugins:
   ```bash
   claude plugin install grid-core@the-grid
   claude plugin install grid-agents@the-grid
   ```
4. Start a new Claude Code session so they load.

**Verify:**

1. Open the Desktop app's Code tab (or run `claude` in a terminal).
2. Ask: "what skills and sub-agents do you have".
3. You should see `grid-*` and `core-*` agents listed (Route 2 shows the `grid-agents`
   ones with a `grid-agents:` prefix).

**Code tab facts:** it delegates to subagents by bare name (for example
`grid-qa-engineer`) and sees the local folder directly. It is the route for git
repos and worktrees.

## Claude Cowork (Desktop app)

Cowork does not read `~/.claude`, so `wire.sh` does nothing for it. It gets the
grid only from plugins installed in Cowork. Detail:
[docs/PLUGINS.md](docs/PLUGINS.md#claude-desktop-code-tab-and-cowork).

1. Open the Claude Desktop app and switch to Cowork.
2. In Cowork's plugin settings, add the marketplace `oneafrikan/the-grid`. It is
   public: no git credentials are needed.
3. Install `grid-core` and `grid-agents`.
4. Fallback that worked: ask Cowork in chat to add the marketplace and install both
   plugins.

Optional third-party skills: add the upstream marketplaces listed in
[docs/PLUGINS.md](docs/PLUGINS.md#claude-desktop-code-tab-and-cowork) the same way.
`garrytan/gstack`, `HubSpot/agent-cli-skills` and `Fission-AI/openspec` have no
marketplace and cannot be installed in Cowork this way.

**Verify:**

1. Start a fresh Cowork session.
2. Ask what skills and sub-agents it has.
3. You should see the `grid-core` skills and the four orchestrator skills (`gsd`,
   `grid-tech-lead`, `grid-ceo-orchestrator`, `grid-growth-hacker`). Plugin agents are
   not listed there, but the orchestrators call them by `grid-agents:` name.

**Caveats:**

- Subagents work on copies staged into Cowork's cloud container; the results are
  written back to your folder.
- Write-back replaces the originals. Keep the folder under git or back it up first.
- Use the Code tab for git repos.

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
