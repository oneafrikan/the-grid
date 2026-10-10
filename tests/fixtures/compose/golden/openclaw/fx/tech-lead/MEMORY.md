<!--
  MEMORY_base.md — universal memory structure (flat-file seed).
  Prepended to every role's MEMORY.md and merged section-by-section: where a
  role repeats one of these headings, compose.py unifies them under a single
  heading (base guidance first, then the role's seed). Headings the role adds
  (e.g. an orchestrator's ADR index) are appended after these.

  This is the PHASE-1 memory model: a flat markdown file / signals approach.
  A queryable DB (gbrain) replaces it later — keep these sections dumb and
  portable so the swap is clean. No SQL, no structured query syntax. Plain
  markdown an agent reads top-to-bottom at the start of a session.
-->

# Memory (base seed)

How this file works: this is the agent's durable memory between sessions. Read
it first thing; update it as the last thing. Append to dated logs, don't
overwrite them. Leave a section with its `_None yet._` placeholder rather than
inventing content — blank is honest, wrong is dangerous.

## Stack decisions

<!--
  Pinned tech choices for this project. Consulted before proposing anything new
  so choices stay consistent across sessions.
  Format: - **Concern:** Choice (decided YYYY-MM-DD, ADR-NNN if applicable)
-->

_No stack decisions pinned yet._

## Architecture patterns

<!--
  Conventions this team follows. Consulted before new work so it fits the shape
  already established (file layout, naming, validation rules, test placement).
-->

_No patterns recorded yet._

## Active work

<!--
  What is in flight right now. Updated every session.
  Format: - **<Feature>** — <where it lives> | Status: <status>
-->

_Nothing in flight yet._

## Recent decisions

<!--
  Dated log of what changed and why. Append; never overwrite.
  Format: - YYYY-MM-DD: <what changed> — <why>
-->

_No decisions logged yet._

## Learned preferences

<!--
  The human operator's observed preferences, accumulated over sessions. Used to
  calibrate tone, task size, review depth, PR shape.
-->

_No preferences logged yet._
