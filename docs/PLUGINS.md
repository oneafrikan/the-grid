# Claude Code plugins

the-grid ships two Claude Code plugins from this repo, as a zero-clone way to
try it. **Claude Code and the Claude Desktop app (Code tab, Cowork) only** — for other harnesses, or for third-party skills,
use `grid install`. Claude Desktop (Code tab, Cowork): see
[Claude Desktop](#claude-desktop-code-tab-and-cowork).

## Install

```bash
claude plugin marketplace add oneafrikan/the-grid
claude plugin install grid-core@the-grid
claude plugin install grid-agents@the-grid
```

Install either or both. Installs follow the default branch, so there is no pin to a
release tag.

## What is in each bundle

- `grid-core` — the-grid's own skills (`gh-issues-by-severity`, `grid-help`,
  `mine-learnings`, `openspec-help`, `rubber-duck`, `spec-scout`, `standup`,
  `tighten`, `un-claudish`), `/tron`, and the five cross-desk agents
  (`core-researcher`, `core-librarian`, `core-gh-triage`, `core-platform-engineer`,
  `core-context-engineer`).
- `grid-agents` — the composed dev team: the CEO, tech-lead and growth-hacker
  orchestrators and the `gsd` fan-out (all as skills), the specialist subagents, and
  `grid-ponytail`.

The bundles hold the-grid's **own** content only. Third-party skills are not
included; `grid install` handles those, with sha-pinned locks.

## Limits of a plugin install

The bundled skills and agents are the same text the repo wires with `wire.sh`; the
builder does not adapt it. A plugin install lacks the rest of the repo, so some
references in that text point at things that are not there:

- `wire.sh` and the other `scripts/` (for example in `grid-help`).
- `/ponytail` and `/skill-scout`, which are not shipped.
- Other shipped text mentions `/ponytail-help`, `SPECS.md`, and the jeffallan skills named in the `grid-agents` text (for example `secure-code-guardian`, `prompt-engineer`); the plugins do not install them, so treat them as optional and ignore them if absent.
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

## Claude Desktop (Code tab and Cowork)

Observed 2026-11-05 on macOS unless marked. Delegation-gate results: `docs/business-tier/DELEGATION-GATE.md`.

- **Code tab** runs Claude Code on the Mac and reads `~/.claude`. A machine wired with `wire.sh` (or `grid install`) gets the full wired set of skills and subagents there, with no plugin install.
- The one-channel-per-machine rule applies to the Code tab too.
- In the Code tab (wired, no plugin installed) an Agent call with `subagent_type: grid-agents:grid-qa-engineer` failed as an invalid agent type: names are bare there, not namespaced.
- The bare name `grid-qa-engineer` ran (in the background) and listed the files of the folder connected on the Mac, so local file access works.
- Installing the plugins from inside the Code tab is documented by Anthropic but untested here.
- **Cowork does not read `~/.claude`.** It sees only Anthropic's built-in skills plus plugins installed in Cowork.
- **Install in Cowork**: in Cowork's plugin settings, add the marketplace `oneafrikan/the-grid` (public, no git credentials needed), then install `grid-core` and `grid-agents`. The exact UI path is unverified.
- Fallback that worked: ask Cowork in chat to add the marketplace and install the two plugins.
- **Verify**: in a fresh Cowork session ask what skills and sub-agents it has. The `grid-core` skills and the four `grid-agents` orchestrator skills (`gsd`, `grid-tech-lead`, `grid-ceo-orchestrator`, `grid-growth-hacker`) should be listed.
- **Third-party skills in Cowork**: the bundles carry only the-grid's own content. Add these upstream marketplaces in Cowork the same way (each ships `.claude-plugin/marketplace.json`): `anthropics/skills`, `jeffallan/claude-skills`, `mattpocock/skills`, `DietrichGebert/ponytail`, `obra/superpowers`.
- No marketplace, so not installable in Cowork this way: `garrytan/gstack`, `HubSpot/agent-cli-skills`, `Fission-AI/openspec`.

Cowork limits (observed):

- Plugin subagents are not listed among Cowork's subagent types (only its built-ins). An explicit Agent call with the namespaced name `grid-agents:grid-qa-engineer` still resolved and ran.
- That subagent's tools ran in Cowork's cloud container (as Cowork reported), which cannot see the folder connected on the Mac. The main session fell back to the linked computer.
- So orchestrators in Cowork cannot hand local-file work to specialists. Use the Code tab for repo and file work.
- Installed Cowork plugins were not found on the host under `~/Library/Application Support/Claude`. Where Cowork stores them is unknown.

## Maintaining the bundles

`plugins/` and `.claude-plugin/marketplace.json` are **generated**. Never
hand-edit them.

- Membership and version live in `plugins/bundles.json`.
- Bump the version in `plugins/bundles.json` in any PR that changes generated output. It is
  one static string, edited by hand; how a client treats an unchanged version on update is
  unverified, so a bump is the safe signal. The repo's release tags (v0.1.0 onwards) are
  separate from the bundle version, and installing from a tag is unverified: do not
  document it.
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
