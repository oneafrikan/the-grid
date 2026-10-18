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
- A glob may use only `A-Za-z0-9_./*?{},[]-` (anything else, such as spaces or quotes, is
  prose smuggled into the delivered header). It must not start with `/`, contain `..`, or
  be nearly always-on: the last path segment must hold at least 2 literal characters, where
  `[...]`, `*` and `?` count 0 and a `{a,b}` group counts as its shortest alternative. That
  rejects `*`, `**/*`, `**/*.*`, `**/[a-z]*`, `**/{*,x}` and `**/*e*` but keeps `*.{ts,tsx}`
  (`E_PATHS`). A directory scope is the one allowed shape ending in `**`: `src/**` and
  `**/migrations/**` pass when the directory name has no wildcard and at least 2 characters;
  `**/**` and `*/**` do not. `..` is rejected only as a whole path segment
  (`**/foo..bar.txt` is fine), and a leading `~` is outside the character set.
- Brace expansion `{a,b}` is allowed: no nesting, no empty alternative, at most 2 groups per
  glob and 12 alternatives per group, and one rule file may expand to at most 64 globs in
  all. Write `**/*.py` and `**/*.pyi` as two entries rather than `**/*.py{,i}`.
- Rule files are untrusted text: an HTML comment marker (`<!--`, `-->`), an invisible or
  bidi character (zero-width, tag, variation selector, BOM, a blank look-alike such as
  U+3164 or U+2800), a combining mark (any Mn/Me character, so decomposed `e` + U+0301 is
  refused; write the precomposed letter), a control character (ESC, NUL, DEL; a tab is
  fine) or a word mixing ASCII letters with a confusable non-ASCII letter is `E_STYLE`,
  fenced or not. A confusable letter is one that (a) NFKC folds to ASCII letters (fullwidth,
  ligatures such as U+FB01, mathematical alphanumerics), (b) belongs to a script with ASCII
  look-alikes other than Latin or CJK (Cyrillic, Greek, Armenian, Cherokee, Coptic, Lisu,
  Osage, Canadian syllabics), or (c) is one of a few Latin look-alikes (dotless i U+0131,
  Latin alpha U+0251, script g U+0261, small capitals U+026A U+1D04 U+1D0F U+1D1C U+1D20
  U+1D21 U+1D22). Accented Latin letters (precomposed), sharp s, o-slash, l-stroke, the
  micro sign and CJK next to ASCII are fine. The denylist is matched after NFKC folding, dropping invisible
  characters (blank look-alikes become a space) and collapsing whitespace.
- Files must be UTF-8 (`E_ENCODING`) and readable (`E_UNREADABLE`); neither is ever a
  traceback. An empty `denylist.txt` with packs present is `E_OPINION` (fails closed).
- Lint is a format and hygiene check, not a security control. A merged pack is loaded as
  instructions every session, so review pack changes as raw bytes (`git diff` with
  invisible characters shown), not only as rendered markdown.
- After the frontmatter: a first line `# <Title>`, then only `##`/`###` headings,
  bullets (`- `) with two-space continuation lines, and fenced blocks of at most 10 lines
  (`E_STYLE`). A bullet is measured with its continuation lines joined by one space. A rule
  file needs at least one non-empty bullet. Fences are triple backticks only (`~~~` is one
  `E_STYLE`); a fence may be indented inside a bullet; a closing line is backticks only.
- A file with a bad frontmatter (or a leading BOM, which is named in its message) gets that
  one finding, not a cascade of title and style findings on top of it.
- Size caps: 4096 bytes per rule file (`E_FILE_SIZE`, the rest of an oversize file is not
  read), 9216 bytes per pack (`E_PACK_SIZE`).
- File and pack names are lowercase kebab-case (`E_NAME`). `readme` is a reserved topic
  name, a dangling symlink is `E_NAME`, and two rule files that would write the same Cursor
  output name (`a-b` + `c.md` and `a` + `b-c.md` both give `grid-a-b-c.mdc`) collide.
- A pack with no rule files is `E_PACK_META`.
- No line, fenced or not, may start with `<!-- BEGIN the-grid rules` or `<!-- END the-grid rules`
  or contain `the-grid:rules` (`E_MARKER`), nor start with any retired marker spelling listed in
  `scripts/lib/rules-markers.txt`: those strings delimit the managed block and the
  generated Cursor files, and a copy inside a rule body would wedge delivery and removal.
  Plain prose such as "the-grid rules" is fine.

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

- Only rows under the `## Sources` heading count. Every `<topic>.md` basename must appear
  in that table with at least one full `https://host.tld/...` URL on its row; a row naming a
  file that is not in the pack, or a URL such as `https://x`, is `E_SOURCES`.
- Tier 2 packs must contain the literal line `Adapted from affaan-m/ECC (MIT)` and be
  listed in `THIRD_PARTY_NOTICES.txt` under `Adapted packs`; the list ends at the next
  heading, and every name on it must be an existing tier 2 pack (`E_ATTRIBUTION`).
- `adapted_from` reads `<owner>/<repo> rules/<pack> @ <sha> (MIT)` (`E_PACK_META`). A
  trailing comment in `pack.yaml` needs two or more spaces before the `#`.
- `python3 scripts/rules.py lint --check-urls` checks every Sources URL (8 in parallel, 10 s
  each; HEAD, then GET on any failure; 429 and 5xx retried once; a redirect with no
  `Location` counts as alive). It needs network and is never run by the gate or the tests.
- `lint` and `list` with an explicit `--root` that has no `rules/` exit 2. Without
  `--root` (the gate uses `GRID_DIR`) an absent `rules/` is clean.

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

## Delivery to harness instruction files (`rules.py emit`)

`rules.py emit` renders packs for other harnesses (`cursor`, `agents-md`, `gemini`);
`wire.sh` calls it for the instruction files in the harness registry. How it writes:

- **Atomic:** every file is written to a temp file in the same directory and swapped in
  with `os.replace`, so a failed write (disk full, size limit, read-only file) leaves the
  original byte-identical and `emit` exits 2 with one stderr line, never a traceback.
- **Mode kept:** the permission bits (and, where allowed, the owner) of an existing file
  are kept.
- **Hard links are broken:** the swap gives the file a new inode, so a second hard link
  to the instruction file keeps the old content. Edit the file through one name only.
- **Never through a symlink:** a symlinked `--out` (or a symlink at a Cursor target path,
  even one pointing at a marker-bearing file) is refused with exit 2.
- **Empty file kept:** removing the block from a file that held nothing else truncates it
  to 0 bytes; the operator's opt-in file is never deleted.
- **Byte-exact removal:** the append adds one separator newline and removal takes it back,
  so `emit` then `emit ''` restores a newline-terminated file byte for byte (a file with no
  final newline gains one). A file whose newlines are all CRLF gets a CRLF block.
- **Exact markers:** the managed block is the complete BEGIN line through the complete END
  line, matched whole-line (a CR before the newline is allowed). A user note that merely
  starts like a marker, or quotes one marker, is user text. Markers are exact-line matches,
  so a hand-edited BEGIN line is treated as user text and the next emit appends a fresh
  block (decision D20). An exact END line with no BEGIN line at all (the BEGIN was deleted, or
  edited so it no longer starts `<!-- BEGIN the-grid rules`) is refused with a message that says
  so; restore the BEGIN line or delete the END line by hand. If the edited BEGIN still starts
  `<!-- BEGIN the-grid rules`, it and the END beside it are taken for a quoted fence: emit
  appends a fresh block and the stale END line stays. Residual: a user fence that
  quotes our complete BEGIN and END lines is still treated as our block.
- **Marker spellings:** `scripts/lib/rules-markers.txt` is the one list of BEGIN/END lines,
  read by `rules.py` and by `wire.sh` (via `scripts/lib/harness.sh`). The first of each is
  what `emit` writes; to reword a marker put the new line first and keep the old one below
  it, so blocks written under the old wording are still found and replaced. A spelling not
  listed there is user text and is never removed automatically.
- **Re-validated delivery:** `emit` lints the rule files of every selected pack first
  (frontmatter, paths, title, style, size, denylist and marker text). A failing pack is
  excluded and named on stderr, the clean packs are still delivered, and the exit is 2 so
  `wire.sh` shows red. If every selected pack fails, nothing is written. A missing, empty
  or partly invalid `denylist.txt` stops delivery of any pack (exit 2); removal needs no denylist.
- **Exit codes:** 0 done or no drift, 1 drift (`--check` only; it prints `would write` /
  `would remove`), 2 refusal or I/O error, 3 block over the 12288-byte cap (nothing
  written, an existing block untouched). `wire.sh` treats 3 as a visible skip, not a failure.
- **Registry limits:** `wire.sh` refuses (exit 2) a registry where two harnesses share a
  `rules_file`, and only writes instruction files named `AGENTS.md`, `GEMINI.md` or
  `CLAUDE.md` under `~/` (otherwise the manifest row says `rules-file-not-allowed`).
