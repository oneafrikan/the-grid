---
name: handoff
description: Compact the current conversation into a handoff document for another agent to pick up.
argument-hint: "What will the next session be used for?"
---

## Session handoff file

Write a handoff document summarising the current conversation so a fresh agent can continue the work.

**Template:** load `handoff-template.md` from this skill's base directory and fill it in. Do not invent a different structure.

**Filename:** `YYYY-MM-DD-<machine>-<slug>-handoff.md` where:
- `YYYY-MM-DD` is today's date
- `<machine>` is the output of `hostname -s` (e.g. `my-laptop`, `build-box`)
- `<slug>` is a 2-4 word kebab-case summary of the session topic (e.g. `machine-overlays`, `agent-factory-roster`)
- `-handoff` is appended to make the file self documenting

**Save location:** the location resolved by the Document locations reference below (ask before creating the directory).

**Rules:**
- Do not duplicate content already captured in commits, diffs, PRDs, plans, or ADRs — reference them by path or URL instead
- If the user passed arguments, treat them as a description of what the next session will focus on and tailor accordingly
- Suggest relevant skills for the next session in the Suggested Skills section

---

## Session context file

Also write a context file using today's actual date.
**Template:** load `context-template.md` from this skill's base directory and fill it in.
**Filename:** `YYYY-MM-DD-<machine>-<slug>-context.md` — same date, machine, and slug as the handoff file, with `-context` appended.
**Must include:** what was investigated and why, every decision and reasoning, field conventions, known bugs, key findings, open questions, immediate next actions.

---

## Document locations reference

Default: save to `LOGS/` — ask before creating it if it doesn't exist.

Optional per-project overrides: if `handoff-locations.md` exists in the private dir
(`$GRID_PRIVATE_DIR`, default `~/.the-grid-private/`), read its table first (rows: `| directory-name-or-glob | location |`);
the first row matching the current working directory wins. If the file is
absent or no row matches, use the default above.

**Case handling:** match case-insensitively — if a directory matching the
table's name already exists on disk in any casing (`logs`, `Logs`, `LOGS`),
write there as-is. Do not compare on-disk casing against git's tracked
casing, do not check `core.ignorecase`, do not investigate or flag a
mismatch — that's out of scope for this skill and wastes tokens. Only
create a new directory (using the table's casing) when nothing matching
exists at all.

---

## After writing

Resolve the save directory to its real path first (`realpath <dir>` /
`readlink -f <dir>`) — it may be a symlink into a **different** git repo than
the one you're working in (e.g. the-grid's `LOGS/` symlinks to a separate
private repo). Commit — and push, if a remote is configured — inside
whichever repo actually contains the resolved path, not necessarily the
project repo. If the resolved path isn't inside a git repo at all, leave the
files on disk and say so; don't invent a repo to commit to.

Otherwise: commit both files with the session's other changes if the project
is a git repo.