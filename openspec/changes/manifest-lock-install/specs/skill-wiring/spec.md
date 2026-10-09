## Purpose

Keep one wiring script serving both the maintainer path (submodules) and the install path (store).

## ADDED Requirements

### Requirement: wire.sh reads the install store without changing the maintainer path
`scripts/wire.sh` SHALL resolve each source name to its submodule checkout when `repos/<name>` is its own git checkout, otherwise to `.grid/store/<name>` when present, and MUST produce identical links and `.wired.manifest` as before for a repository with no store.

#### Scenario: Store used when submodule is absent
- **WHEN** `.grid/store/<name>/skills/foo/SKILL.md` exists, `repos/<name>` is an empty directory, and the baseline wires `<name>/foo`
- **THEN** `wire.sh` links `foo` into `SKILLS_DIR` pointing at the store directory

#### Scenario: Submodule wins over store
- **WHEN** both a git checkout at `repos/<name>` and a store directory for `<name>` exist
- **THEN** `wire.sh` wires from the checkout and ignores the store

#### Scenario: No store, no change
- **WHEN** the existing `tests/test_wiring.bats` suite runs after the change
- **THEN** every existing test passes unmodified

#### Scenario: Baseline override
- **WHEN** `GRID_BASELINE` names a file
- **THEN** `wire.sh` loads that file instead of `baseline-submodules.txt`; when unset it behaves as before
