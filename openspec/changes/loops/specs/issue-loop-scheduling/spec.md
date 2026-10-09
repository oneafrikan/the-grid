## Purpose

Schedule the headless runner on Linux (systemd user timer) as well as macOS
(launchd), from pure, testable renderers. Use case: a headless Linux server that
runs the backlog nightly and catches up after downtime.

## ADDED Requirements

### Requirement: Linux profile
`instantiate.sh` SHALL accept `--profile linux`, which implies `--mode pr`, installs the guard and worktree helper, and writes a systemd user service and timer for the runner.

#### Scenario: Units written to the user unit dir
- **WHEN** `instantiate.sh issue-loop <target> --profile linux` runs with `SYSTEMD_USER_DIR` set to a temp dir
- **THEN** `issue-loop-<slug>.service` and `issue-loop-<slug>.timer` exist in that dir

#### Scenario: Nothing activated
- **WHEN** the profile run finishes
- **THEN** no `systemctl` or `launchctl` command and no `loginctl enable-linger` was executed
- **AND** the output prints the enable and linger commands for the human

### Requirement: Service unit shape
The rendered service SHALL be `Type=oneshot`, run `/bin/bash <target>/loop/run-issues.sh`, set `WorkingDirectory` to the target, set `Environment=PATH=` including `%h/.local/bin`, carry no `EnvironmentFile` (the runner loads its own optional env file), and set `TimeoutStartSec` to `MAX_ISSUES*(ISSUE_TIMEOUT+REVIEW_TIMEOUT)+600`.

#### Scenario: Required directives present
- **WHEN** the service is rendered for a target with `MAX_ISSUES=3`, `ISSUE_TIMEOUT=1800`, `REVIEW_TIMEOUT=600`
- **THEN** it contains `Type=oneshot`, `.local/bin` in `Environment=PATH=` and `TimeoutStartSec=7800`
- **AND** it contains no `EnvironmentFile=` line

#### Scenario: Unit passes systemd verification
- **WHEN** `systemd-analyze` is available and `verify` runs on the rendered files
- **THEN** it reports no errors (the test is skipped when the tool is absent)

### Requirement: Timer unit shape
The rendered timer SHALL use `OnCalendar` with the configured hour, `Persistent=true`, and `WantedBy=timers.target`, and SHALL reference its service by name.

#### Scenario: Hour option honoured
- **WHEN** `--schedule-hour 3` is passed
- **THEN** the timer contains `OnCalendar=*-*-* 03:00:00` and `Persistent=true`

### Requirement: Credentials and linger are the human's
`instantiate.sh` SHALL NOT create or write the credentials env file, SHALL print its path and keys (`GH_TOKEN` required where `gh` uses a keyring, `CLAUDE_CODE_OAUTH_TOKEN` optional), and on the linux profile SHALL warn, without changing anything, when `loginctl show-user` reports linger is not `yes`.

#### Scenario: Env file guidance
- **WHEN** the linux profile run finishes and the env file does not exist
- **THEN** the output names the env file path and `GH_TOKEN`
- **AND** the env file was not created

#### Scenario: Linger off
- **WHEN** a stub `loginctl show-user` prints `no`
- **THEN** the output warns that timers will not fire while logged out and prints `loginctl enable-linger`
- **AND** the stub log shows no `enable-linger` call

### Requirement: launchd uses the same runner and carries no personal name
The mac-mini profile SHALL write a launchd plist whose command runs `loop/run-issues.sh`, whose label starts with `io.the-grid.issue-loop.`, and which contains no personal name.

#### Scenario: Plist content
- **WHEN** `--profile mac-mini` runs with `LAUNCH_AGENTS_DIR` set to a temp dir
- **THEN** the plist references `run-issues.sh`
- **AND** its label starts with `io.the-grid.issue-loop.`

### Requirement: Renderers are pure and shared
`scripts/lib/render-schedule.sh` SHALL provide functions that print systemd service, systemd timer, launchd plist and crontab line text from arguments only, with no filesystem or process side effects.

#### Scenario: Deterministic output
- **WHEN** a renderer is called twice with the same arguments
- **THEN** both outputs are byte-identical
- **AND** no file was created

### Requirement: Public files carry no machine-specific values
Every file shipped in `automation-factory/`, `scripts/` and `tests/` for this change SHALL NOT contain a hostname, username, email address or absolute home-directory path.

#### Scenario: Scan
- **WHEN** the new and changed files are searched for `/Users/`, `/home/` and the maintainer's name
- **THEN** there are no matches
