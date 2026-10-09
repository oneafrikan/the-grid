## Purpose

Detect drift between lock, ledger, placed files and links, restore it safely, and remove an install without touching anything grid did not write.

## ADDED Requirements

### Requirement: Doctor reports drift and repair restores it
`grid doctor` SHALL report, without changing anything, manifest/URL problems, ledger-versus-lock differences (missing, stale, extra), placed directories that are absent or modified, and link drift from `wire.sh --check`, exiting 1 on any finding; `grid repair` MUST fix only the missing, stale, absent or modified entries by re-fetching, re-verifying and re-vetting at the locked sha.

#### Scenario: Clean install is healthy
- **WHEN** `grid doctor` runs immediately after `grid install`
- **THEN** it exits 0 and prints no findings

#### Scenario: Modified skill detected
- **WHEN** a file inside a placed skill directory is edited
- **THEN** `grid doctor` exits 1 with a `modified` finding naming that skill

#### Scenario: Repair restores a deleted skill
- **WHEN** a placed skill directory is deleted and `grid repair` runs
- **THEN** the directory is restored with a verified hash, the ledger and links are consistent, and a following `grid doctor` exits 0

#### Scenario: Maintainer machine has no ledger
- **WHEN** `grid doctor` runs where no ledger exists
- **THEN** it reports maintainer mode and checks only the manifest and link drift

#### Scenario: Lock bump shows as stale
- **WHEN** `grid.lock` changes a skill's sha after install
- **THEN** `grid doctor` reports that skill `stale` and `grid repair` updates it

### Requirement: Uninstall removes only grid-owned files
`grid uninstall` SHALL list its plan and perform no deletion without `--yes`, and MUST remove only ledger-listed directories under a `repos/<source>` that is not a git checkout, links in the skills dir whose target is one of those directories, and the ledger, never following symlinks or touching submodule checkouts, manifests, or foreign files.

#### Scenario: Dry run by default
- **WHEN** `grid uninstall` runs without `--yes`
- **THEN** it prints the files it would remove and the filesystem is unchanged

#### Scenario: Only owned files removed
- **WHEN** `grid uninstall --yes` runs and the skills dir also holds a foreign symlink and a real directory
- **THEN** both are still present afterwards, `repos/<source>` itself still exists, and the placed directories, their links and the ledger are gone

#### Scenario: Modified skill protected
- **WHEN** a placed skill's on-disk hash differs from the ledger
- **THEN** `grid uninstall --yes` skips it and lists it, and removes it only with `--force`

#### Scenario: Second run is clean
- **WHEN** `grid uninstall --yes` is run again after a successful uninstall
- **THEN** it reports nothing to remove and exits 0
