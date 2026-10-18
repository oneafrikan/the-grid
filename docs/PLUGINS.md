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

Install either or both. Installs follow the default branch; no release tags exist yet,
so there is no pin. The bundles are built on `next` and reach the default branch (`main`)
only when `next` is promoted to `main`, so until then this install has nothing to fetch
from `main`.

## What is in each bundle

- `grid-core` — the-grid's own skills (`gh-issues-by-severity`, `grid-help`,
  `mine-learnings`, `openspec-help`, `rubber-duck`, `spec-scout`, `standup`,
  `tighten`, `un-claudish`), `/tron`, and the four cross-desk agents
  (`core-researcher`, `core-librarian`, `core-gh-triage`, `core-platform-engineer`).
- `grid-agents` — the composed dev team: the CEO, tech-lead and growth-hacker
  orchestrators (as skills), the specialist subagents, and `grid-ponytail`.

The bundles hold the-grid's **own** content only. Third-party skills are not
included; `grid install` handles those, with sha-pinned locks.

## Limits of a plugin install

The bundled skills and agents are the same text the repo wires with `wire.sh`; the
builder does not adapt it. A plugin install lacks the rest of the repo, so some
references in that text point at things that are not there:

- `wire.sh` and the other `scripts/` (for example in `grid-help`).
- `/ponytail` and `/skill-scout`, which are not shipped.
- `docs/model-selection.md` and other repo docs.
- `repos/openspec`, the wired `security-reviewer` skill and the jeffallan skills.
- `/tron` reads `~/.claude` to see what is wired; on a plugin-only machine that is empty.
- Orchestrator rosters name agents by bare name (`grid-qa-engineer`); installed agents
  carry the `grid-agents:` namespace. Whether the bare name resolves is unverified.

Each bundle carries `LICENSE` and `THIRD-PARTY-NOTICES.md` (copies of the repo root's).
Not every root skill is shipped: `exclude_skills` in `plugins/bundles.json` records each
one left out and why, and the builder refuses a skill that is in neither list.

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
- Bump the version in `plugins/bundles.json` in any PR that changes generated output. It is
  one static string, edited by hand; how a client treats an unchanged version on update is
  unverified, so a bump is the safe signal. No tags are cut yet; do not document a tag
  install until one exists.
- Regenerate with `python3 scripts/build-plugins.py` (needs `agent-factory/.venv`).
- `python3 scripts/build-plugins.py --check` reports drift and writes nothing.
- Only git-tracked files under `skills/` and `agents/` are bundled (`git add` a new file
  first; untracked files are skipped), and a symlinked `skills/`, `agents/` or
  `agent-factory/` is refused.
- Bundles are built with the neutral identity in `agent-factory/user.public.yaml`
  and no private roles, so they carry no operator, channel or hostname.
- The gate runs `--check` (`plugins`) and `claude plugin validate --strict`
  (`plugins-validate`), and the `audit` check scans `plugins/` as owned content.
  Each check is skipped with a notice where its tool is absent.
