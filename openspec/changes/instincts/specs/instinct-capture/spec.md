## Purpose

Record what happens in an opted-in project (commands, edited paths, user prompts) at zero token cost, so a weekly job has material to learn from. Use case: any developer-facing project the operator works in across several machines.

## ADDED Requirements

### Requirement: Capture is opt-in per project
The system SHALL capture observations only for a project whose `.grid/project.yaml` contains `learning: on`, and SHALL treat every other value, or an absent flag, as off, independent of the hook profile.

#### Scenario: Flag absent
- **WHEN** a hook payload arrives for a git repo whose `.grid/project.yaml` has no `learning: on`
- **THEN** no observation file is created or changed
- **AND** the hook exits 0 with empty output

#### Scenario: Flag flipped off after registration
- **WHEN** hooks are still registered in settings but the flag is changed to `learning: off`
- **THEN** capture writes nothing

#### Scenario: Profile does not imply learning
- **WHEN** the hook profile is `strict` and the flag is absent
- **THEN** the emitted settings contain no instincts hooks

### Requirement: Capture costs zero tokens and never blocks
The system SHALL implement capture as a single local process that makes no model call and exits 0 for every input, including malformed input.

#### Scenario: Malformed payload
- **WHEN** the hook receives text that is not JSON
- **THEN** the process exits 0, writes nothing and prints nothing

#### Scenario: Subagent and analyser sessions
- **WHEN** the payload carries an `agent_id`, or `GRID_INSTINCTS_SKIP=1` is set
- **THEN** nothing is recorded

### Requirement: Observations are scrubbed and minimal
The system SHALL record only the tool name, a scrubbed command or project-relative path, a scrubbed prompt truncated to 240 characters, an error flag and timestamps, and MUST NOT record tool output or file contents.

#### Scenario: Secret in a command
- **WHEN** a Bash command contains `API_KEY=abcd1234efgh5678`
- **THEN** the stored line contains `[REDACTED]` in place of the value

#### Scenario: Edit records the path only
- **WHEN** an Edit tool call completes
- **THEN** the stored line holds the project-relative path and no file content

#### Scenario: Sensitive file touched
- **WHEN** a command or path refers to `.env` or an SSH private key
- **THEN** the whole observation is dropped

### Requirement: Raw observations stay on the machine
The system SHALL write raw observations only under the machine-local state directory and SHALL NOT place them in any git-tracked directory.

#### Scenario: Location
- **WHEN** an observation is captured
- **THEN** it is appended to a file under `GRID_STATE_DIR` (default `~/.local/state/the-grid`), mode 0600
- **AND** nothing is written under the private learning directory

### Requirement: Projects without a git remote are not captured
The system SHALL skip capture when the repository has no git remote, because it has no stable cross-machine project id.

#### Scenario: Local-only repo
- **WHEN** the working directory is a git repo with no remote
- **THEN** capture writes nothing
