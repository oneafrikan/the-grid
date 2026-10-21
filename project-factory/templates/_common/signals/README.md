# signals/

Where agents and humans record a claim for this project's knowledge flow. One file per signal.

## Layout

- `signals/`: pending signals, one file each, named `<UTC YYYYMMDDTHHMMSSZ>-<filer>-<hash6>.md`.
- `signals/done/`: processed signals. Only the sweep moves a file there, never the filer.
- Files starting with `→` (for example `→qa.md`) are agent-to-agent handoffs, not knowledge signals. They share this directory and `scripts/map.py status` does not count them.

## File name

`<UTC YYYYMMDDTHHMMSSZ>-<filer>-<hash6>.md`

- The timestamp is UTC.
- `<filer>` is the slug of `filed_by`: `[a-z0-9-]{1,32}`.
- `<hash6>` is six lowercase hex characters.
- Example: `20261018T101500Z-qa-agent-3f9a1c.md`

## Rules

- Signals stay in this project's own repo. Never file one in another project's repo.
- No secrets or personal data in a signal. Never paste a token, key, password or personal data, not even in the body or as an example.
- The commit-time secret scan is opt-in and partial; it is not a safety net. Keep secrets out by hand.
- Signals are immutable once committed. Never edit one; file a new signal instead.
- Only the sweep moves files to `signals/done/`. Never move or delete a signal yourself.
- Sweep: the `gh-triage` knowledge sweep, enabled per repo in the gh-triage scope file. Until a repo is listed there, its signals stay pending.
- Recommended: set `hooks.profile: standard` in `.grid/project.yaml` so the commit-time secret guard is on.

## Fields

Frontmatter is flat: `---` fences, one `key: value` per line. An unknown key, a missing required key or a repeated key makes the signal invalid. Keep the body under 4096 bytes.

| Key | Required | Value |
|---|---|---|
| `filed_by` | yes | who files it (agent or human slug) |
| `claim` | yes | one line, 1-200 characters |
| `stage` | yes | `wip`, `provisional`, `established` or `canonical` |
| `warrant` | yes | one line, 1-300 characters: what you ran or read, and where |
| `status` | yes | always `pending` |
| `supersedes` | no | one entry address `K-<hash8>` |
| `contradicts` | no | one entry address `K-<hash8>` |
| `confirms` | no | one entry address `K-<hash8>` |
| `guardrail` | no | `GUARDRAILS#Gn` |

## Template

Copy, fill in, save under the file name above. Add optional keys as extra lines inside the fences.

```
---
filed_by: your-slug
claim: One line stating what is true.
stage: wip
warrant: What you ran or read, and where.
status: pending
---
```

## Filing

- By hand: write the file yourself. `<hash6>` is any six hex characters, or `shasum -a 256 <file> | cut -c1-6`.
- By helper: `python3 scripts/knowledge.py file` writes a valid signal to `signals/` and prints its path. It does not commit. It is present in every seeded project and optional to use.

## Evidence and stages

Restated here because project-level agents may not receive the grid-wide agent base text.

- Every claim carries its warrant: what you ran or read, and where.
- Stages, lowest to highest: `wip` (unverified), `provisional` (warrant given), `established` (confirmed by a different filer's own warrant), `canonical` (human-approved via PR).
- `superseded` and `retired` are end states set by a human.
- The stage you file is a proposal. `canonical`, and anything that supersedes or contradicts an entry, is decided by a human.
- No warrant means `wip`, and `wip` is never promoted.
- Confidence (H/M/L) and source tier are not stages; put them in the warrant text.
- Completion claims are tagged RAN (executed this session), READ (read, not executed) or UNTESTED.
