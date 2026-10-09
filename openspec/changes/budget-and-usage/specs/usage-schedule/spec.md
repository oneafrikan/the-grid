## Purpose

Run the usage extract weekly on every machine, whatever its OS, and publish only that machine's file to the private repo so cross-machine evidence accumulates without manual steps.

## ADDED Requirements

### Requirement: Weekly job publishes one file per host
The weekly job SHALL run the extractor, then commit and push only that host's usage file in the private repo, treating pull and push failures as non-fatal and making no commit when the file is unchanged.

#### Scenario: First run publishes
- **WHEN** the job runs against a private git repo with a remote
- **THEN** one commit containing only the host's usage file is pushed

#### Scenario: Second run is a no-op
- **WHEN** the job runs again with no new usage
- **THEN** no new commit is created

#### Scenario: Push failure keeps the data
- **WHEN** the remote is unreachable
- **THEN** the job exits successfully, the commit remains local and the failure is logged

#### Scenario: Thin client without the private repo
- **WHEN** the private directory is not a git repository
- **THEN** the file is written locally and git steps are skipped

### Requirement: Per-OS scheduler installer
The system SHALL provide an installer that renders the weekly job's launchd job on macOS, systemd user timer on Linux with systemd, or crontab line otherwise through the shared schedule renderer, writes only scheduler files, prints the activation commands without running any scheduler command, and keeps absolute paths out of tracked files.

#### Scenario: Install writes files and prints activation only
- **WHEN** the installer runs with override directories
- **THEN** scheduler files appear there with the repository path substituted, the activation commands are printed, and no scheduler command is invoked

#### Scenario: Unsafe install path is refused
- **WHEN** the repository or state path contains characters the renderer cannot escape safely
- **THEN** the installer exits with status 2 and writes nothing

#### Scenario: Installer is idempotent
- **WHEN** the installer runs twice
- **THEN** the second run produces no change

#### Scenario: Uninstall removes only what was installed
- **WHEN** uninstall runs
- **THEN** the installed scheduler files are removed and nothing else is touched

#### Scenario: Missed runs are caught up
- **WHEN** the machine was asleep at the scheduled time
- **THEN** the systemd timer is persistent and the launchd job runs on wake
