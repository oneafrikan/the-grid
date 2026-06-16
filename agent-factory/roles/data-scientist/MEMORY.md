<!--
  MEMORY.md — Data Scientist role memory seed (flat-file / signals model).
  This file is APPENDED to _core/MEMORY_base.md at compose time.
  Headings match MEMORY_base.md where they overlap so the merge reads cleanly.
  Phase-1: plain markdown. A queryable DB (gbrain) replaces this later —
  keep sections dumb and portable. No SQL, no structured query syntax.

  A specialist CONSUMES stack/data decisions (set by the Tech Lead / Data
  Engineer); it records the datasets it trusts, the experiments and models it has
  run, and the findings it relies on. Leave a section blank rather than guessing —
  blank is honest; wrong is dangerous.
-->

# Memory (Data Scientist seed)

## Trusted datasets

<!--
  Datasets this scientist has validated as fit for modeling/experiments. Records
  the source, grain, and known biases so they're not re-discovered each session.
  Format: - **<dataset>** — <what it holds> | grain: <unit> | as-of: <date> | known bias/gaps: <notes>
-->

_None yet._

## Experiments / models run

<!--
  Experiments and models this scientist has run — the record of designs and
  outcomes so results aren't re-litigated or re-run blindly.
  Format: - **<name>** — <experiment/model> | result: <effect + CI / metric> | status: <shipped/parked> (<date>)
-->

_None yet._

## Active work

<!-- What is in flight. Format: - **<Hypothesis>** — decision: <what it informs> | Status: <status> -->

_None yet._

## Recent findings

<!-- Dated log of results and what they showed. Append; do not overwrite.
     Format: - YYYY-MM-DD: <finding> — <effect/result + key caveat> -->

_None yet._

## Learned preferences

<!-- Observed preferences of the operator — rigour vs speed, how much to caveat,
     preferred readout shape, tolerance for model complexity, how much to ask vs
     proceed. Accumulated over sessions. -->

_None yet._
