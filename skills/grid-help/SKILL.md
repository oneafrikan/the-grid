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
  - **Specialist** (the other 24 roles) → not a slash command. Delegate
    explicitly ("use the grid-backend-dev subagent to…") or let an
    orchestrator hand off once invoked.
  - Three public projects, independently gated (`project:<name>`): `grid`
    (dev team), `finance-desk` (standalone finance pipeline), `core`
    (`gh-triage` + `librarian` — cross-desk infra, meant to stay wired
    everywhere). A private desk can exist too, composed the same way.
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

If the question is deeper than a pointer — which template to pick, how a
pattern composes, how the delegation topology works — read the relevant
section of [USAGE.md](../../USAGE.md), [README.md](../../README.md), or
[CLAUDE.md](../../CLAUDE.md) rather than guessing.
