# Plan format and guarantees

```
# lines starting with # are comments
## source: CLAUDE.md
B001-3fa9 -> GUARDRAILS.md#Hard constraints
B004-91c2..B009-00ab -> CONVENTIONS.md
B010-ffff -> keep
B011-1234 -> unsorted
```

- One `## source: <path>` section per source, paths relative to the repo root.
- Ids come from `retrofit.py blocks <source>`. The 4 hex digits are a hash of the
  block text: if the source changed since, the plan is rejected as stale.
- A range maps every block from the first to the last, inclusive.
- `#Heading` appends at the end of that heading's section (case-insensitive, the
  heading must exist once in the destination). No anchor appends at the end of
  the file under `## Moved from <source>`.
- `keep` and `unsorted` are reserved words. `unsorted` goes to `UNSORTED.md`
  (created if absent).

## The script refuses (exit 2, with the plan line number, nothing written)

Unknown id, stale hash, a block not mentioned, a block mentioned twice, a
destination that does not exist, a path that leaves the repo (also through a
symlink), `MAP.md`, or the source itself as destination.

## What it guarantees

- `apply` never modifies the source. Moved text is appended verbatim after an
  HTML comment `<!-- moved from CLAUDE.md B004-91c2..B009-00ab -->`.
- `apply --yes` twice adds nothing (the comment marks a run as done).
- `check` re-reads every destination: each moved block must appear verbatim and
  contiguously (only CRLF and trailing blanks are ignored), each `keep` block
  must still be in the source, each `unsorted` block in `UNSORTED.md`. Duplicate
  blocks need as many copies. Any miss exits 1 and names the block.
- `check --report` writes `docs/archive/retrofit-<source>-<date>-coverage.md`.
- `finalize` runs only when `check` passes and every `keep` block is in the
  replacement. It refuses to overwrite an archive, refuses a source that is not
  tracked-and-clean in git unless `--allow-dirty`, and never deletes anything
  else. After finalize the plan is spent (the source changed): do not re-run it.
