# Business tier — the-grid for people who don't use a terminal

**Status:** design agreed, nothing built. Last updated 2026-10-18.
**Tracking issue:** #274. **Related:** #241 (Portal), #159-#162 (plugin marketplace, already built on `next`), #55 (uplift).

## One-line goal

A colleague on a Mac types one sentence into Claude Desktop and the right
the-grid agents and skills become callable from Cowork, with the business's own
context applied. No terminal, no Python, no clone.

## The one question everything hangs on

**Does a Claude Desktop surface (Cowork, Code tab) delegate from an orchestrator
to plugin-supplied subagents?** If yes, the plugin route works as designed. If
not, the design degrades (see [DELEGATION-GATE.md](DELEGATION-GATE.md)).
Nothing past the probe plugin should be built until this is answered on a Mac.

## Reading order

1. [SPEC.md](SPEC.md) — journey, repo architecture, Claude flow, what the user gets
2. [DELEGATION-GATE.md](DELEGATION-GATE.md) — the open question, the probe plugin, the Mac checklist, the decision tree
3. [DECISIONS.md](DECISIONS.md) — decisions log (ADRs), including what was reversed and why
4. [RESEARCH.md](RESEARCH.md) — evidence from the 2026-10-17 research pass, with sources and confidence

## Picking this up in a new session

- Read this file, then `DELEGATION-GATE.md` results table. If it is still empty, the pilot has not been run.
- `main` is far behind `next` (hundreds of commits at time of writing). Work and PRs go to `next`.
- The public grid already ships two plugins (`grid-core`, `grid-agents`) built by
  `scripts/build-plugins.py` from `plugins/bundles.json`; see `docs/PLUGINS.md`.
  The business tier is a second consumer of that builder. Not yet read in detail.
- Keep this directory business-neutral: the repo is public. Use `<business>` or `acme`.

## Open questions

| # | Question | Blocks | Where |
|---|----------|--------|-------|
| OQ-1 | Does Cowork delegate to plugin subagents? Does the Code tab? | everything | DELEGATION-GATE |
| OQ-2 | How does business context reach the grid's agents (read-first skill vs build-time injection)? | bundle design | SPEC |
| OQ-3 | Can a non-technical Mac add a private GitHub marketplace (git credentials)? | onboarding | DELEGATION-GATE |
| OQ-4 | Do marketplace updates reach colleagues without action? | maintenance | DELEGATION-GATE |
| OQ-5 | Do orchestrators that name agents bare (`grid-qa-engineer`) resolve against namespaced plugin agents (`grid-agents:grid-qa-engineer`)? | orchestration | DELEGATION-GATE |
| OQ-6 | Evaluate Orca as the model for a non-technical ADE (ADR-005). Not yet looked at. | long-term | DECISIONS |

## Next actions

1. Operator runs the probe plugin on a Mac (DELEGATION-GATE, Phase 1) and fills in the results table.
2. Branch on the result (decision tree in DELEGATION-GATE).
3. Only then: build `research-brief` (Phase 2), then the business-repo template and builder changes.
