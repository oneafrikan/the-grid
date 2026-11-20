# The question batch

Send these as one numbered list. Say that "skip" and "unknown" are fine answers and
that pointing at an existing README or notes file replaces any of them. If the
target directory already holds a README, offer to read it first and ask only the gaps.

1. Project name and a one-line purpose.
2. The problem it solves and the outcome that shows it worked.
3. Stack, and the commands to run and test it.
4. The humans involved and their roles.
5. Constraints and hard must-nots (things an agent must never do here).
6. Where existing docs or material live (paths or URLs).
7. Does the project have formulas or numbers that must stay consistent? (If yes,
   scaffold CALCULATIONS and ASSUMPTIONS.)
8. Use the grid extras? Default yes inside the grid, meaning only that you offer them.
   They add signals, knowledge, specs, hooks and deployable agent roles; none is
   needed for the docs to work. Each state-changing step still waits for its own yes.
9. Adopt the 3 baseline rules in RULES.md (answer questions as questions; check you
   are on current files; never kill processes by pattern)?

Record each answer verbatim in your notes before filling anything. An unanswered
item is `<unknown: ask the operator>` in the file, not a guess.
