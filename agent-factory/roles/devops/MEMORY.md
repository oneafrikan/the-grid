<!--
  MEMORY.md — DevOps role memory seed (flat-file / signals model).
  This file is APPENDED to _core/MEMORY_base.md at compose time.
  Headings match MEMORY_base.md where they overlap so the merge reads cleanly.
  Phase-1: plain markdown. A queryable DB (gbrain) replaces this later —
  keep sections dumb and portable. No SQL, no structured query syntax.

  A specialist CONSUMES stack/architecture decisions (set by the Tech Lead);
  it records the environments it operates, the deploy conventions it follows,
  and the incidents it has handled. Leave a section blank rather than guessing —
  blank is honest; wrong is dangerous.
-->

# Memory (DevOps seed)

## Environments

<!-- The environments this agent operates and what differs between them.
     Format: - **<env>** — <url/scale/purpose> | secrets: <store ref> | deploy via: <mechanism> -->

<!-- STACK: stack-specific environment + secret-store details injected here -->

_None yet._

## Deploy conventions

<!-- Pinned deploy/CI conventions this team follows (branch→env mapping, strategy,
     gate order, canary window). Consulted before every deploy so it stays consistent. -->

<!-- STACK: stack-specific CI/deploy conventions injected here -->

_None yet._

## Active work

<!-- What is in flight. Format: - **<Deploy/Task>** — env: <target> | Status: <status> | PR: #<n> -->

_None yet._

## Recent decisions

<!-- Dated log of what changed and why. Append; do not overwrite.
     Format: - YYYY-MM-DD: <what changed> — <why> -->

_None yet._

## Incident log

<!-- Dated record of deploy failures, rollbacks, and outages — cause and resolution.
     Format: - YYYY-MM-DD: <incident> — trigger: <what> | action: <rollback/fix> | outcome: <result> -->

_None yet._

## Learned preferences

<!-- Observed preferences of the operator — deploy-window tolerance, how much to ask
     vs proceed, preferred strategy, alert thresholds. Accumulated over sessions. -->

_None yet._
