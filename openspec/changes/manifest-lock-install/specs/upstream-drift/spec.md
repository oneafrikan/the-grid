## Purpose

Tell the maintainer, weekly and cheaply, when upstream has moved on from a locked skill, without ever changing the install.

## ADDED Requirements

### Requirement: Weekly drift report that never updates
`grid drift` SHALL compare each locked entry's tree id with its source's upstream head using `git ls-remote` plus a trees-only fetch, write a Markdown report under `${GRID_STATE_DIR:-$HOME/.grid}/reports/`, and MUST NOT modify `grid.lock`, the ledger, any `repos/` directory or any link; `grid schedule install` SHALL write a launchd plist on macOS or a systemd user service and timer on Linux with a user manager (printing a crontab line otherwise), rendered through the shared `scripts/lib/render-schedule.sh` weekly form, MUST exit 2 writing nothing when the install path contains a character outside `[A-Za-z0-9_./@+-]`, and MUST NOT run any activation command.

#### Scenario: No drift
- **WHEN** every source's upstream head equals its locked sha
- **THEN** the report states all sources current and no fetch occurs

#### Scenario: Changed skill reported
- **WHEN** a source moved and one wired skill's tree id differs at the new head
- **THEN** the report lists that skill as changed with the locked and upstream short shas, and unchanged skills in that source are only counted

#### Scenario: Removed path reported
- **WHEN** a locked skill path no longer exists at the upstream head
- **THEN** the report lists it as removed

#### Scenario: Read-only guarantee
- **WHEN** `grid drift` completes
- **THEN** `grid.lock`, the ledger and `repos/` are byte-identical to before and the exit status is 0

#### Scenario: Schedule files per OS
- **WHEN** `grid schedule install` runs with `GRID_OS` set to `Darwin`, `Linux` and another value
- **THEN** a plist, a `grid-drift.service` plus `grid-drift.timer` pair, and no file but a printed crontab line containing `scripts/grid drift` are produced respectively, each rendered by `scripts/lib/render-schedule.sh` with schedule `weekly:Mon:09:00` and command `/usr/bin/env python3 <grid>/scripts/grid drift --quiet`, and no `launchctl`, `systemctl` or `crontab` command runs

#### Scenario: Weekly timing
- **WHEN** the plist or timer is rendered
- **THEN** it fires on Monday at 09:00 local time and its `PATH` and log location are exactly what the renderer emits

#### Scenario: Unquotable install path
- **WHEN** `grid schedule install` runs from a grid directory whose path contains a space or a character outside `[A-Za-z0-9_./@+-]`
- **THEN** it exits 2 with a message and writes nothing

#### Scenario: Unknown upstream ref
- **WHEN** a source's `ref` does not exist upstream
- **THEN** the report lists the source as unreachable with `ref not found` and the exit status is 0

#### Scenario: Schedule is idempotent and removable
- **WHEN** `grid schedule install` is run twice, then `grid schedule remove`
- **THEN** the files are byte-identical after the second install and absent after remove
