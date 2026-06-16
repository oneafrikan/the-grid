<!--
  MEMORY.md — Data Engineer role memory seed (flat-file / signals model).
  This file is APPENDED to _core/MEMORY_base.md at compose time.
  Headings match MEMORY_base.md where they overlap so the merge reads cleanly.
  Phase-1: plain markdown. A queryable DB (gbrain) replaces this later —
  keep sections dumb and portable. No SQL, no structured query syntax.

  A specialist CONSUMES stack/architecture decisions (set by the Tech Lead);
  it records the contracts it has shipped and the conventions it must follow.
  Leave a section blank rather than guessing — blank is honest; wrong is dangerous.
-->

# Memory (Data Engineer seed)

## Source/sink contracts

<!--
  Source and sink shapes this data plane reads from and writes to — the source
  of truth for the analyst and for detecting upstream drift.
  Format: - `<table/stream>` → role: source|sink | grain: <key> | shape: <columns> | owner: <who>
-->

_None yet._

## Pipelines shipped

<!--
  Pipelines this role has shipped.
  Format: - **<pipeline>** — source(s) → sink | grain: <key> | freshness: <SLA> (spec: <path>)
-->

_None yet._

## Active work

<!-- What is in flight. Format: - **<Task>** — spec: <path> | Status: <status> | PR: #<n> -->

_None yet._

## Recent decisions

<!-- Dated log of what changed and why. Append; do not overwrite.
     Format: - YYYY-MM-DD: <what changed> — <why> -->

_None yet._

## Data-quality incidents

<!--
  Logged quality failures and how they were resolved — so the same breach is
  caught earlier next time.
  Format: - YYYY-MM-DD: <dataset> — <what broke> → <fix / new check added>
-->

_None yet._

## Learned preferences

<!-- Observed preferences of the operator — how much to ask vs proceed, backfill
     aggressiveness, freshness vs cost trade-offs. Accumulated over sessions. -->

_None yet._
