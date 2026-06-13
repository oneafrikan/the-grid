<!--
  MEMORY.md — Tech Lead role memory seed (flat-file / signals model).
  This file is APPENDED to _core/MEMORY_base.md at compose time.
  Headings match MEMORY_base.md where they overlap so the merge reads cleanly.
  Phase-1: plain markdown. A queryable DB (gbrain) replaces this later —
  keep sections dumb and portable. No SQL, no structured query syntax.

  Usage: fill in project-specific values when composing a team.
  Placeholders marked <!-- [FILL] --> must be replaced before use.
  Leave a section blank rather than guessing — blank is honest; wrong is dangerous.
-->

# Memory (Tech Lead seed)

## Stack decisions

<!--
  Pinned tech choices for this project. Tech Lead consults this before
  proposing architecture so choices stay consistent across sessions.
  Format: - **Concern:** Choice (decided YYYY-MM-DD, ADR-NNN if applicable)
-->

<!-- [FILL] Examples (delete or replace):
- **Auth:** <!-- [FILL] provider/approach -->
- **Database:** <!-- [FILL] engine + ORM/query layer -->
- **Styling:** <!-- [FILL] CSS approach -->
- **State management:** <!-- [FILL] client-side state approach -->
- **Testing:** <!-- [FILL] test framework(s) -->
- **CI/CD:** <!-- [FILL] pipeline and deploy target -->
-->

<!-- STACK: stack-specific defaults injected here by compose.py -->

## Architecture patterns

<!--
  Conventions this team follows. Consulted before writing PRDs to ensure
  new features fit the established shape.
-->

<!-- [FILL] Examples:
- API endpoints validate all inputs before processing
- Tests live alongside source files, not in a separate /tests root
- PRs are small and focused — one logical change per PR
- Server-side rendering is the default; client-side is an explicit choice
- All ADRs live at output/<project>/architecture/ADR-NNN.md
-->

<!-- STACK: stack-specific patterns (file layout, naming, framework idioms) injected here -->

## Active work

<!--
  What is currently in flight. Updated each session.
  Format: - **<Feature>** — PRD: <path> | Status: <status> | PRs: #<n> (role)
-->

<!-- [FILL] Example:
- **User dashboard** — PRD: output/dashboard/PRD.md | Status: in progress | PRs: #42 (frontend), #41 (backend — awaiting QA)
-->

_Nothing in flight yet._

## Recent decisions

<!--
  Dated log of what changed and why. Append; do not overwrite.
  Format: - YYYY-MM-DD: <what changed> — <why>
-->

<!-- [FILL] Example:
- 2026-01-15: Chose <auth provider> for authentication — fastest time to production, built-in social OAuth
- 2026-01-20: Added rate limiting to all public endpoints — abuse pattern observed in staging
-->

_No decisions logged yet._

## Learned preferences

<!--
  Observed preferences of the human operator. Accumulated over sessions.
  Tech Lead uses these to calibrate tone, task size, PR shape, etc.
-->

<!-- [FILL] Examples:
- Prefers small, focused PRs over large ones
- Code review comments must include "why", not just "change this"
- Security > functionality > performance > polish (priority order)
- Wants rollback recommended before hotfix when production error rate > 1%
- Prefers boring, well-understood tech over novel choices
-->

_No preferences logged yet._

## ADR index

<!--
  Running list of all Architecture Decision Records for this project.
  Format: - ADR-NNN: <title> — <status> (YYYY-MM-DD)
-->

_No ADRs filed yet._

## Open questions

<!--
  Unresolved questions the Tech Lead should surface at the next session.
  Clear this section when questions are resolved.
-->

_None._

## Incident log

<!--
  Summary of production incidents. Points to full post-mortems.
  Format: - YYYY-MM-DD: <slug> — <one-line summary> | Post-mortem: output/<project>/incidents/<file>.md
-->

_No incidents logged._
