## Purpose

Schedule the headless runner, and every other the-grid scheduled job, on Linux
(systemd user timer), macOS (launchd) or cron from one pure, tested renderer
that never activates anything. Use case: a headless Linux server that runs the
backlog nightly and catches up after downtime; weekly maintenance jobs owned by
other changes.

## ADDED Requirements

### Requirement: One shared print-only schedule renderer and the linux profile
`scripts/lib/render-schedule.sh` SHALL provide the functions documented in design.md (systemd service, systemd timer, launchd plist, crontab line, unit slug, activation commands), callable when sourced or as `bash scripts/lib/render-schedule.sh <function> <args...>`, that print text from arguments only with no filesystem or process side effects; SHALL accept schedules `daily:HH:MM` and `weekly:<Mon..Sun>:HH:MM`; SHALL emit `Persistent=true` in every timer and a `RandomizedDelaySec=` line only when that optional argument is given; and SHALL exit 2 with nothing on stdout when a path argument contains a character outside `[A-Za-z0-9_./@+-]` or the schedule is malformed. `instantiate.sh --profile linux` SHALL write a `Type=oneshot` service running `/bin/bash <target>/loop/run-issues.sh` (with `WorkingDirectory`, `Environment=PATH=` including `%h/.local/bin`, `TimeoutStartSec=MAX_ISSUES*(ISSUE_TIMEOUT+REVIEW_TIMEOUT)+600`, no `EnvironmentFile`, no `network-online.target`) and a daily timer, to `SYSTEMD_USER_DIR`; the `mac-mini` profile SHALL write a launchd plist that runs the runner directly (no `bash -l`), sets `PATH` including `$HOME/.local/bin` and `/opt/homebrew/bin`, and is labelled `io.the-grid.issue-loop.<slug>`. Neither SHALL run `systemctl`, `launchctl`, `crontab` or a state-changing `loginctl`, nor create the credentials env file; both SHALL print the activation commands and the env file path and keys, and the linux profile SHALL warn (without changing anything, and still exit 0 if the probe fails) when `loginctl show-user` does not report linger `yes`, also printing a crontab line as the alternative. No file shipped by this change SHALL contain a hostname, username, email address or absolute home path.

#### Scenario: Linux units written, nothing activated
- **WHEN** `instantiate.sh issue-loop <target> --profile linux --schedule-hour 3` runs with `SYSTEMD_USER_DIR` set to a temp dir and `MAX_ISSUES=3`, `ISSUE_TIMEOUT=1800`, `REVIEW_TIMEOUT=600`
- **THEN** `issue-loop-<slug>.service` contains `Type=oneshot`, `.local/bin` in `Environment=PATH=`, `TimeoutStartSec=7800` and no `EnvironmentFile=`, and the timer contains `OnCalendar=*-*-* 03:00:00` and `Persistent=true`
- **AND** no `systemctl`, `launchctl`, `crontab` or `loginctl enable-linger` was executed, the output prints the enable and linger commands, names the env file path and the keys `GH_APP_ID`, `GH_APP_INSTALLATION_ID` and `GH_APP_KEY_FILE`, and the env file does not exist

#### Scenario: Weekly timer with randomized delay
- **WHEN** `render_systemd_timer "desc" "x.service" "weekly:Sun:04:30" "1h"` is called
- **THEN** the output contains `OnCalendar=Sun *-*-* 04:30:00`, `Persistent=true` and `RandomizedDelaySec=1h`
- **AND** the same call without the fourth argument contains no `RandomizedDelaySec`

#### Scenario: Unsafe path refused
- **WHEN** a renderer receives a path containing a space, `%`, `$`, `&` or a quote
- **THEN** it exits 2, prints nothing on stdout and names the path on stderr

#### Scenario: Deterministic and pure
- **WHEN** a renderer is called twice with the same arguments, once sourced and once through the command form
- **THEN** all outputs are byte-identical and no file was created

#### Scenario: Linger off or unknown
- **WHEN** a stub `loginctl show-user` prints `no`, or exits non-zero
- **THEN** `instantiate.sh` exits 0, warns that timers will not fire while logged out, prints `loginctl enable-linger` and one crontab line, and the stub log shows no `enable-linger` call

#### Scenario: launchd plist
- **WHEN** `--profile mac-mini` runs with `LAUNCH_AGENTS_DIR` set to a temp dir
- **THEN** the plist references `run-issues.sh`, its `PATH` contains `.local/bin`, it has no `-l` argument, and its label starts with `io.the-grid.issue-loop.`

#### Scenario: No machine-specific values
- **WHEN** the new and changed files are searched for `/Users/`, `/home/` and the maintainer's name
- **THEN** there are no matches
