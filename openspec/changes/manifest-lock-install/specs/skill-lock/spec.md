## Purpose

Pin every default-wired skill to a reviewed commit and content hash, generated from the maintainer's submodule checkouts.

## ADDED Requirements

### Requirement: grid.lock pins each wired skill
`grid lock` SHALL generate a deterministic `grid.lock` listing, for every skill that `wire.sh` wires from a submodule for the tracked baseline, its `kind` (`skill`), source, 40-character commit sha, repo-relative path, git tree id and content hash, and `grid lock --check` MUST exit 1 when the committed file differs from a fresh generation.

#### Scenario: Lock generated from submodules
- **WHEN** a maintainer runs `grid lock` with all baseline submodules initialised at their recorded commits
- **THEN** `grid.lock` is written with one entry per wired skill, sorted, each with `sha` of 40 hex characters and `hash` starting `sha256:`

#### Scenario: Second run is byte-identical
- **WHEN** `grid lock` is run twice with no changes between runs
- **THEN** `grid.lock` is byte-identical after both runs

#### Scenario: Lock run writes only to temp dirs
- **WHEN** `grid lock` runs `wire.sh` to resolve the wired set, with `HOME` pointing at an empty directory
- **THEN** that directory is still empty afterwards and no file outside a temporary directory and `grid.lock` is created or changed

#### Scenario: Submodule not at its recorded commit
- **WHEN** a baseline submodule's checkout differs from the commit recorded in the parent repo, or its skill directory has uncommitted changes
- **THEN** `grid lock` exits 2 and names the submodule without writing `grid.lock`

#### Scenario: Stale lock fails the check
- **WHEN** a submodule moves to a commit that changes a wired skill and `grid.lock` is not regenerated
- **THEN** `grid lock --check` exits 1 and names the skill

#### Scenario: Editor and interpreter litter ignored
- **WHEN** a `.DS_Store` file, a `__pycache__` directory or a `.pyc` file exists inside a skill directory on disk or in git
- **THEN** the skill's content hash is the same as without them

#### Scenario: Unsafe skill path
- **WHEN** a wired skill directory path contains a space, a leading `-` or a character outside `[A-Za-z0-9._@+-]`, or the skill contains a nested submodule
- **THEN** `grid lock` exits 2 naming it

#### Scenario: Check not possible here
- **WHEN** `grid lock --check` runs and no source named in `grid.lock` has a `repos/<source>/.git`
- **THEN** it exits 3 with a message and `gate.sh` reports the check as skipped, not failed

#### Scenario: Partial checkouts are still checked
- **WHEN** `grid lock --check` runs and some, but not all, sources named in `grid.lock` have a checkout
- **THEN** it compares the present sources, names each skipped source on stderr, and exits 1 if a present source is stale

#### Scenario: Symlink escaping the skill directory
- **WHEN** a wired skill contains a symlink whose target resolves outside the skill directory
- **THEN** `grid lock` exits 2 and names the file

#### Scenario: Locked commit not on the declared ref
- **WHEN** the commit recorded for a source is not an ancestor of the source's declared ref (`origin/HEAD` for `HEAD`) and no tag points at it
- **THEN** `grid lock` and `grid lock --check` exit 2 naming the source, the commit and the ref, and `grid lock` writes nothing
- **AND** a shallow checkout that cannot show the ancestry makes `grid lock` and `grid lock --check` exit 2 naming the source
- **AND** `grid lock --check` skips that reachability check, with a notice, only when `GRID_LOCK_ALLOW_SHALLOW=1` is set (CI clones submodules at depth 1); `grid lock` never skips it
- **AND** the lock is only as trustworthy as the review of the change that edits it: the commit is checked against the ref at lock time, not against what upstream does later

#### Scenario: Duplicate lock entries
- **WHEN** `grid.lock` holds two entries with the same destination, or the same name and source
- **THEN** every command that reads it (`lock --check`, `install`, `doctor`, `drift`) exits 2 naming both entries

#### Scenario: Empty or partial lock refused
- **WHEN** `grid lock` would write zero entries, or a baseline source named in `grid.yaml` has no checkout
- **THEN** it exits 2 naming the cause and leaves `grid.lock` unchanged
