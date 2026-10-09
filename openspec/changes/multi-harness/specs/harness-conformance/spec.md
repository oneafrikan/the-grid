## Purpose

Keep every generated harness artefact true to its single source and to the harness vendor's documented format, so mirrors cannot drift unnoticed.

## ADDED Requirements

### Requirement: Golden outputs for every generated target

Every `compose.py` target that feeds a harness SHALL have a byte-compared golden output built from fixture roles, fixture models and a fixed identity file, and updating a golden MUST require an explicit opt-in that is refused in CI.

#### Scenario: Emitter change without golden update fails
- **WHEN** an emitter's output changes by one byte and the golden is not updated
- **THEN** the golden test fails

#### Scenario: Explicit update succeeds locally
- **WHEN** `GRID_UPDATE_GOLDEN=1` is set outside CI
- **THEN** the golden directory is rewritten and the next run passes

#### Scenario: Update refused in CI
- **WHEN** `GRID_UPDATE_GOLDEN=1` and `CI` are both set
- **THEN** the test fails without writing

#### Scenario: Goldens ignore the host machine
- **WHEN** the same test runs on two machines with different `user.yaml` and hostnames
- **THEN** the composed output is identical

### Requirement: Format validators and sandboxed tests

The test suite SHALL validate every generated agent file and every linked shared-directory skill against the documented format of its harness, and MUST NOT read or write the real home directory.

#### Scenario: Codex TOML round-trips
- **WHEN** a generated body contains a backslash, a triple quote and non-ASCII text
- **THEN** the `.toml` parses with `tomllib` and `developer_instructions` equals the original body

#### Scenario: Skill limits enforced
- **WHEN** a skill is linked into the shared directory
- **THEN** its name matches `^[a-z0-9]+(-[a-z0-9]+)*$`, equals its directory name and its description is at most 1024 characters

#### Scenario: Orphan harness copy detected
- **WHEN** a generated agent file exists in a harness output directory with no matching role in the config
- **THEN** the conformance test fails
