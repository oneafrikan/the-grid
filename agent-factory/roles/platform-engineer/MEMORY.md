<!--
  MEMORY.md — Platform Engineer role memory seed (flat-file / signals model).
  This file is APPENDED to _core/MEMORY_base.md at compose time.
  Headings match MEMORY_base.md where they overlap so the merge reads cleanly.
  Phase-1: plain markdown. A queryable DB (gbrain) replaces this later —
  keep sections dumb and portable. No SQL, no structured query syntax.

  A specialist CONSUMES layout/architecture decisions (set by the Tech Lead); it
  records the repo conventions it follows, what has actually been RUN on which OS,
  and the traps it has hit. Leave a section blank rather than guessing — blank
  is honest; wrong is dangerous. Public repo: record MECHANISM here, never
  machine names, hostnames, IPs, employers or private repo names.
-->

# Memory (Platform Engineer seed)

## Repo conventions

<!-- Read from the repo, don't assume. Consulted before every change so it stays consistent.
     Format: - **<convention>** — <value> | source: <file> -->
<!-- Slots to fill: entry-point script names; the dry-run flag; the headless override
     env var; the generated-file header text; the rc marker-block text; where
     per-host files and their *.example live; how repo root is derived. -->

<!-- STACK: repo-specific conventions injected here -->

_None yet._

## Verified matrix

<!-- What has actually been exercised, per OS. One line per claim; never "works on X"
     without RAN. Append; re-date when re-run.
     Format: - YYYY-MM-DD: <claim> — RAN | READ | UNTESTED — <OS / shell / version> -->

_None yet._

## Real-run pre-flight

<!-- Per-OS steps the human confirmed for THIS repo's real runs. Policy: SKILL → Real-run
     pre-flight. Only what is recorded here is known; anything else is UNTESTED. -->

_None yet._

## Portability traps hit

<!-- Traps found in THIS repo, beyond the skill checklist. Cause and fix.
     Format: - YYYY-MM-DD: <trap> — where: <file/OS/shell> | fix: <what> -->

_None yet._

## Active work

<!-- What is in flight. Format: - **<Task>** — branch: <name> | OS in scope: <list> | Status: <status> | Review: <qa-engineer verdict or pending> -->

_None yet._

## Recent decisions

<!-- Dated log of what changed and why. Append; do not overwrite.
     Format: - YYYY-MM-DD: <what changed> — <why> -->

_None yet._

## Learned preferences

<!-- Observed preferences of the operator — which OSes they test and how, how much to ask
     vs proceed, commit/branch style, what they consider opt-in. Accumulated over sessions. -->

_None yet._
