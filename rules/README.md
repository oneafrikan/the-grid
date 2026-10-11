# rules/

Rule packs: short, path-scoped directive files that Claude Code loads only when a
matching file is read or edited. Nothing in this directory is loaded by itself;
packs are wired per machine through the manifest (see `openspec/changes/rule-packs`).
This README, `denylist.txt`, `THIRD_PARTY_NOTICES.txt` and the review prompts are
never wired (any `.md` in a wired rules directory would load on every session).

Layout:

```
rules/
  denylist.txt                 # regexes of house opinions (lint input)
  THIRD_PARTY_NOTICES.txt      # MIT notice for ECC + list of adapted packs
  review-a.prompt.txt          # Reviewer A prompt (source fidelity)
  review-b.prompt.txt          # Reviewer B prompt (opinion and overbuild)
  README.md                    # this file
  <pack>/
    pack.yaml                  # flat key: value metadata
    README.md                  # purpose + Sources table (not wired)
    <topic>.md                 # rule files; frontmatter = paths only
```

Check and inspect with `python3 scripts/rules.py lint` and `python3 scripts/rules.py list`.
The gate runs `lint` on every commit.

## Rule file format

```markdown
---
paths:
  - "**/*.sql"
---
# BigQuery

- Select only the columns you need; never `SELECT *` on a wide or partitioned table.
- Filter on the partition column in every query against a partitioned table.
```

- Frontmatter is the first block delimited by `---` lines. It holds exactly one key,
  `paths:`, followed by one or more `  - "<glob>"` lines (two-space indent, double quotes).
  Any other key or shape is `E_FRONTMATTER`.
- A glob must not start with `/`, contain `..`, or be effectively always-on (last
  segment empty after removing `*?[]{},.`, which rejects `*`, `**/*`, `**/*.*`): `E_PATHS`.
- Brace expansion `{a,b}` is allowed: no nesting, no empty alternative, at most 2 groups
  per glob. Write `**/*.py` and `**/*.pyi` as two entries rather than `**/*.py{,i}`.
- After the frontmatter: a first line `# <Title>`, then only `##`/`###` headings,
  bullets (`- `) with two-space continuation lines, and fenced blocks of at most 10 lines
  (`E_STYLE`).
- Size caps: 4096 bytes per rule file (`E_FILE_SIZE`), 9216 bytes per pack (`E_PACK_SIZE`).
- File and pack names are lowercase kebab-case (`E_NAME`).

## pack.yaml

```yaml
# Flat "key: value" lines only. Parsed by rules.py (no YAML library).
summary: Warehouse-first SQL (BigQuery), portable safety rules
tier: 1                      # 1 = written fresh, 2 = adapted from ECC
adapted_from: affaan-m/ECC rules/python @ ef648e0 (MIT)   # required iff tier 2
```

## Pack README.md (required, never wired)

```markdown
# sql

Warehouse-first SQL conventions. Not tuned for MySQL/Postgres OLTP.

## Sources

| Rule file | Source |
|---|---|
| style.md | https://docs.getdbt.com/best-practices/how-we-style/2-how-we-style-our-sql |
| bigquery.md | https://cloud.google.com/bigquery/docs/best-practices-performance-overview |
| safety.md | https://cloud.google.com/bigquery/docs/parameterized-queries |

## Adaptation notes
(tier 2 only) What was dropped from ECC and why; "Adapted from affaan-m/ECC (MIT), see rules/THIRD_PARTY_NOTICES.txt".
```

- Every `<topic>.md` basename must appear in the table with at least one `https://` URL
  on its row (`E_SOURCES`).
- Tier 2 packs must contain the literal line `Adapted from affaan-m/ECC (MIT)` and be
  listed in `THIRD_PARTY_NOTICES.txt` under `Adapted packs` (`E_ATTRIBUTION`).

## Pack authoring template

Authoring standards. Lint enforces the starred ones; Reviewer B checks the rest.

1. Each bullet is one directive: starts with an imperative verb, names one concrete construct in backticks (function, flag, config key, keyword), and gives the reason in at most one short clause. Maximum 240 characters (*).
2. Write only what changes model output: non-default behaviour, easy-to-miss pitfalls, tool or config consequences. Omit advice a competent model follows unprompted ("use descriptive names", "handle errors", "keep functions small", "write tests").
3. State the positive form first (`Use X for Y`). Use "never" only for a hazard, and name the hazard in the bullet.
4. Use `When <trigger>, <action>` for conditional rules. Name a specific tool only if its cited source does; otherwise write "the project's formatter".
5. Allowed line shapes are `##`/`###` headings, bullets, and at most a few fenced snippets of at most 10 lines (*). No prose paragraphs or block quotes (*), and no pointers to other rules, skills or agents (denylist).
6. One topic per file, scoped to the narrowest `paths:` where its bullets apply. Two files in one pack with identical `paths:` is a smell; a bullet that only concerns CSS does not belong in a file that loads on `.tsx`.
7. A directive appears once across all packs. If it applies to two stacks, keep it in the more general pack (for example `sql`, not `dbt`) and rely on both loading.
8. Size targets: 1.5-2.5 KB per file and at most 6 KB per tier 1 pack. The 4096 and 9216 byte caps are ceilings (*), not targets.
9. No hedging, no workflow mandates (tests, coverage, review, commits, agents), no house opinions; every bullet traces to a cited source (README Sources table (*) and Reviewer A).

Rule file skeleton (the `Good`/`Bad` lines are illustrative, not rules):

```markdown
---
paths:
  - "**/*.sql"
---
# BigQuery

## Cost
- Name the columns you need; `SELECT *` bills every column read.
- Filter on the partition column in `WHERE` so BigQuery prunes partitions.
- Set `require_partition_filter` on large partitioned tables so unfiltered scans fail.
```

```
Good: Use `ref()` or `source()` for every table reference in a model; hard-coded schema names break lineage.
Bad:  You should try to write clean, readable SQL with meaningful names.   (hedged, generic, no construct)
```

Pack README skeleton: as in "Pack README.md" above. `pack.yaml` skeleton: as in "pack.yaml" above.

## Review procedure

Every content PR (a PR that adds or changes a pack) runs two independent Opus
reviewers after lint passes. The prompts are `review-a.prompt.txt` (Reviewer A, source
fidelity: fetches every cited URL and quotes support for each bullet) and
`review-b.prompt.txt` (Reviewer B, opinion and overbuild: codes B1-B8).

1. Spawn both in one message with the Agent tool: `subagent_type: general-purpose`,
   `model: opus`, fresh agents. The prompt is the prompt file with `<PACK_DIRS>`
   replaced by the PR's pack directories. Add nothing else.
2. Both end with exactly `VERDICT: PASS` or `VERDICT: FAIL`; findings are `MUST`/`NICE` lines.
3. Resolve every `MUST` by rewriting or deleting the bullet. Re-run only the reviewer
   that failed, with a fresh agent; at most 2 re-runs per reviewer.
4. Still FAIL after 2 re-runs, or WebFetch denied: open the PR as a draft labelled
   `needs-human` and stop.
5. Paste both final outputs in the PR body under `## Reviewer A (source fidelity)` and
   `## Reviewer B (opinion and overbuild)`. Mark ready only when both pass.

## Size caps (summary)

- 4096 bytes per rule file; 9216 bytes per pack; bullets at most 240 characters.
- Targets: 1.5-2.5 KB per file, at most 6 KB per tier 1 pack.
- A file read loads every matching file, so packs that co-load (for example typescript,
  web and react on `.tsx`) add up; `python3 scripts/rules.py list` shows the sizes.
