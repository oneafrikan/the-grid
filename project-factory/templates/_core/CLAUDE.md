# CLAUDE.md: <fill: project name>

Entry point for any session in this project. Keep it under 60 lines.
What goes here: what the project is, what to read when, how a session starts and ends. What does not: rules (RULES.md), conventions (CONVENTIONS.md), history (DECISIONS.md).

## What this is

<fill: one or two sentences: what the project is, who it is for, the main stack.>

## Read when

| File | Read when |
|---|---|
| `PURPOSE.md` | Session start: why the project exists |
| `RULES.md` | Session start: standing orders from the operator |
| `GUARDRAILS.md` | Before editing, committing or opening a PR |
| `CONVENTIONS.md` | Before writing code, docs or a commit |
| `DECISIONS.md` | Before changing something that looks deliberate |
| `DOCS.md` | Before guessing how a tool, spec or reference works |
| `CHANGELOG.md` | You need to know what changed recently (never read `docs/changelog-archive/`) |
| `MAP.md` | You need to find a file (generated; never hand-edit) |
| `CONTEXT.md`, `DESIGN.md`, `AGENTS.md`, `HUMANS.md`, `LOGS.md`, `CALCULATIONS.md`, `ASSUMPTIONS.md`, `LEARNINGS.md`, `MEMORY.md` | Only if the file exists; `MAP.md` says when to read each |

## Session start

1. Run `git fetch` and `git status -sb`; say so if the checkout is behind.
2. Read `PURPOSE.md`, `RULES.md` and `MAP.md`.
3. State the rules that apply to you in one sentence.
4. If the operator says they changed `RULES.md`, re-read it at once.

## Starting work

1. Restate the goal in one line; ask if it has more than one reading.
2. Read `GUARDRAILS.md` and `CONVENTIONS.md`.
3. Make the smallest change that meets the goal, then run the checks: <fill: test / lint / build command>.

## Keeping docs true

- Before a session ends, update `DECISIONS.md` (new decisions), `CHANGELOG.md` (user-visible changes), `CONTEXT.md` and `TODO.md` where they exist.
- Outdated docs are bugs: fix them in the same change as the code.
- Regenerate the map after adding or removing a doc: `python3 scripts/map.py`.
