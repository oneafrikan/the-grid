## Purpose

Declare, in one tracked file, where the-grid's wired skills come from and which set is wired by default, without duplicating the baseline grammar, and keep that grammar open for rule packs and harnesses.

## ADDED Requirements

### Requirement: grid.yaml declares HTTPS sources and the default wired set
The repository SHALL contain a tracked `grid.yaml`, read with the restricted-YAML reader `scripts/lib/miniyaml.py`, that lists each wired source (directory name, `https://` `url` equal to the `.gitmodules` URL for `repos/<name>`, optional `ref`) and points `wired.baseline` at a tracked file in the existing baseline entry grammar.

#### Scenario: Valid manifest loads
- **WHEN** any `grid` subcommand reads the tracked `grid.yaml`
- **THEN** it loads without error and exposes each source with its `url` and `ref` (default `HEAD`)

#### Scenario: Unknown key rejected
- **WHEN** `grid.yaml` contains a key that is neither defined nor reserved, or `version` is not `1`
- **THEN** `scripts/grid` exits 2 naming the key or line

#### Scenario: Baseline repo without a source
- **WHEN** the file named by `wired.baseline` has an untyped `repo` or `repo/skill` entry with no entry under `sources`
- **THEN** `grid lock --check` exits 1 and names the missing source

#### Scenario: Non-HTTPS URL refused
- **WHEN** a source `url` starts with `git@`, `ssh://` or `http://`
- **THEN** `grid install` exits 2 before any network access and `grid doctor` reports a `manifest` finding naming the source

#### Scenario: URL mismatch with .gitmodules
- **WHEN** `grid.yaml` and `.gitmodules` disagree on a source's URL
- **THEN** `grid lock --check` exits 1 and prints both URLs

### Requirement: Typed entries are reserved for other asset kinds
`grid` MUST ignore every typed wired-set entry (`<kind>:<value>` or `-<kind>:<value>`, including `project:`, `rules:<pack>` and `harness:<name>`), MUST write a `kind` on every lock and ledger entry, and MUST skip lock or ledger entries of an unknown `kind` with a notice instead of failing, so rule packs and harness selection can be added without a `grid` change or a format version bump.

#### Scenario: Typed entries pass through
- **WHEN** the baseline or an overlay contains `rules:sql`, `-rules:sql`, `harness:codex`, `-harness:codex` or `project:core`
- **THEN** `grid lock` writes the same lock as without those lines and `grid install` selects the same entries

#### Scenario: Unknown lock kind tolerated
- **WHEN** `grid.lock` contains an entry with `"kind": "rule"`
- **THEN** `grid` prints one notice for that kind, ignores the entry, and exits as if it were absent

#### Scenario: Reserved grid.yaml keys
- **WHEN** `grid.yaml` has a top-level `rules` or `harnesses` key
- **THEN** it loads with a notice that the key is reserved and ignored
