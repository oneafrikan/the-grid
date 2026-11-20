# Plan format and guarantees

```
# lines starting with # are comments
## source: CLAUDE.md sha256:<64 hex>
B001-3fa9 -> GUARDRAILS.md#Hard constraints
B004-91c2..B009-00ab -> CONVENTIONS.md
B010-ffff -> keep
B011-1234 -> unsorted
```

- One `## source:` section per source, paths relative to the repo root. Copy the
  header line from `retrofit.py blocks <source>` (run from the repo root with the
  relative path); it pins the sha256 of the whole file.
- Ids come from `blocks`. The 4 hex digits are a hash of the block text.
- A range maps every block from the first to the last, inclusive.
- `#Heading` appends at the end of that heading's section (case-insensitive; the
  heading must exist once in the destination as it was before apply). Several
  runs into one heading land in plan order. A moved run holding a heading of the
  same or a higher level ends that section early for later readers: apply warns;
  use a flat anchor or move the children with it. No anchor appends at the end of
  the file under `## Moved from <source>`.
- `keep` and `unsorted` are reserved words. `unsorted` goes to `UNSORTED.md`.
- Destinations: existing `.md` or `.txt` text files only. Not dotfiles, not the
  plan file, not another source of the plan, not `MAP.md`, not the source itself.

## The script refuses (exit 2, with the plan line number, nothing written)

No source section or no block lines, a header without sha256, a source that
changed since `blocks` (any edit, even in the middle of a range), unknown id,
stale hash, a block not mentioned or mentioned twice, a bad destination, a path
that leaves the repo (also through a symlink), a destination ending inside an
unclosed fence or comment, an unwritable destination (checked before any write).

## What it guarantees

- `apply` never modifies the source. Moved text is appended verbatim after
  `<!-- moved from CLAUDE.md B004-91c2..B009-00ab -->`, with a blank line before it.
  Before writing it re-parses the result and refuses if any block would not read
  back as itself. `apply --yes` twice adds nothing.
- `check` compares BLOCKS, not lines: each source block must equal a block of its
  destination (only CRLF and trailing blanks are ignored). Text inside a fence or
  comment never counts, and one destination block satisfies one source block. Keep
  blocks must be in the live source, unsorted ones in `UNSORTED.md`. A missing
  destination file is a failure (exit 1). `--report` writes
  `docs/archive/retrofit-<source>-<date>-coverage.md`.
- `finalize` runs only when `check` passes and every `keep` block is in the
  replacement as a block of its own. It refuses an existing archive that differs
  (an identical one, left by a failed replace, is reused), refuses a source that
  is not tracked-and-clean in git without `--allow-dirty`, and deletes nothing.
  After it, the same plan still checks (the source text is read from the archive
  whose sha256 matches) and the next source can be finalized.
- A hard kill can leave a stray `.retrofit-*` temp file; delete it.
