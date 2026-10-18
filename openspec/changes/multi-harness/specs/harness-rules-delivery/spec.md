## Purpose

Put the rule packs compiled by `rule-packs` into each active harness's global instruction file. Reuse its emitter, never create a file the operator has not created, and never inject text by default.

## ADDED Requirements

### Requirement: Rules delivered through the rule-packs emitter into existing instruction files

For every active harness that has an instruction file in the registry, `wire.sh` SHALL deliver the wired rule packs by calling `scripts/rules.py emit --harness <rules_harness> --packs <list> --out <file>` when that file already exists. It MUST NOT create a missing instruction file. It SHALL remove the block from an inactive harness's file.

#### Scenario: Missing instruction file is not created
- **WHEN** `harness:codex` is active, a `rules:` pack is wired and `~/.codex/AGENTS.md` does not exist
- **THEN** no file is created and the wiring manifest records `rules-file-absent`

#### Scenario: Symlinked instruction file is not written through
- **WHEN** `~/.codex/AGENTS.md` is a symlink (to any file) and a `rules:` pack is wired
- **THEN** the target file is byte-identical afterwards and the manifest records `rules-file-symlink`

#### Scenario: Existing file receives the block and keeps user text
- **WHEN** `~/.codex/AGENTS.md` exists with user text and a `rules:` pack is wired
- **THEN** the rule-packs block is present and the user text is unchanged byte-for-byte

#### Scenario: Unchanged rules are a no-op
- **WHEN** `wire.sh` runs twice with the same wired packs
- **THEN** the second run does not modify the instruction file

#### Scenario: No wired packs means no block
- **WHEN** no `rules:` entry is wired and the file holds a block from an earlier run
- **THEN** the block is removed and the user text remains

#### Scenario: Deactivation removes the block
- **WHEN** a harness whose file holds the block is deactivated
- **THEN** the block is removed from that file

#### Scenario: Empty opt-in file is left alone
- **WHEN** a harness's instruction file exists and is empty, with no rule-packs block, and the harness is inactive or no pack is wired
- **THEN** the file still exists afterwards and `rules.py` is not called for it

#### Scenario: Skills-only harness is never touched
- **WHEN** `GRID_HARNESS=antigravity` is set
- **THEN** no instruction file is read or written for it
