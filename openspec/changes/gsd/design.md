## Context

- Facts read from `main` on 2026-10-21; re-verify before editing (tasks group 1).
- Orchestrators compile to Claude Code skills; `AGENTS.md` cap for an orchestrator is 5120 B (`docs/role-authoring.md`, Variants) with sections `Scope`, `What to get right hardest`, `Hard rules`, plus `Roster` (rendered from `delegates_to` at `{{ROSTER_TABLE}}`), `Delegation & Context` and `Routing`.
- A `delegates_to` entry must be a role on the same team or compose fails; `grid-ponytail` is root-owned (`agents/` at repo root) so it can only be named in prose.
- `bare: true` on an agent entry in the compose config gives `/<role>` instead of `/grid-<role>`; bare names must be unique across wired projects (`tron` does this in `core`).
- Shared rule 15 (already live) routes small changes to one specialist with no process and fan-out to `gsd`.
- Worktree hygiene (`CLAUDE.md`): agents must remove the worktrees and branches they create once merged.

## Decisions

- Decided: name `gsd`, project `grid`, `orchestrator: true`, `bare: true` (so `/gsd`), `default_model: sonnet`. Before composing, `ls ~/.claude/skills ~/.claude/agents | grep -i gsd` must show no existing `gsd`; if one exists, stop and report.
- Decided: standalone orchestrator. Not in `ceo-orchestrator`'s `delegates_to`; `tech-lead`'s files are not touched.
- Decided: `delegates_to` = backend-dev, frontend-dev, fullstack-engineer, devops, data-engineer, sdet, qa-engineer, technical-writer.
- Decided: flow. (1) Read the request and split it into independent fixes. (2) One fix: hand it to ONE specialist and report; no fan-out; `gsd` never does the work itself. (3) Two or more independent fixes: one specialist per fix in parallel, each on its own branch or worktree (Agent tool with worktree isolation), each with a self-contained brief (goal, files, constraint, success check). (4) Merge the branches into the working branch; a conflict beyond trivial goes back to a specialist. (5) `qa-engineer` verifies independently after the merge: runs the repo's own checks and confirms each stated fix. QA always runs, even for one fix. (6) Report what changed, what QA showed, and which worktrees and branches were removed.
- Decided: the wording avoids "one-line change". The rule is by count of independent fixes, not by size.
- Decided: out of scope and said so in `AGENTS.md`: PRDs, ADRs, task tracking, security review, CI/release gate. These wait for feature releases and `tech-lead`.
- Decided: escalate to `tech-lead` (say so to the operator, do not start the work) when a fix needs a new dependency, a schema change, auth or secrets, something irreversible, or turns out to need design.
- Decided: hard rules: never writes code itself; QA is never the builder's own check (name the checker, label a self-check); quote failing output verbatim; push nothing beyond the working branch unless told; remove the worktrees and branches it created once merged and report them; follow the shared four from `docs/role-authoring.md` as reworded for orchestrators ("verify before accepting").
- Decided: `grid-ponytail` is named in `Routing` as the specialist for the smallest-diff case, with "if not available, use the specialist for the stack".
- Decided: counts are derived at build time: grid gains one orchestrator (so 4 orchestrators + 21 specialists = 25), public role total +1, orchestrator count +1. Do not copy numbers from this file.
- Decided: raise the budget ratchet with `budget.py --update-target --allow-raise`, show before/after in the commit message, leave the raise visible for review.
- Decided: recompose only `grid`. Do not recompose other projects, including private ones.
- Decided: work lands directly on `main` (no PR), as the operator prefers; full `bash scripts/gate.sh` must pass first, run twice.

## Risks

- Two orchestrators with overlapping descriptions invite "which one" confusion; the descriptions must state the split (small independent fixes vs PRD-and-gate features).
- Merging several branches can produce conflicts the role cannot resolve without writing code; the rule sends those to a specialist.
- Name collision on `/gsd` with a wired skill; checked in group 1.
