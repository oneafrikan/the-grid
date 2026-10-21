# knowledge/

Claims this project has recorded, grouped by stage. Entries below canon are read on demand only.

## Layout

One directory per stage. An entry's `stage` frontmatter value agrees with its directory.

| Directory | Stage | Meaning |
|---|---|---|
| `knowledge/wip/` | `wip` | Unverified, or filed with no warrant. Never promoted. |
| `knowledge/provisional/` | `provisional` | One filer gave a warrant. |
| `knowledge/established/` | `established` | A second, different filer confirmed it with their own warrant. |
| `knowledge/canon/` | `canonical` | Human-approved. Canonical entries only. `scripts/map.py` lists their claims in `MAP.md`. |
| `knowledge/superseded/` | `superseded` | Replaced by a newer entry. Kept, and still resolves by address. |
| `knowledge/retired/` | `retired` | Withdrawn by a human. Kept for the record. |

## Entry file

Name: `K-<hash8>-<slug>.md`.

- `<hash8>` is the first 8 hex characters of the claim hash. `python3 scripts/knowledge.py hash "<claim>"` prints the full 16.
- `<slug>` is the claim reduced to `[a-z0-9-]`, at most 40 characters.

Format: flat frontmatter, then two fixed headings.

```
---
id: K-7483b737
claim: Scripts that write committed output pin the locale
claim_hash: 7483b7372c83655b
stage: provisional
created: 2026-10-21
updated: 2026-10-21
---

## Claim

Scripts that write committed output pin the locale

## Evidence

- 20261018T101500Z-qa-agent-3f9a1c.md | qa-agent | provisional | Ran the script under two locales and diffed the output.
```

- Optional frontmatter keys: `supersedes`, `superseded_by`, `contradicts`, `guardrail`, `unwarranted: yes`.
- `## Claim` holds the claim text.
- `## Evidence` holds one line per supporting signal: `- <signal filename> | <filed_by> | <claimed stage> | <warrant>`.
- An entry never contains signal body text.

## Entry keys

`scripts/map.py` reads two frontmatter keys and nothing else:

- `claim`: the one-line claim. Used for the canon lines in `MAP.md`.
- `stage`: used only by `python3 scripts/map.py status` for the counts.

## Citing an entry

- Cite `K-<hash8>`, or `K-<hash8>#evidence` for a heading (`claim` or `evidence`).
- Do not cite the path `knowledge/<dir>/K-<hash8>-<slug>.md`. It breaks when the entry is promoted, because the file moves to another stage directory.
- `K-<hash8>` is resolved by matching `knowledge/*/K-<hash8>-*.md`, so it survives a move.
- An address that matches no file, several files or a missing heading fails: `python3 scripts/knowledge.py check --address <addr>` exits 1 with the reason.

## Rules

- Entries stay in this project's own repo. No secrets or personal data.
- Only the sweep writes entries. Never write one by hand below canon.
- Canon changes only by a human-approved PR. The sweep opens it and never merges it.
- Retirement is a human PR that moves the entry to `knowledge/retired/` with `stage: retired`.
- Sweep: the `gh-triage` knowledge sweep, enabled per repo in the gh-triage scope file. Until a repo is listed there, nothing moves into `knowledge/` automatically.
- Stages and the warrant rule are restated in `signals/README.md`.
