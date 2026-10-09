## Purpose

Deliver the same rule packs to harnesses other than Claude Code (Cursor, Codex, OpenCode, Gemini CLI) at project level, idempotently and without touching files the emitter did not generate.

## ADDED Requirements

### Requirement: Cursor rule emission
`rules.py emit --target cursor` SHALL write one `.cursor/rules/grid-<pack>-<topic>.mdc` per rule file of each selected pack, with `description` taken from the rule title, `globs` taken from `paths` with braces expanded, `alwaysApply: false`, and a generated-file marker comment.

#### Scenario: Emit a pack
- **WHEN** `emit --target cursor --project DIR --packs sql` runs
- **THEN** `DIR/.cursor/rules/grid-sql-<topic>.mdc` exists for each sql rule with the expected frontmatter and the rule body unchanged

#### Scenario: Brace globs expand
- **WHEN** a rule has `paths` of `"**/*.{ts,tsx}"`
- **THEN** the emitted `globs` lists `**/*.ts` and `**/*.tsx` separately

### Requirement: Cursor emission never touches foreign files
The Cursor emitter MUST delete only `grid-*.mdc` files that carry its marker and are no longer selected, and MUST NOT modify or delete any other file.

#### Scenario: Pack deselected
- **WHEN** a previous emit included `bash` and the next emit omits it
- **THEN** the marked `grid-bash-*.mdc` files are removed and a hand-written `grid-keep.mdc` without the marker remains

### Requirement: Managed instruction block
`rules.py emit --target agents-md|gemini-md` SHALL write a single block delimited by BEGIN/END marker comments into `AGENTS.md` or `GEMINI.md` in the project root, creating the file if absent and preserving all text outside the markers byte-for-byte.

#### Scenario: Update an existing file
- **WHEN** `AGENTS.md` has user text before and after an existing block and `emit` runs with a different pack list
- **THEN** only the text between the markers changes

#### Scenario: Unbalanced markers
- **WHEN** the target file has a BEGIN marker without an END marker
- **THEN** the command exits 2 and writes nothing

### Requirement: Block size cap
The block emitters MUST exit 2 without writing when the generated block exceeds `--max-bytes` (default 12288).

#### Scenario: Too many packs
- **WHEN** the selected packs produce a block over the cap
- **THEN** the command exits 2 with a message to select fewer packs and the file is unchanged

### Requirement: Idempotent and checkable emission
Every emit target SHALL produce byte-identical output on repeated runs and `--check` MUST write nothing and exit 1 if a run would change any file.

#### Scenario: Second run
- **WHEN** `emit` runs twice with the same arguments
- **THEN** the second run changes no file and `emit --check` exits 0

#### Scenario: Check detects drift
- **WHEN** an emitted `.mdc` file is edited by hand and `emit --check` runs
- **THEN** it exits 1 and modifies nothing
