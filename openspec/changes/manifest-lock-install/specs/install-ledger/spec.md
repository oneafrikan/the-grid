## Purpose

Record exactly what grid placed on a machine so health checks and removal touch only grid-owned files.

## ADDED Requirements

### Requirement: Install ledger records what grid wrote
`grid install` and `grid repair` SHALL write `.installed.manifest`, a sorted, timestamp-free TSV with one row per installed skill (`kind`, `name`, `source`, `sha`, `path`, `dest`, `hash`) using paths relative to the grid directory, rewriting the file only when its content changes.

#### Scenario: Ledger rows after install
- **WHEN** `grid install` completes
- **THEN** `.installed.manifest` has one `skill` row per store directory, `dest` begins `.grid/store/`, and no field contains an absolute path

#### Scenario: Unchanged ledger is not rewritten
- **WHEN** `grid install` is re-run with nothing to do
- **THEN** the ledger file's modification time is unchanged

#### Scenario: Ledger is per-machine state
- **WHEN** `git status` is run after an install
- **THEN** `.installed.manifest` and `.grid/` do not appear as untracked
