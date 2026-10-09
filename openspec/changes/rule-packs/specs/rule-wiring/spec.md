## Purpose

Wire selected rule packs into Claude Code's user rules directory through the existing baseline/overlay manifest, opt-in and reversible, like skills.

## ADDED Requirements

### Requirement: Opt-in pack wiring
`wire.sh` SHALL create rule links only for packs named by `rules:<pack>` entries (minus `-rules:<pack>` subtractions) across the baseline, machine overlay and local overlay, symlinking each `rules/<pack>/*.md` except `README.md` to `$RULES_DIR/grid/<pack>/<file>.md`, where `RULES_DIR` defaults to `~/.claude/rules`.

#### Scenario: No rules entries
- **WHEN** `wire.sh` runs with a manifest that has no `rules:` entry
- **THEN** nothing is created under `$RULES_DIR/grid`

#### Scenario: Wire a pack
- **WHEN** the manifest contains `rules:sql` and `wire.sh` runs
- **THEN** each rule file of `rules/sql` is a symlink under `$RULES_DIR/grid/sql/` resolving to its source, and no `README.md` link exists

#### Scenario: Overlay subtracts a pack
- **WHEN** the baseline has `rules:sql` and the machine overlay has `-rules:sql`
- **THEN** `wire.sh` creates no links for `sql`

#### Scenario: Typo in a manifest
- **WHEN** the manifest contains `rules:slq`
- **THEN** `wire.sh` prints a warning naming `slq`, records a skipped manifest row, exits 0, and wires the other entries

### Requirement: Idempotent, non-destructive teardown
`wire.sh` SHALL remove grid-owned rule symlinks that are no longer wired and the resulting empty directories under `$RULES_DIR/grid`, and MUST NOT remove or overwrite anything it did not create.

#### Scenario: Re-run is a no-op
- **WHEN** `wire.sh` runs twice with the same manifest
- **THEN** the link set under `$RULES_DIR/grid` is identical after both runs and the second run exits 0

#### Scenario: Entry removed
- **WHEN** a `rules:` entry is removed and `wire.sh` runs again
- **THEN** that pack's links and its empty directory are gone

#### Scenario: Foreign and real files survive
- **WHEN** `$RULES_DIR/grid` contains a symlink pointing outside the repo and a real file at a path a wired pack would use
- **THEN** both are left untouched and the real-file case is recorded as skipped in `.wired.manifest`

### Requirement: Drift detection without side effects on other readers
`wire.sh --check` SHALL exit 1 when the rule links under `$RULES_DIR/grid` differ from a fresh wiring, and `catalog.sh` and `sources.sh` MUST ignore `rules:` and `-rules:` lines.

#### Scenario: Missing link
- **WHEN** a wired rule link is deleted and `wire.sh --check` runs
- **THEN** it exits 1 and lists the expected link

#### Scenario: Catalog unchanged
- **WHEN** a `rules:sql` line is added to the baseline
- **THEN** `catalog.sh --check` output and `SKILLS.md` are unchanged
