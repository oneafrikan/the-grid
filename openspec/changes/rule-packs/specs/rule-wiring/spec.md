## Purpose

Wire selected rule packs into Claude Code's user rules directory through the existing baseline/overlay manifest, opt-in and reversible, like skills.

## ADDED Requirements

### Requirement: Rules are opt-in
`wire.sh` SHALL create no rule links unless at least one `rules:<pack>` entry resolves from the baseline, machine overlay or local overlay.

#### Scenario: No rules entries
- **WHEN** `wire.sh` runs with a manifest that has no `rules:` entry
- **THEN** nothing is created under `$RULES_DIR/grid`

### Requirement: Pack wiring layout
`wire.sh` MUST symlink each `rules/<pack>/*.md` except `README.md` to `$RULES_DIR/grid/<pack>/<file>.md` for every wired pack, where `RULES_DIR` defaults to `~/.claude/rules`.

#### Scenario: Wire a pack
- **WHEN** the manifest contains `rules:sql` and `wire.sh` runs
- **THEN** each rule file of `rules/sql` is a symlink under `$RULES_DIR/grid/sql/` resolving to its source, and no `README.md` link exists

#### Scenario: Overlay subtracts a pack
- **WHEN** the baseline has `rules:sql` and the machine overlay has `-rules:sql`
- **THEN** `wire.sh` creates no links for `sql`

### Requirement: Idempotent teardown
`wire.sh` SHALL remove grid-owned rule symlinks that are no longer wired, delete the resulting empty directories under `$RULES_DIR/grid`, and never remove or overwrite anything it did not create.

#### Scenario: Re-run is a no-op
- **WHEN** `wire.sh` runs twice with the same manifest
- **THEN** the link set under `$RULES_DIR/grid` is identical after both runs and the second run exits 0

#### Scenario: Entry removed
- **WHEN** a `rules:` entry is removed and `wire.sh` runs again
- **THEN** that pack's links and its empty directory are gone

#### Scenario: Foreign and real files survive
- **WHEN** `$RULES_DIR/grid` contains a symlink pointing outside the repo and a real file at a path a wired pack would use
- **THEN** both are left untouched and the real-file case is recorded as skipped in `.wired.manifest`

### Requirement: Unknown packs do not fail wiring
`wire.sh` MUST warn on stderr, record a skipped manifest row, and exit 0 when a `rules:<pack>` entry has no directory under `rules/`.

#### Scenario: Typo in a manifest
- **WHEN** the manifest contains `rules:slq`
- **THEN** `wire.sh` prints a warning naming `slq`, exits 0, and wires the other entries

### Requirement: Drift detection
`wire.sh --check` SHALL compare the rule links under `$RULES_DIR/grid` against a fresh wiring and exit 1 on any difference.

#### Scenario: Missing link
- **WHEN** a wired rule link is deleted and `wire.sh --check` runs
- **THEN** it exits 1 and lists the expected link

### Requirement: Other manifest readers ignore rules entries
`catalog.sh` and `sources.sh` MUST ignore `rules:` and `-rules:` lines in the baseline.

#### Scenario: Catalog unchanged
- **WHEN** a `rules:sql` line is added to the baseline
- **THEN** `catalog.sh --check` output and `SKILLS.md` are unchanged
