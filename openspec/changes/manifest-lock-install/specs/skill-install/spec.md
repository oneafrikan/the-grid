## Purpose

Let any machine get the locked skill set with no submodule clones, using only HTTPS and git, with every byte verified against the lock.

## ADDED Requirements

### Requirement: grid install fetches only locked skills and verifies them
`grid install` SHALL, without cloning any submodule, fetch only the locked skill directories over HTTPS at each entry's pinned sha, verify commit sha, tree id and content hash against `grid.lock`, and place verified directories into a gitignored store before wiring.

#### Scenario: Fresh machine install
- **WHEN** `grid install` runs on a clone with no initialised submodules
- **THEN** each selected skill exists under `.grid/store/<source>/<path>` with a `SKILL.md`, no `repos/*` directory contains a `.git`, and the skills dir contains a link per wired skill

#### Scenario: Re-run is a no-op
- **WHEN** `grid install` is run a second time with an unchanged lock
- **THEN** no network fetch occurs, the store and ledger are unchanged, and it exits 0

#### Scenario: Hash mismatch aborts that skill
- **WHEN** the fetched content hash differs from the lock
- **THEN** nothing for that skill is placed in the store, the error names the skill, and `grid install` exits 1

#### Scenario: Non-HTTPS source refused
- **WHEN** a source URL is not `https://` and `GRID_ALLOW_FILE` is not `1` with a `file://` URL
- **THEN** `grid install` exits 2 before any network access

#### Scenario: Machine overlay subtraction honoured
- **WHEN** the machine overlay contains `-gstack/qa`
- **THEN** that skill is not fetched and not wired

#### Scenario: Setup-flagged source
- **WHEN** a selected source has `needs-setup: true`
- **THEN** `grid install` prints a notice that the source's own setup is not run and still exits 0
