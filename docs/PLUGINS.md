# Claude Code plugins

the-grid ships two Claude Code plugins from this repo, as a zero-clone way to
try it. **Claude Code only** — for other harnesses, or for third-party skills,
use `grid install`.

## Install

```bash
claude plugin marketplace add oneafrikan/the-grid
claude plugin install grid-core@the-grid
claude plugin install grid-agents@the-grid
```

Install either or both. To pin a version, add the marketplace at a tag.

## What is in each bundle

- `grid-core` — the-grid's own skills (`gh-issues-by-severity`, `grid-help`,
  `mine-learnings`, `openspec-help`, `rubber-duck`, `spec-scout`, `standup`,
  `tighten`, `un-claudish`), `/tron`, and the four cross-desk agents
  (`core-researcher`, `core-librarian`, `core-gh-triage`, `core-platform-engineer`).
- `grid-agents` — the composed dev team: the CEO, tech-lead and growth-hacker
  orchestrators (as skills), the specialist subagents, and `grid-ponytail`.

The bundles hold the-grid's **own** content only. Third-party skills are not
included; `grid install` handles those, with sha-pinned locks.

## Namespacing

Plugin components are namespaced by plugin name:

- skills: `/grid-core:standup`, `/grid-agents:grid-tech-lead`
- agents: `grid-agents:grid-qa-engineer`

`skillOverrides` in settings does not apply to plugin skills.

## One channel per machine

A machine that already wired the-grid (`wire.sh`) has the agents in
`~/.claude/agents/`. Installing `grid-agents` on top lists each agent twice (the
second under the `grid-agents:` namespace). Pick one channel per machine.

## Maintaining the bundles

`plugins/` and `.claude-plugin/marketplace.json` are **generated**. Never
hand-edit them.

- Membership and version live in `plugins/bundles.json`.
- Regenerate with `python3 scripts/build-plugins.py` (needs `agent-factory/.venv`).
- `python3 scripts/build-plugins.py --check` reports drift and writes nothing.
- Bundles are built with the neutral identity in `agent-factory/user.public.yaml`
  and no private roles, so they carry no operator, channel or hostname.
- The gate runs `--check` (`plugins`) and `claude plugin validate --strict`
  (`plugins-validate`), and the `audit` check scans `plugins/` as owned content.
  Each check is skipped with a notice where its tool is absent.
