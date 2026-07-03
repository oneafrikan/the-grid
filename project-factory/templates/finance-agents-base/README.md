# finance-agents-base (template)

The default, generic scaffold for a personal-finance agent **team** — watch,
build evidence, propose, veto, remember. Not tied to one finance domain
(portfolio, budget, debt, tax); the roles below are the shape that
generalizes across them. Seeded from `project-factory`. Everything here is a
**structural stub**: folders and one-line placeholder files, no business
logic, and — deliberately — no thresholds, limits, or trading logic. Those
are per-user policy, not template content; see `POLICY.template.md`.

## Shape

- `CLAUDE.md`, `CONTEXT.md`, `LEARNINGS.md`, `handoffs/`, `prompts/` — agent
  conventions and session-continuity scaffolding. The last four come from
  `_common` — see [`project-factory/README.md`](../../README.md).
- `POLICY.template.md` — the one human-authored, version-controlled document
  everything else is subordinate to: objective, limits, what this team
  doesn't do, amendment process. Copy to `POLICY.md` and fill in before
  running anything for real.
- `src/agents/` — the team:
  - `watcher/` — deterministic polling against policy thresholds; flags,
    never analyses. Should be cheap enough to run constantly.
  - `analyst/` — turns a flag into an evidence pack (both sides, argued with
    equal effort); never recommends.
  - `strategist/` — turns an evidence pack + policy into a proposal, with a
    confidence level and the strongest argument against its own proposal.
  - `guardrail/` — the veto. `rules.py` is pure code, no model, loaded from
    `POLICY.md` — a proposal that violates a hard limit dies here before any
    human sees it.
  - `scribe/` — logs every flag/brief/proposal/decision/outcome; runs
    periodic post-mortems.
  - `shared/` — execution loop, state, and memory common to all roles.
- `src/approval/` — the human approval gate. No agent in this team ever
  executes anything that moves money; `queue.py` is where a proposal waits
  for a human decision.
- `src/tools/` — illustrative stub: `data_feed.py`, a read-only data poller.
  Delete/replace with the actual data source.
- `src/models/`, `src/prompts/`, `src/utils/` — LLM client, prompt templates,
  helpers/config/logging.
- `data/`, `logs/` — runtime output (gitignored — `.gitkeep` only).
- `tests/` — unit tests for the agents and, especially, the guardrail rules.
- `main.py` — entry point: runs the watcher heartbeat / a single pipeline
  pass, depending on how this gets deployed (cron, long-running, or invoked
  per-schedule — not fixed by the template).
- `docker-compose.yml` — optional, for local services. Ships commented out.

## Non-negotiable

No agent in this team ever holds write access to anything that moves money.
Read-only data in, proposals out; only a human executes. See `CLAUDE.md`.

## Composing this project (after cutting)

1. Write `POLICY.md` first (copy `POLICY.template.md`) — everything else is
   plumbing without it.
2. Implement `guardrail/rules.py` as pure code against `POLICY.md`'s hard
   limits, with tests, before wiring up `strategist/`.
3. Once this repo has a GitHub issue backlog, instantiate
   `automation-factory`'s `issue-loop` pattern into `loop/`, and fill in
   `_common`'s `prompts/autonomous-coding-loop.template.md` with the
   `{{VERIFY_CMD}}` from this template's `CLAUDE.md`. Note: that loop is for
   an agent autonomously *maintaining this codebase* — a separate concern
   from the watcher's own runtime heartbeat (cron/scheduler, not GitHub
   issues).

## Setup

```bash
python3 -m venv venv && source venv/bin/activate
pip install -r requirements.txt
cp .env.example .env    # read-only data source config — never broker credentials
cp POLICY.template.md POLICY.md   # fill in before running anything for real
python main.py
```
