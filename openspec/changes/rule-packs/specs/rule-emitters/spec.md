## Purpose

Deliver the same rule packs to harnesses other than Claude Code (Cursor, Codex, OpenCode, Gemini CLI) through one command whose interface other changes call, idempotently and without touching files the emitter did not generate.

## ADDED Requirements

### Requirement: Single emit interface with Cursor output
`python3 scripts/rules.py emit --harness <cursor|agents-md|gemini> --packs <list> [--out PATH] [--check]` SHALL be the only rule emitter in the repository, write only under `--out` (defaults `.cursor/rules`, `AGENTS.md`, `GEMINI.md` relative to the current directory), and for `cursor` write one `grid-<pack>-<topic>.mdc` per selected rule file with `description` from the rule title, `globs` from `paths` with braces expanded, `alwaysApply: false` and a generated-file marker, deleting only marker-carrying `grid-*.mdc` files that are no longer selected.

#### Scenario: Emit a pack to an explicit location
- **WHEN** `emit --harness cursor --packs sql --out DIR` runs
- **THEN** `DIR/grid-sql-<topic>.mdc` exists for each sql rule with the expected frontmatter and the rule body unchanged, and nothing is written outside `DIR`

#### Scenario: Brace globs expand
- **WHEN** a rule has `paths` of `"**/*.{ts,tsx}"`
- **THEN** the emitted `globs` lists `**/*.ts` and `**/*.tsx` separately

#### Scenario: Pack deselected
- **WHEN** a previous emit included `bash` and the next emit omits it
- **THEN** the marked `grid-bash-*.mdc` files are removed and a hand-written `grid-keep.mdc` without the marker remains

#### Scenario: Unknown harness or pack
- **WHEN** `emit` is given an unknown `--harness` value or an unknown pack
- **THEN** it exits 2 and writes nothing

#### Scenario: Check detects drift
- **WHEN** an emitted `.mdc` file is edited by hand and `emit --check` runs with the same arguments
- **THEN** it exits 1 and modifies nothing

### Requirement: Bounded managed instruction block
`emit --harness agents-md|gemini` SHALL write a single block delimited by BEGIN/END marker comments into the `--out` file, creating it if absent, preserving all text outside the markers byte-for-byte, producing byte-identical output on repeated runs, and MUST exit 2 without writing when markers are unbalanced or the block exceeds 12288 bytes.

#### Scenario: Update an existing file
- **WHEN** `AGENTS.md` has user text before and after an existing block and `emit` runs with a different pack list
- **THEN** only the text between the markers changes

#### Scenario: Second run
- **WHEN** `emit` runs twice with the same arguments
- **THEN** the second run changes no file and `emit --check` exits 0

#### Scenario: Unbalanced markers
- **WHEN** the target file has a BEGIN marker without an END marker
- **THEN** the command exits 2 and writes nothing

#### Scenario: Too many packs
- **WHEN** the selected packs produce a block over 12288 bytes
- **THEN** the command exits 2 with a message to select fewer packs and the file is unchanged
