## Purpose

Place the rules compiled by workstream 8 into each harness's global instruction file without taking ownership of the file or injecting text nobody asked for.

## ADDED Requirements

### Requirement: Managed rules block in global instruction files

`wire.sh` SHALL write compiled rules for an active harness into a marker-delimited block in that harness's global instruction file only when a compiled rules file exists for it, SHALL refuse a block over the configured byte cap, and SHALL NOT modify any text outside the markers.

#### Scenario: No compiled rules, no write
- **WHEN** `harness:codex` is active and `dist/rules/codex.md` does not exist
- **THEN** `~/.codex/AGENTS.md` is neither created nor modified

#### Scenario: Block is inserted and user text preserved
- **WHEN** `~/.codex/AGENTS.md` has user text and compiled rules exist
- **THEN** the block is appended and the user text is unchanged byte-for-byte

#### Scenario: Unchanged source is a no-op
- **WHEN** `wire.sh` runs twice with the same compiled rules
- **THEN** the second run does not modify the instruction file

#### Scenario: Changed source replaces only the block
- **WHEN** the compiled rules change
- **THEN** only the text between the markers changes

#### Scenario: Over-cap block is refused
- **WHEN** the compiled rules exceed 8192 bytes
- **THEN** `wire.sh` exits non-zero and the instruction file is unchanged

#### Scenario: Deactivation removes the block
- **WHEN** the harness is deactivated
- **THEN** its block is removed, and the file is deleted only if nothing else remains in it
