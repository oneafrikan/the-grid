## Purpose

Make `wire.sh` teardown remove exactly the links the-grid owns, whatever shape the target dir has, and let dry runs write only into a throwaway home.

## ADDED Requirements

### Requirement: Teardown removes only links that target inside the grid dir
`wire.sh` SHALL treat a symlink as grid-owned only when its target begins with `$GRID_DIR/`, so a link into a sibling directory that merely shares the `$GRID_DIR` prefix is never removed.

#### Scenario: Sibling-prefix link survives
- **WHEN** `$SKILLS_DIR` contains a symlink to `${GRID_DIR}-private/x`
- **THEN** `wire.sh` leaves that link in place

#### Scenario: Grid-owned link is removed
- **WHEN** `$SKILLS_DIR` contains a symlink to `$GRID_DIR/repos/gone`
- **THEN** `wire.sh` removes it before rewiring

### Requirement: Teardown and check follow a symlinked target dir
`wire.sh` teardown and `wire.sh --check` SHALL list the links inside `$SKILLS_DIR` and `$AGENTS_DIR` even when either path is itself a symlink to a directory.

#### Scenario: Symlinked skills dir is torn down
- **WHEN** `$SKILLS_DIR` is a symlink to a real directory holding a stale grid-owned link
- **THEN** `wire.sh` removes the stale link

#### Scenario: Check sees drift through a symlinked dir
- **WHEN** `$SKILLS_DIR` is a symlink to a real directory holding a stale grid-owned link
- **THEN** `wire.sh --check` exits 1

### Requirement: GRID_DRY_HOME redirects every home-derived target
When `GRID_DRY_HOME` is set, `wire.sh` SHALL write only under that directory: `HOME`, `SKILLS_DIR`, `AGENTS_DIR`, `CLAUDE_CONFIG_DIR`, `RULES_DIR` (`$GRID_DRY_HOME/.claude/rules`) and `GRID_HARNESS_HOME` (`$GRID_DRY_HOME`) are forced under it regardless of inherited values, and the repo's `SKILLS.md` and `.wired.manifest` are not written. `wire.sh --check` SHALL use it for its throwaway run.

#### Scenario: Real home untouched by a dry run
- **WHEN** `HOME`, `SKILLS_DIR`, `AGENTS_DIR`, `CLAUDE_CONFIG_DIR` and `RULES_DIR` point into a fake real home holding a sentinel file and a stale grid-owned link, and `wire.sh` runs with `GRID_DRY_HOME` set
- **THEN** the fake real home is byte-identical afterwards
- **AND** the wired links exist under `$GRID_DRY_HOME/.claude/skills`
- **AND** the repo's `.wired.manifest` and `SKILLS.md` are unchanged

#### Scenario: Check run leaves the real home alone
- **WHEN** `wire.sh --check` runs with the same fake real home
- **THEN** the fake real home is byte-identical afterwards
