## Purpose

Surface wired skills whose runtime was never set up, keep the runtime-root link alive across re-wiring, and run the upstream setup without touching global hooks.

## ADDED Requirements

### Requirement: wire.sh checks declared runtime markers
For each row in `scripts/lib/runtimes.txt` whose repo is wired, `wire.sh` SHALL print a `runtime MISSING` line naming the repo, the marker and the command `bash scripts/runtime-setup.sh <repo>` when the marker is absent, and SHALL still exit 0.

#### Scenario: Marker missing
- **WHEN** gstack is wired and `repos/gstack/browse/dist/browse` is absent
- **THEN** the output contains `runtime MISSING: gstack`
- **AND** the exit status is 0

#### Scenario: Repo not wired
- **WHEN** the repo has no baseline or overlay entry
- **THEN** no warning is printed and no link is created

### Requirement: wire.sh maintains the runtime-root link
`wire.sh` SHALL ensure `$SKILLS_DIR/<link>` is a symlink to `$GRID_DIR/repos/<repo>` for each active row, and MUST NOT replace a real directory at that path.

#### Scenario: Link survives re-wiring
- **WHEN** `wire.sh` runs twice
- **THEN** the link exists after each run and `wire.sh --check` exits 0

#### Scenario: Real dir in the way
- **WHEN** a real directory exists at `$SKILLS_DIR/gstack`
- **THEN** wire.sh skips it with a "real dir, not managed" line and leaves it untouched

### Requirement: Runtime setup does not change global hooks
`scripts/runtime-setup.sh` MUST run the repo's declared setup command with its hook-suppressing flags and SHALL exit 3 if the Claude settings file differs afterwards.

#### Scenario: Clean setup
- **WHEN** the setup command leaves the settings file unchanged
- **THEN** the script removes setup's flat skill dirs, re-runs `wire.sh`, and exits 0

#### Scenario: Setup changed settings
- **WHEN** the setup command edits the settings file
- **THEN** the script prints the rollback command and exits 3

#### Scenario: Missing prerequisite
- **WHEN** the `needs` command is not on PATH
- **THEN** the script exits 2 before running setup

### Requirement: Runtime setup is safe to re-run
A second `scripts/runtime-setup.sh` run MUST leave the skills dir and settings file unchanged.

#### Scenario: Second run
- **WHEN** the script is run twice in a row
- **THEN** the second run removes nothing and `wire.sh --check` exits 0
