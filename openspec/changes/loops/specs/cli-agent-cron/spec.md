## Purpose

Run any CLI coding agent on a schedule against a prompt file, with a hard time
cap, per-run logs and a run record. Use cases: nightly report generation,
periodic repo audits, scheduled research digests. Partially serves the
"scheduled headless run" half of issue #4.

## ADDED Requirements

### Requirement: Agent-agnostic job runner
`run-agent.sh` SHALL read `job.conf`, export `PROMPT_FILE` as an absolute path, and run `AGENT_CMD` with `bash -c`, without interpreting the command beyond that.

#### Scenario: Any command works
- **WHEN** `AGENT_CMD='cat "$PROMPT_FILE"'` and the prompt file contains `hello`
- **THEN** the run log contains `hello` and the runner exits 0

#### Scenario: No default agent
- **WHEN** `AGENT_CMD` is empty
- **THEN** the runner exits 2 with a message that `AGENT_CMD` is required

### Requirement: Wall-clock cap
The runner SHALL wrap the agent in the timeout binary with `TIMEOUT_SECS` and exit 124 when the cap is hit.

#### Scenario: Cap enforced
- **WHEN** the agent sleeps longer than `TIMEOUT_SECS`
- **THEN** the runner exits 124 and the run record outcome is `error` with note `timeout`

### Requirement: One run record per run
The runner SHALL append one `run-record.sh` line per run with role from `RUN_ROLE`, action `run`, target `JOB_NAME`, and outcome `ok` for exit 0 and `error` otherwise, and SHALL tolerate a missing recorder.

#### Scenario: Success recorded
- **WHEN** a run succeeds with `GRID_RUN_LOG` set to a temp file
- **THEN** the file gains one line with outcome `ok` and target equal to the job name

### Requirement: Logs are kept and bounded
The runner SHALL write combined output to `LOG_DIR/<JOB_NAME>-<UTC stamp>.log` and SHALL keep only the newest `KEEP_LOGS` logs for that job.

#### Scenario: Pruning
- **WHEN** `KEEP_LOGS=2` and four runs have happened
- **THEN** exactly two log files remain, the newest two

### Requirement: Headless environment and single instance
The runner SHALL load the optional `GRID_LOOP_ENV` file and add `~/.local/bin` to PATH when the agent binary is not found, SHALL exit 2 when the prompt file is unreadable, the agent binary (first word of `AGENT_CMD`) is still not on PATH, or no timeout binary exists, and SHALL exit 0 immediately when another run of the same job holds the lock.

#### Scenario: Missing agent binary
- **WHEN** `AGENT_CMD` starts with a command that does not exist
- **THEN** the runner exits 2 and starts no process

#### Scenario: Agent in the user bin dir
- **WHEN** the agent binary exists only in `$HOME/.local/bin` and PATH lacks that dir
- **THEN** the run proceeds

#### Scenario: Overlap
- **WHEN** a run is active and a second starts
- **THEN** the second exits 0 and logs that the job is already running

### Requirement: Scheduler install without activation
`install.sh <job-dir> --at HH:MM [--scheduler systemd|launchd|cron]` SHALL render the scheduler files with the shared renderers into the user's unit or agent directory (overridable by env vars) and print the activation commands, without running them.

#### Scenario: systemd files
- **WHEN** `install.sh` runs with `--scheduler systemd --at 06:30` and `SYSTEMD_USER_DIR` set to a temp dir
- **THEN** a `.service` and `.timer` exist there and the timer contains `OnCalendar=*-*-* 06:30:00`

#### Scenario: cron prints only
- **WHEN** `--scheduler cron` is used
- **THEN** a crontab line is printed and no crontab was modified

### Requirement: Example agent commands are capped
`job.conf.example` SHALL contain exactly two commented `AGENT_CMD` examples, for `claude` and `codex`, each naming an explicit model, the claude one also `--max-budget-usd`, and neither SHALL contain a permission-bypass flag.

#### Scenario: Examples checked
- **WHEN** the file is read
- **THEN** the claude line contains `--model` and `--max-budget-usd`, the codex line contains `-m`
- **AND** the text `dangerously-skip-permissions` does not appear
