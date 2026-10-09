## Purpose

Record exactly what grid placed on a machine so health checks and removal touch only grid-owned files.

## ADDED Requirements

### Requirement: Install ledger records what grid wrote
`grid install` and `grid repair` SHALL write `${GRID_STATE_DIR:-$HOME/.grid}/installed.manifest`, a sorted, timestamp-free TSV with one row per placed entry (`kind`, `name`, `source`, `sha`, `path`, `dest`, `hash`) whose `dest` is relative to the grid directory, rewriting the file only when its content changes.

#### Scenario: Ledger rows after install
- **WHEN** `grid install` completes
- **THEN** the ledger has one `skill` row per placed directory, `dest` begins `repos/`, and no field contains an absolute path

#### Scenario: Unchanged ledger is not rewritten
- **WHEN** `grid install` is re-run with nothing to do
- **THEN** the ledger file's modification time is unchanged

#### Scenario: Ledger is machine-local
- **WHEN** `git status` is run in the grid dir after an install
- **THEN** no ledger or staging file appears
