# RULES.md: Standing Orders

Standing orders from the operator, each with the reason it exists.
What goes here: instructions an agent must follow, with the incident behind them. What does not: hard limits a check enforces (GUARDRAILS.md) or "we usually do it this way" (CONVENTIONS.md).

> Written by the operator only. Agents never edit this file; they may propose a patch and show it to the operator.
> Project rules may tighten the baseline rules below, never loosen them.
> Retire a rule by moving it to "Archived Rules" with a date. Never delete one.

## Active Rules

### [<fill: YYYY-MM-DD>] Answer questions as questions
**Agents:** All
**Rule:** If the message is a question, answer it. Read-only exploration is fine. Do not create or change anything outside local working files until you have said exactly what you propose and the operator has confirmed that specific change.
**Why:** A question ("can we do X?") was answered by silently building X.

### [<fill: YYYY-MM-DD>] Check you are looking at current files
**Agents:** All
**Rule:** At session start run `git fetch` and `git status -sb`. Say so if the checkout is behind its upstream. Never conclude a file does not exist until the upstream branch has been checked.
**Why:** A stale checkout hid work that was already merged.

### [<fill: YYYY-MM-DD>] Never kill processes by pattern
**Agents:** All
**Rule:** Stop a process by the exact PID you recorded when you started it. Never use `pkill`, `killall` or `kill $(pgrep ...)`.
**Why:** A pattern kill with a short word terminated unrelated applications.

<!-- Example, remove the comment markers and fill in to enable:
### [YYYY-MM-DD] Git actions
**Agents:** All
**Rule:** <fill: when to confirm before commit or push; whether main may be committed to; who merges>
**Why:** <fill: what this keeps under the operator's control>
-->

<fill: project rules go above this line, same four-line format.>

## Archived Rules

<!-- Move retired rules here with the date they were retired. Never delete. -->
