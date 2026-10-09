## Purpose

Tell the maintainer, weekly and cheaply, when upstream has moved on from a locked skill, without ever changing the install.

## ADDED Requirements

### Requirement: Weekly drift report that never updates
`grid drift` SHALL compare each locked skill's tree id with its source's upstream head using `git ls-remote` plus a trees-only fetch, write a Markdown report to the report directory, and MUST NOT modify `grid.lock`, the store, the ledger or any link; `grid schedule install` SHALL create a weekly job via launchd on macOS, a systemd user timer on Linux with a working user manager, and a tagged cron entry otherwise.

#### Scenario: No drift
- **WHEN** every source's upstream head equals its locked sha
- **THEN** the report states all sources current and no blob data was fetched

#### Scenario: Changed skill reported
- **WHEN** a source moved and one wired skill's tree id differs at the new head
- **THEN** the report lists that skill as changed with the locked and upstream short shas, and unchanged skills in that source are only counted

#### Scenario: Removed path reported
- **WHEN** a locked skill path no longer exists at the upstream head
- **THEN** the report lists it as removed

#### Scenario: Read-only guarantee
- **WHEN** `grid drift` completes
- **THEN** `grid.lock`, `.installed.manifest` and the store are byte-identical to before and the exit status is 0

#### Scenario: Scheduler chosen per OS
- **WHEN** `grid schedule install` runs with `GRID_SCHEDULE_DIR` set on Darwin, on Linux with systemd user support, and on Linux without it
- **THEN** a launchd plist, a `grid-drift.service` plus `grid-drift.timer` pair, and a crontab line tagged `# the-grid drift` respectively are produced, and no `launchctl`, `systemctl` or `crontab` command runs

#### Scenario: Scheduler is idempotent and removable
- **WHEN** `grid schedule install` is run twice, then `grid schedule remove`
- **THEN** exactly one job exists after the second install and none after remove
