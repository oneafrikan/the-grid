## Purpose

Provide a repeatable scan that fails the commit gate and CI when personal data re-enters the public tree, using generic rules kept in public and a concrete denylist kept only in the private repo.

## ADDED Requirements

### Requirement: Generic patterns scan tracked text files

`scripts/check-personal.sh` SHALL scan every tracked text file, excluding submodules and allowlisted paths, against the rules in `scripts/personal-patterns.txt` and exit 1 if any finding remains.

#### Scenario: Email and home path flagged

- **WHEN** a tracked file contains an email address on a non-example domain or a `/Users/<name>/...` path with a real user name
- **THEN** the script prints `path:line: [label]` for each and exits 1

#### Scenario: Placeholders pass

- **WHEN** a tracked file contains `you@example.com`, `git@github.com` and `/Users/you/project`
- **THEN** the script exits 0

#### Scenario: Untracked files ignored

- **WHEN** a gitignored or untracked file contains a flagged string
- **THEN** the script does not report it

### Requirement: Private denylist extends the scan

The script SHALL merge the rules in `${GRID_PRIVATE_DENYLIST-$HOME/.the-grid-private/denylist.txt}` when that file exists, and MUST NOT print the matched text of a denylist finding.

#### Scenario: Denylist hit is redacted

- **WHEN** a tracked file matches rule 3 of the private denylist
- **THEN** the output line is `path:line: [private:3]`, the matched text is absent, and the exit status is 1

#### Scenario: Denylist absent

- **WHEN** the private denylist file does not exist
- **THEN** the script prints a notice that only generic patterns ran and exits 0 if there are no generic findings

#### Scenario: Private half disabled explicitly

- **WHEN** `GRID_PRIVATE_DENYLIST` is set to the empty string
- **THEN** no denylist is read and no absence notice is printed

### Requirement: Scoped and allow rules

Rule files SHALL use four tab-separated columns (kind, scope, label, regex) where `allow` rules suppress `deny` hits on the same line within the same scope.

#### Scenario: Scoped rule applies only in scope

- **WHEN** the author's first name appears in `skills/x/SKILL.md` and in `README.md`
- **THEN** only the `skills/` occurrence is reported

### Requirement: Archives, secrets files and oversize files blocked

The script MUST flag tracked files with extensions `zip`, `pdf`, `tar`, `tgz`, `gz`, `sqlite`, `db`, `pem`, `key`, a tracked `.env`, and any file larger than `GRID_MAX_BYTES` (default 1048576), unless the path is allowlisted.

#### Scenario: Archive tracked

- **WHEN** `vendor/bundle.zip` is tracked and not allowlisted
- **THEN** the script reports it and exits 1

#### Scenario: Allowlisted path skipped

- **WHEN** a path matches a glob in `scripts/personal-allow-paths.txt`
- **THEN** the script skips it for every rule

### Requirement: Gate and CI enforcement

`scripts/gate.sh` SHALL run the scan as a `personal` check, and the bats suite MUST include a repo-wide generic scan so CI fails without access to the private denylist.

#### Scenario: Gate fails on residue

- **WHEN** a tracked file gains a home-directory path
- **THEN** `bash scripts/gate.sh` prints FAIL for `personal` and exits 1

#### Scenario: Gate skips the private half visibly

- **WHEN** the private denylist is absent and the tree is clean
- **THEN** the gate passes and its summary lists `personal-denylist` as skipped

#### Scenario: Scan is idempotent

- **WHEN** the script runs twice on an unchanged tree
- **THEN** both runs print identical output and modify no file
