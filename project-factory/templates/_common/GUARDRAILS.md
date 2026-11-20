# Guardrails

Read before editing, committing or opening a PR. One must-not per line.

Format: a line starting with a dash, an ID `G<n>`, the must-not, then `[check: human|CI|hook|none]` with an optional `: <how>` before the closing bracket. IDs are never reused or renumbered; a withdrawn guardrail keeps its ID and reads `(retired)`. Cite one as `GUARDRAILS#G1`.

Optional reason: put `(why: <reason>)` after the must-not and before the `[check: ...]`, so the line still ends with the check.

<fill: add this project's must-nots below, one per line. Only write `CI` or `hook` when that check really exists.>

<!-- - G1: Commit a secret to this repo (why: a leaked key cannot be recalled) [check: hook: <name of the hook that blocks it>] -->
