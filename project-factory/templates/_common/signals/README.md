# signals/

Where agents and humans record a claim for this project's knowledge flow. One file per signal.

## Layout

- `signals/`: pending signals, one file each, named `<UTC YYYYMMDDTHHMMSSZ>-<filer>-<hash6>.md`.
- `signals/done/`: processed signals. Only a sweep moves a file there, never the filer.
- Files starting with `→` (for example `→qa.md`) are agent-to-agent handoffs, not knowledge signals. They share this directory and `scripts/map.py status` does not count them.

## Rules

- Signals stay in this project's own repo. Never file one in another project's repo.
- No secrets or personal data in a signal.
- Never edit a signal after it is committed; file a new one.
- Sweep: none configured. No sweep runs, so signals are not processed yet. Filing is still allowed.

## Fields

Frontmatter: `filed_by`, `claim` (one line), `stage`, `warrant`, `status: pending`. Optional: `supersedes`, `contradicts`, `confirms` (each `K-<hash8>`), `guardrail` (`GUARDRAILS#Gn`).

## Evidence and stages

Restated here because project-level agents may not receive the grid-wide agent base text.

- Every claim carries its warrant: what you ran or read, and where.
- Stages, lowest to highest: `wip` (unverified), `provisional` (warrant given), `established` (confirmed by a different filer's own warrant), `canonical` (human-approved via PR).
- `superseded` and `retired` are end states set by a human.
- The stage you file is a proposal. `canonical`, and anything that supersedes or contradicts an entry, is decided by a human.
- No warrant means `wip`, and `wip` is never promoted.
- Confidence (H/M/L) and source tier are not stages; put them in the warrant text.
- Completion claims are tagged RAN (executed this session), READ (read, not executed) or UNTESTED.
