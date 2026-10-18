## Purpose

Make any change to what `compose.py` emits visible as a test failure, and give every public build one machine-independent identity.

## ADDED Requirements

### Requirement: Emitted output is byte-compared to goldens
The test suite SHALL render a fixture compose config for each of the `claude-code`, `openclaw`, `paperclip` and `openclaw-native` targets and byte-compare the result with committed golden trees, regenerating them only with an explicit, idempotent `--update`.

#### Scenario: Unchanged emitters pass
- **WHEN** `scripts/compose-goldens.sh --check` runs on a clean checkout
- **THEN** it exits 0 and reports no differences

#### Scenario: Drift fails the check
- **WHEN** a golden file is edited, or deleted, in a temporary copy used as `GOLDEN_DIR`
- **THEN** `scripts/compose-goldens.sh --check` exits 1
- **AND** the output names the differing file

#### Scenario: Second update is a no-op
- **WHEN** `--update` runs twice into the same temporary `GOLDEN_DIR`
- **THEN** the two resulting trees are byte-identical

### Requirement: Public builds use a neutral identity
`compose.py` SHALL read its identity from the path in `GRID_USER_CONFIG` when that variable is set and non-empty, and the tracked `agent-factory/user.public.yaml` MUST carry neutral values with a non-empty `machine` so no hostname reaches goldens or shipped output.

#### Scenario: No personal or host data in goldens
- **WHEN** the committed golden trees are searched for `/Users/`, `/home/`, the absolute repository path and `$HOME`
- **THEN** there are no matches
- **AND** each of the four target trees contains `your-machine`, proving the hostname fallback did not run

#### Scenario: Override replaces the personal file
- **WHEN** `GRID_USER_CONFIG` points at a file whose `machine` is `sentinel-xyz`
- **THEN** the rendered IDENTITY contains `sentinel-xyz`
- **AND** `agent-factory/user.yaml` is not read

#### Scenario: Missing override file fails
- **WHEN** `GRID_USER_CONFIG` names a file that does not exist
- **THEN** `compose.py` exits 1 naming the path and does not fall back to the hostname

### Requirement: Full-profile deploys default to the neutral identity
`deploy.py` SHALL render the IDENTITY nameplate from `agent-factory/user.public.yaml` unless `--identity PATH` is passed, and MUST ignore an ambient `GRID_USER_CONFIG`.

#### Scenario: Default is neutral
- **WHEN** `deploy.py <project> --roles qa-engineer --profile full` runs with `GRID_USER_CONFIG` exported to a file whose `machine` is `ambient-xyz`
- **THEN** the deployed agent file contains `your-machine`
- **AND** does not contain `ambient-xyz`

#### Scenario: Explicit identity is used
- **WHEN** `--identity` names a file whose `machine` is `sentinel-xyz`
- **THEN** the deployed agent file contains `sentinel-xyz`

#### Scenario: Missing identity file fails
- **WHEN** `--identity` names a file that does not exist
- **THEN** `deploy.py` exits non-zero with `identity file not found` and writes nothing
