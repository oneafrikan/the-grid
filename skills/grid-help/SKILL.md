---
name: grid-help
description: >
  Explain how to use the-grid — which slash command or subagent to reach for,
  how orchestrators vs specialists work, how the four factories differ. Use
  when user asks "how do I use the-grid", "what can I do here", "how do I add
  a skill/agent/automation", or invokes /grid-help.
---

# grid-help

A live, in-session guide to the-grid. Answer from the summary below; point to
[USAGE.md](../../USAGE.md) (repo root) for the full walkthrough rather than
reproducing it verbatim — it changes independently of this skill.

## Quick orientation

- **Want a one-off capability?** A wired skill is a slash command — e.g.
  `/standup`, `/ponytail`, `/skill-scout`. Ask "is there a skill for X?" and
  check [SKILLS.md](../../SKILLS.md) if unsure.
- **Want a role to do work for you?**
  - **Orchestrator** (`grid-ceo-orchestrator`, `grid-tech-lead`,
    `grid-growth-hacker`, `finance-desk-finance-manager`) → slash command,
    e.g. `/grid-tech-lead`. Transforms the session into that role; it
    delegates further down the team.
  - **Specialist** (the other 25 roles) → not a slash command. Delegate
    explicitly ("use the grid-backend-dev subagent to…") or let an
    orchestrator hand off once invoked.
  - Three public projects, independently gated (`project:<name>`): `grid`
    (dev team), `finance-desk` (standalone finance pipeline), `core`
    (`gh-triage`, `librarian`, `researcher`, `platform-engineer` — cross-desk
    infra, meant to stay wired everywhere). A private desk can exist too, composed the same way.
- **Want a recurring, unattended automation** (e.g. clearing a GitHub issue
  backlog)? Cut an `automation-factory/patterns/*` pattern into the target
  repo's tracked `loop/` folder — not a slash command, a one-time setup per
  target repo.
- **Want to start a brand-new project?**
  `bash project-factory/scripts/cut-project.sh <template> <target-dir>`.
- **Want to add or promote a skill?** Original work → `skills/<name>/SKILL.md`
  at the repo root. Found something useful in a library repo? Add its name to
  `baseline-submodules.txt` (every machine) or `machines/<host>.txt` (this
  machine only), then `bash scripts/wire.sh`.
- **Want to plan work so it outlives the session?** the-grid wires
  [OpenSpec](https://openspec.dev) — 12 `openspec-*` skills,
  `explore → propose → apply → verify → archive`, specs as markdown in
  `openspec/`. Point at **`/openspec-help`** rather than explaining it here.
  `/spec-scout` audits adoption + spec↔code drift. Needs the CLI
  (`npm i -g @fission-ai/openspec@latest`) or the skills dead-end.
- **Want to know which model to use for a job?**
  [docs/model-selection.md](../../docs/model-selection.md) — prices, independent
  benchmarks, worked cost maths, and an explicit list of what is *not* known.

## Sibling help skills

Don't reproduce their content — hand off:

| Command | Owns |
|---|---|
| `/openspec-help` | The 12 openspec skills, spec format, adoption paths |
| `/ponytail-help` | ponytail modes and intensity levels |

## Answering well

- **Give a pointer, not a tutorial.** One or two lines plus the file to read.
- **Check before asserting.** [SKILLS.md](../../SKILLS.md) is generated and
  current; your memory of what's wired is not. Same for which agents exist —
  read `~/.claude/agents/`.
- **Private projects: mechanism yes, names never.** A machine may run a project
  composed from roles outside this repo (`GRID_PRIVATE_ROLES_DIR`, gated in
  gitignored `machines/<host>.local.txt`). Explain how that works to anyone who
  asks; never enumerate the roles of a private desk in this repo or in a shared
  session.

If the question is deeper than a pointer — which template to pick, how a
pattern composes, how the delegation topology works — read the relevant
section of [USAGE.md](../../USAGE.md), [README.md](../../README.md), or
[CLAUDE.md](../../CLAUDE.md) rather than guessing.
