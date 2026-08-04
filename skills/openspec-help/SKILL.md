---
name: openspec-help
description: >
  Quick-reference card for OpenSpec in the-grid — the 12 wired skills, when to
  reach for each, the spec format, the CLI, and how the convention reaches new
  and existing projects. Use when the user asks "how do I use openspec", "what
  are the openspec commands", "which openspec skill do I want", "how do I add
  specs to this repo", or invokes /openspec-help.
---

# openspec-help

One-shot reference. Not a mode — display and stop.

[OpenSpec](https://openspec.dev) is spec-driven development: proposals get
written and **reviewed before code exists**, and the spec survives the session
that produced it. Upstream is [Fission-AI/openspec](https://github.com/Fission-AI/openspec)
(MIT), tracked at `repos/openspec`.

## The 12 skills

**Normal path — start here:**

| Skill | When |
|---|---|
| `/openspec-explore` | Thinking out loud before committing to a direction. No artefacts written. |
| `/openspec-propose` | You know what you want. Creates the change + all artefacts in one pass. |
| `/openspec-apply-change` | Proposal reviewed and accepted — implement the tasks. |
| `/openspec-verify-change` | Check the implementation actually matches the spec, before archiving. |
| `/openspec-archive-change` | Fold the delta into `openspec/specs/`, move the change to `archive/`. |

**When the normal path doesn't fit:**

| Skill | When |
|---|---|
| `/openspec-new-change` | Step-by-step artefact creation instead of `propose`'s one-shot. |
| `/openspec-continue-change` | Pick up a change someone (or a past session) left half-built. |
| `/openspec-ff-change` | Fast-forward — generate every artefact without stepping through. |
| `/openspec-update-change` | Revise an existing plan and keep its artefacts coherent. **Never edits code.** |
| `/openspec-sync-specs` | Push a delta into main specs *without* archiving the change. |
| `/openspec-bulk-archive-change` | Several parallel changes finished at once. |
| `/openspec-onboard` | Guided first cycle, narrated, on real work in your codebase. |

Related, and **not** an openspec skill: `/spec-scout` audits adoption and
reports spec↔code drift. Survey-only — it never writes specs.

## Layout

```
openspec/
  specs/<capability>/spec.md     current truth — what the system does today
  changes/<change-id>/
    proposal.md                  what & why
    design.md                    how
    tasks.md                     implementation checklist
    specs/<capability>/spec.md   the DELTA — how the spec changes
  archive/                       completed changes
```

The distinction that matters: `openspec/specs/` is present tense.
`openspec/changes/*/specs/` is a diff against it. **Never hand-edit current
truth as part of a change** — write the delta, let `archive` or `sync` fold it
in. That's the failure mode the whole convention exists to prevent.

## Spec format

Plain markdown. No custom syntax.

```markdown
## ADDED Requirements

### Requirement: Theme selection
The app SHALL let users switch between light and dark themes, defaulting to
the system preference.

#### Scenario: User toggles dark mode
- **WHEN** the user clicks the theme toggle
- **THEN** the app switches to dark mode and persists the choice
```

Headers are `ADDED`, `MODIFIED`, or `REMOVED`. Requirements use SHALL. Every
requirement needs at least one WHEN/THEN scenario — one without is untestable
and shouldn't merge.

## Adopting it in a repo

**`openspec init` is optional.** `openspec new change` creates
`openspec/{specs,changes,archive}` + `config.yaml` on its own, so the skills
work in a repo that has never been initialised. What `init` adds is
project-local `.claude/` copies of six skills plus `/opsx:*` commands —
redundant here, since the-grid already wires all 12 globally.

**Greenfield:** just `/openspec-propose`. Optionally `/openspec-onboard` first.

**Brownfield:** the code is already the truth — don't back-fill specs for all
of it. Write specs only for the capability you're about to change, as part of
the first change that touches it. `openspec/specs/` then grows to cover the
codebase incrementally, driven by real work. A big-bang spec-writing exercise
produces documentation nobody trusts and nothing verifies.

## the-grid specifics

- **All 12 wired globally** on every machine via `baseline-submodules.txt`
  (`openspec` whole-repo entry, minus `-openspec/release-openspec`, which is
  upstream's own maintainer release skill).
- **Hard CLI dependency.** Every skill declares `allowed-tools:
  Bash(openspec:*)` and pulls its real instructions from `openspec instructions`
  at runtime — the `SKILL.md` files are shells. Without the binary they
  dead-end immediately:
  ```bash
  npm install -g @fission-ai/openspec@latest    # needs Node >= 20.19.0
  ```
- **Default profile is `core`.** That controls which skills `init` scaffolds
  locally — **not** which CLI commands work. Every command works under `core`.
- **Cut projects get the convention automatically** —
  `project-factory/templates/_common/SPECS.md` lands on every seed *and* every
  retrofit, so spec-driven is the default rather than a per-project decision.
- **Composed agents check for it** — `agent-factory/_core/AGENTS_base.md` adds a
  boot-sequence check for `SPECS.md` / `openspec/`. All 28+ agents across
  `core`, `grid`, `finance-desk` (and any private desk) honour the convention in
  repos that have it, and ignore it in repos that don't.
- **Telemetry is on by default.** Opt out with `OPENSPEC_TELEMETRY=0`.

## Stores (beta, not adopted here)

A **store** is a standalone repo whose only job is planning — same `openspec/`
shape, registered per-machine by name, addressed with `--store <id>`. Solves
planning that spans several repos. the-grid has **not** adopted this; it's
tracked in issue #38 as an open decision. Don't reach for `--store` unless that
issue closes as adopt.

## Gotchas

- A proposal exists to be **rejected cheaply**. If review always rubber-stamps,
  the convention is costing you and buying nothing.
- `update-change` revises the plan and never touches code. `apply-change` is the
  one that writes code. Mixing them up produces a change whose artefacts and
  implementation disagree.
- If implementation proves the spec wrong, update the **delta**, not the code
  silently. Divergence between spec and code is the thing being prevented.
