# Business tier — the-grid for people who don't use a terminal

**Status:** v0 built (ADR-009). Last updated 2026-11-05.
**Tracking issue:** #274. **Related:** #241 (Portal), #159-#162 (plugin marketplace, already built on `main`), #55 (uplift).

## One-line goal

A colleague on a Mac types one sentence into Claude Desktop and the right
the-grid agents and skills become callable from Cowork, with the business's own
context applied. No terminal, no Python, no clone.

## The one question everything hangs on

**Does a Claude Desktop surface (Cowork, Code tab) delegate from an orchestrator
to plugin-supplied subagents?** If yes, the plugin route works as designed. If
not, the design degrades (see [DELEGATION-GATE.md](DELEGATION-GATE.md)).
**Answered 2026-11-05 (ADR-008):** Cowork delegates to plugin subagents by namespaced
name; its subagents work on copies the main session stages into the cloud container and
writes back. The Code tab delegates and sees local files directly. The business tier ships single-thread skills only;
Cowork carries the full grid plugins.

## Install, by user type

| User | Route |
|---|---|
| Git user | `claude plugin marketplace add <org>/the-grid-<business>`, then install the plugin |
| Cowork user with access to the business repo | Customize → Plugins → add the business repo as a marketplace → install the plugin → fresh Cowork session |
| Colleague without access to the business repo | download one skill's zip, upload it under Customize → Skills → Upload skill (not Customize → Plugins, which rejects a skill zip) |

Pick one route per surface: a plugin plus a zip of the same skill lists that skill twice.
The public grid's own routes are in [install-desktop.md](../install-desktop.md).

## Reading order

1. [SPEC.md](SPEC.md) — journey, repo architecture, Claude flow, what the user gets
2. [DELEGATION-GATE.md](DELEGATION-GATE.md) — the open question, the probe plugin, the Mac checklist, the decision tree
3. [DECISIONS.md](DECISIONS.md) — decisions log (ADRs), including what was reversed and why
4. [RESEARCH.md](RESEARCH.md) — evidence from the 2026-10-17 research pass, with sources and confidence

## Picking this up in a new session

- Read this file, then `DELEGATION-GATE.md` results table. If it is still empty, the pilot has not been run.
- Work and PRs go to `main`.
- The public grid already ships two plugins (`grid-core`, `grid-agents`) built by
  `scripts/build-plugins.py` from `plugins/bundles.json`; see `docs/PLUGINS.md`.
  The v0 business repo does not use that builder (ADR-009); a builder-based business build is deferred.
- Keep this directory business-neutral: the repo is public. Use `<business>` or `acme`.

## Open questions

| # | Question | Blocks | Where |
|---|----------|--------|-------|
| OQ-1 | Does Cowork delegate to plugin subagents? Does the Code tab? | everything | **Answered** (ADR-008): both delegate; Cowork subagents work on files the main session stages in and writes back |
| OQ-2 | How does business context reach the grid's agents (read-first skill vs build-time injection)? | bundle design | **Deferred** (ADR-009): v0 ships self-contained skills with no grid roles. SPEC |
| OQ-3 | Can a non-technical Mac add a private GitHub marketplace (git credentials)? | onboarding | **Answered for accounts with org access** (2026-11-05): a private org repo added as a marketplace in the Desktop app needed no extra credentials, and the skill's assets arrived intact. Untested: the zip upload by a colleague without repo access, and whether the skill uses its bundled assets when building in Cowork. DELEGATION-GATE |
| OQ-4 | Do marketplace updates reach colleagues without action? | maintenance | **Open, untested.** Marketplace route: unknown. Zip route: no propagation by design, a colleague re-downloads and re-uploads. DELEGATION-GATE |
| OQ-5 | Do orchestrators that name agents bare (`grid-qa-engineer`) resolve against namespaced plugin agents (`grid-agents:grid-qa-engineer`)? | orchestration | **Answered for Cowork** (ADR-008): namespaced resolve; the orchestrator mapped bare roster names itself; a bare name passed directly to a plugin agent is untested. DELEGATION-GATE |
| OQ-6 | Evaluate Orca as the model for a non-technical ADE (ADR-005). Not yet looked at. | long-term | DECISIONS |

## Next actions

1. Arrange per-team read access to the business repo with the org admin.
2. Confirm that the Claude > Customize > Skills upload accepts a skill zip with assets (fallback: unzip, upload the skill, add the assets in chat).
3. Add skills as needed.
