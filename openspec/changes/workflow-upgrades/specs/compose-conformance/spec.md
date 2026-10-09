## Purpose

Make any change to what `compose.py` emits visible as a test failure, so emitters cannot drift silently.

## ADDED Requirements

### Requirement: Emitted output is byte-compared to goldens
The test suite SHALL render a fixture compose config for each of the `claude-code`, `openclaw`, `paperclip` and `openclaw-native` targets and byte-compare the result with committed golden trees.

#### Scenario: Unchanged emitters pass
- **WHEN** `scripts/compose-goldens.sh --check` runs on a clean checkout
- **THEN** it exits 0 and reports no differences

#### Scenario: Drift fails the check
- **WHEN** a golden file is edited, or deleted, in a temporary copy used as `GOLDEN_DIR`
- **THEN** `scripts/compose-goldens.sh --check` exits 1
- **AND** the output names the differing file

### Requirement: Goldens do not depend on the machine
The golden render MUST read identity from a fixture `user.yaml` through `GRID_USER_CONFIG` and roles from fixture directories through `GRID_PRIVATE_ROLES_DIR`, never from the user's personal files.

#### Scenario: No personal or host data in goldens
- **WHEN** the committed golden trees are searched for the local hostname, `/Users/` and an absolute repository path
- **THEN** there are no matches

#### Scenario: Personal config is ignored
- **WHEN** `GRID_USER_CONFIG` points at the fixture file and `agent-factory/user.yaml` holds different values
- **THEN** the rendered IDENTITY files contain only the fixture values

### Requirement: Updating goldens is explicit and idempotent
The script SHALL regenerate goldens only when run with `--update`, and a repeated `--update` MUST produce identical files.

#### Scenario: Second update is a no-op
- **WHEN** `--update` runs twice into the same temporary `GOLDEN_DIR`
- **THEN** the two resulting trees are byte-identical
