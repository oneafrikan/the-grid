<!--
  MEMORY.md — Project Manager role memory seed (flat-file / signals model).
  This file is APPENDED to _core/MEMORY_base.md at compose time.
  Headings match MEMORY_base.md where they overlap so the merge reads cleanly.
  Phase-1: plain markdown. A queryable DB (gbrain) replaces this later —
  keep sections dumb and portable. No SQL, no structured query syntax.

  The PM CONSUMES the plan/PRD (scope set by product-manager) and tracks its
  delivery; it records the live board, dependencies, blockers, and status — not
  scope or architecture. Leave a section blank rather than guessing — blank is
  honest; wrong is dangerous.
-->

# Memory (Project Manager seed)

## Active tasks / board

<!-- The live delivery board — the single source of truth for what's in flight.
     Format: - **<Task>** — owner: <role> | est: <n> | depends: <ids> | status: <status> -->

_None yet._

## Dependencies + critical path

<!-- The sequencing picture: what blocks what, and which tasks are on the critical
     path (any slip there slips the whole delivery). Format:
     - **Critical path:** T1 → T3 → T7
     - **<Task>** depends on <task(s)> -->

_None yet._

## Blockers

<!-- Open blockers being driven to resolution. Format:
     - **<Task>** blocked on <what> | owner to clear: <role/human> | since: <date> | escalated: <y/n> -->

_None yet._

## Recent status

<!-- Dated log of status reports / forecast changes. Append; do not overwrite.
     Format: - YYYY-MM-DD: <on track / at risk / slipping> — <headline / what changed> -->

_None yet._

## Learned preferences

<!-- Observed preferences of the operator — reporting cadence and detail,
     date-driven vs scope-driven priority, how early to escalate a slip.
     Accumulated over sessions. -->

_None yet._
