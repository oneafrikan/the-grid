- **Not sure where to start?** Run **`/tron`** — the grid's front door. It asks what
  you're trying to do, checks what is wired on this machine, and recommends the
  right skill or agent. It recommends and hands off; it never launches anything
  unasked. This skill stays the static reference.
- **Want to learn something?** `learning-desk` (if wired): **`/morpheus`**
  (Socratic tutor for any topic), **`/oracle`** (learns about you; you choose your
  own name/role/avatar), and the `tank` subagent (agent-to-agent lessons from run
  logs, proposes changes, never applies them). All manual. Learning data is private,
  kept in the private store outside this repo.
- **Want a one-off capability?** A wired skill is a slash command — e.g.
  `/standup`, `/ponytail`, `/skill-scout`. Ask "is there a skill for X?" and
  check [SKILLS.md](../../../SKILLS.md) if unsure.
- **Want a role to do work for you?**
  - **Orchestrator** (`grid-ceo-orchestrator`, `grid-tech-lead`,
    `grid-growth-hacker`, `finance-desk-finance-manager`, plus `tron`,
    `morpheus`, `oracle`) → slash command,
    e.g. `/grid-tech-lead`. Transforms the session into that role; it
    delegates further down the team.
  - **Specialist** (the other 25 roles) → not a slash command. Delegate
    explicitly ("use the grid-backend-dev subagent to…") or let an
    orchestrator hand off once invoked.
  - Four public projects, independently gated (`project:<name>`): `grid`
    (dev team), `finance-desk` (standalone finance pipeline), `core`
    (`gh-triage`, `librarian`, `researcher`, `platform-engineer`, `tron` — cross-desk
    infra, meant to stay wired everywhere), and `learning-desk` (`morpheus`,
    `oracle`, `tank`). A private desk can exist too, composed the same way.
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
  (`npm i -g @fission-ai/openspec@1.12.0`) or the skills dead-end.
- **Want to know which model to use for a job?**
  [docs/model-selection.md](../../../docs/model-selection.md) — prices, independent
  benchmarks, worked cost maths, and an explicit list of what is *not* known.
