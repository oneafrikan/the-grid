## Purpose

Declare, in one tracked file, where the-grid's wired skills come from and which set is wired by default, without duplicating the baseline grammar.

## ADDED Requirements

### Requirement: grid.yaml declares sources and the default wired set
The repository SHALL contain a tracked `grid.yaml`, restricted to a documented YAML subset, that lists each wired source (directory name, HTTPS `url`, optional `ref`, optional `needs-setup`) and points `wired.baseline` at a tracked file in the existing baseline entry grammar.

#### Scenario: Valid manifest parses
- **WHEN** `grid lock --check` or any `grid` subcommand reads a `grid.yaml` that uses only comments, `key: scalar` lines and two-space nesting
- **THEN** it loads without error and exposes each source with its `url`, `ref` (default `HEAD`) and `needs-setup` (default false)

#### Scenario: Syntax outside the subset is rejected
- **WHEN** `grid.yaml` contains a list item, anchor, flow mapping or multi-line scalar
- **THEN** `scripts/grid` exits 2 naming the offending line number

#### Scenario: Baseline repo without a source
- **WHEN** the file named by `wired.baseline` wires a `repo` or `repo/skill` that has no entry under `sources`
- **THEN** `grid lock --check` exits 1 and names the missing source

### Requirement: Source URLs are HTTPS and match the submodules
Every source URL in `grid.yaml` and every public submodule URL in `.gitmodules` MUST use `https://`, and each `grid.yaml` source MUST have the same URL as the `.gitmodules` entry for `repos/<name>`.

#### Scenario: SSH URL in grid.yaml
- **WHEN** a source `url` starts with `git@` or `ssh://`
- **THEN** `grid doctor` and `grid install` refuse it with a message naming the source

#### Scenario: URL mismatch with .gitmodules
- **WHEN** `grid.yaml` and `.gitmodules` disagree on a source's URL
- **THEN** `grid lock --check` exits 1 and prints both URLs

#### Scenario: Public submodules use HTTPS
- **WHEN** the bats suite runs against the repository's own `.gitmodules`
- **THEN** no URL starts with `git@` except those on the documented private-repo allowlist in the test
