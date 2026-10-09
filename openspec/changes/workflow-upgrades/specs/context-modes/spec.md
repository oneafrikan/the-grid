## Purpose

Let a user start a Claude Code session in a named working mode (development, research, review) with one command, at zero cost to sessions that do not use it.

## ADDED Requirements

### Requirement: Context files are small and shipped
The repository SHALL ship `contexts/dev.md`, `contexts/research.md` and `contexts/review.md`, each at most 1200 bytes.

#### Scenario: Files exist and stay small
- **WHEN** the context files are listed
- **THEN** all three exist
- **AND** none exceeds 1200 bytes

### Requirement: Aliases append rather than replace the system prompt
The sourced snippet `contexts/aliases.sh` SHALL define `claude-dev`, `claude-research` and `claude-review` as `claude --append-system-prompt-file <file>`, MUST NOT use `--system-prompt-file`, and MUST NOT write any file.

#### Scenario: Alias invokes claude with the append flag
- **WHEN** `contexts/aliases.sh` is sourced in bash with alias expansion on and `claude-dev foo` runs against a stub `claude`
- **THEN** the stub receives `--append-system-prompt-file` followed by the path of `contexts/dev.md`, then `foo`

#### Scenario: Works under zsh
- **WHEN** `contexts/aliases.sh` is sourced in zsh
- **THEN** the three aliases are defined with absolute paths to the context files

#### Scenario: Directory override
- **WHEN** `GRID_DIR` is set before sourcing
- **THEN** the aliases point at `$GRID_DIR/contexts/`
