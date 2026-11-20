# Filling the scaffold

Replace `<fill: ...>` markers with content taken from the operator's answers or from
files they pointed you at. Keep each file's existing headings, purpose line and
"what goes here / what does not" line. Dates are today's date (YYYY-MM-DD).

If a fact was not given: leave the marker, or write `<unknown: ask the operator>`.
Never fill a gap with a plausible default (a test command, a licence, a deadline, a
person's role). Quote the operator's words where you can.

- `PURPOSE.md`: problem, intended solution, outcome. Two or three sentences each, from answers 1 and 2. The outcome must be something the operator said, not something you infer.
- `CLAUDE.md`: title, "What this is" (answers 1 and 3), the test/lint/build command in "Starting work" (answer 3). Keep the read-when table; add a row for each extra file that exists (HUMANS, CALCULATIONS and so on, and the grid files when chosen, rows in grid-extras.md). Stay under 60 lines. If CLAUDE.md was SKIPPED (exists, differs), do not edit it: hand the operator the rows as a paste-ready patch.
- `RULES.md`: keep the three baseline rules. Date them (today) only once the operator has said yes to "adopt the 3 baseline rules?" in the question batch; until then leave `<fill: YYYY-MM-DD>`. Add each rule the operator stated in the four-line format (heading with date, Agents, Rule, Why). The Why is the operator's reason; if none was given, write `<unknown: ask the operator>`. Never edit the file after that: it is the operator's.
- `GUARDRAILS.md`: one `G<n>` line per stated must-not, numbered from 1. `[check: CI]` only if that CI job exists in the repo right now (look for it). `[check: hook]` only if the hook is committed in the repo (hooks `target: shared`); a machine-local hook (`target: local`) counts as `[check: human]` or `[check: none]`. Never promise a check that is planned.
- `CONVENTIONS.md`: keep the template headings and add none. Put stack, run and test commands under Testing and Common tasks; layout, naming, commit and test habits go under the matching heading, only what the operator stated or the existing code plainly shows (cite the file you read). Nothing else.
- `DOCS.md`: one row per known doc from answer 6, with a read-when. No guessed documents.
- `DECISIONS.md`: one entry per initial decision the operator stated (stack, scope), with the reason they gave. No reason given: `<unknown: ask the operator>`.
- `HUMANS.md`, `CALCULATIONS.md`, `ASSUMPTIONS.md`, `DESIGN.md`, `AGENTS.md`, `LOGS.md`, only if scaffolded: fill from the matching answers; leave the rest as markers. Formulas and numbers are copied exactly as given, never recomputed or "corrected".
- `CONTEXT.md`, if scaffolded: current state and next priority, both as the operator described them.
- `CHANGELOG.md`: leave the template; add one line "project scaffolded" only if the operator wants it.
- Grid files, if laid down: see grid-extras.md. `LEARNINGS.md`, `knowledge/`, `signals/`, `handoffs/` stay empty.
- `MAP.md` is generated: never edit it by hand.
