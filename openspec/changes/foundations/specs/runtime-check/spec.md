## Purpose

Surface wired skills whose runtime was never set up, keep the runtime-root link alive across re-wiring, and run the upstream setup without touching global hooks.

## ADDED Requirements

### Requirement: wire.sh maintains runtime links and reports missing runtimes
For each row in `scripts/lib/runtimes.txt` whose repo is wired, `wire.sh` SHALL keep `$SKILLS_DIR/<link>` as a symlink to `$GRID_DIR/repos/<repo>` without replacing a real directory, and SHALL print `runtime MISSING: <repo>` with the command `bash scripts/runtime-setup.sh <repo>` when the marker is absent, still exiting 0.

#### Scenario: Marker missing
- **WHEN** gstack is wired and `repos/gstack/browse/dist/browse` is absent
- **THEN** the output contains `runtime MISSING: gstack`
- **AND** the exit status is 0
- **AND** `$SKILLS_DIR/gstack` resolves to `repos/gstack`

#### Scenario: Repo not wired
- **WHEN** the repo has no baseline or overlay entry
- **THEN** no warning is printed and no link is created

#### Scenario: Link survives re-wiring
- **WHEN** `wire.sh` runs twice
- **THEN** the link exists after each run and `wire.sh --check` exits 0

#### Scenario: Runtime root occupied
- **WHEN** a real directory, or a symlink to anywhere other than `$GRID_DIR/repos/gstack`, exists at `$SKILLS_DIR/gstack`
- **THEN** wire.sh skips it with a "runtime root occupied, not managed" line and leaves it untouched

### Requirement: Runtime setup is hook-free and safe to re-run
`scripts/runtime-setup.sh` MUST run the repo's declared setup command, remove only the skill dirs that setup created or converted during that run, re-run `wire.sh`, and exit 3 if the Claude settings file differs afterwards.

#### Scenario: Clean setup
- **WHEN** the setup command leaves the settings file unchanged
- **THEN** the script removes setup's flat skill dirs, re-runs `wire.sh`, and exits 0

#### Scenario: Setup changed settings
- **WHEN** the setup command edits the settings file
- **THEN** the script prints the rollback command and exits 3

#### Scenario: Missing prerequisite
- **WHEN** the `needs` command is not on PATH
- **THEN** the script exits 2 before running setup

#### Scenario: Occupied runtime root blocks setup
- **WHEN** `$SKILLS_DIR/<link>` exists and is not a symlink to `$GRID_DIR/repos/<repo>`
- **THEN** the script exits 2 before running setup and removes nothing

#### Scenario: Setup flags exist upstream
- **WHEN** `repos/gstack/setup` is present
- **THEN** every flag in the declared setup command appears in that file

#### Scenario: Pre-existing real dir
- **WHEN** a real directory existed in the skills dir before the run
- **THEN** it is not removed

#### Scenario: Second run
- **WHEN** the script is run twice in a row
- **THEN** the skills dir and settings file are the same after both runs and `wire.sh --check` exits 0
