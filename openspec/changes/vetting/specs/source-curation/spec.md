## Purpose

Record and enforce which upstream sources the-grid trusts to be wired, and why, so adding a source is a deliberate, documented act.

## ADDED Requirements

### Requirement: Allowed sources are enforced for wired repos

The audit SHALL compare the `.gitmodules` URL of every wired upstream repo with `policy.yaml` `sources` (host `github.com` and an `owner/repo` entry in `allowed_repos`, compared case-insensitively over both SSH and HTTPS URL forms) and SHALL report a `high` `source-not-allowed` finding for any repo not listed.

#### Scenario: Unlisted repo blocks
- **WHEN** a wired upstream repo's URL is `https://github.com/someone/new-skills.git` and `someone/new-skills` is not in `allowed_repos`
- **THEN** the audit reports a `high` `source-not-allowed` finding that points at the `.gitmodules` line

#### Scenario: SSH and HTTPS forms are equivalent
- **WHEN** a repo is declared as `git@github.com:Obra/Superpowers.git` and `allowed_repos` lists `obra/superpowers`
- **THEN** no source finding is reported

#### Scenario: Library repos are not checked
- **WHEN** a submodule is in `.gitmodules` but none of its skills are wired
- **THEN** no source finding is reported for it

#### Scenario: URL check for other tools
- **WHEN** `audit.py --check-url https://github.com/obra/superpowers` runs
- **THEN** it exits 0, and for an unlisted URL it exits 1 and prints the reason

### Requirement: Every wired source has a curation record

The audit SHALL report a `high` `source-uncurated` finding for each wired upstream repo that has no `### repos/<name>` heading in `CURATION.md`, and `CURATION.md` SHALL also record each exclusion with its reason.

#### Scenario: Missing record blocks
- **WHEN** `repos/newrepo` has a wired skill and `CURATION.md` has no `### repos/newrepo` heading
- **THEN** the audit reports `source-uncurated` for `repos/newrepo`

#### Scenario: Example baseline is fully covered
- **WHEN** the repo test suite runs
- **THEN** every repo named in the tracked `baseline-submodules.example.txt` has a heading in `CURATION.md` and an entry in `allowed_repos`

#### Scenario: Exclusions carry reasons
- **WHEN** the repo test suite reads the `## Exclusions` table of `CURATION.md`
- **THEN** every row has a non-empty reason cell
