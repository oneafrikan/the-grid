## Purpose

Run any CLI coding agent on a schedule against a prompt file, with a hard time
cap, per-run logs and a run record. Use cases: nightly report generation,
periodic repo audits, scheduled research digests. Partially serves the
"scheduled headless run" half of issue #4.

## ADDED Requirements

### Requirement: Capped, logged, recorded scheduled agent job
`run-agent.sh` SHALL read `job.conf`, parse (never execute) the optional env file `GRID_CRON_ENV` and export its `KEY=value` pairs, append `~/.local/bin`, `/opt/homebrew/bin` and `/usr/local/bin` to PATH when absent, export `PROMPT_FILE` as an absolute path and `GRID_CRON=1`, and run `AGENT_CMD` with `bash -c` inside the timeout binary with `TIMEOUT_SECS`; SHALL exit 2 when `AGENT_CMD` is empty, the prompt file is unreadable, the first word of `AGENT_CMD` is not on PATH or no timeout binary exists; SHALL exit 0 at once when another run of the same job holds the lock; SHALL write combined output to `LOG_DIR/<JOB_NAME>-<UTC stamp>.log` and keep only the newest `KEEP_LOGS`; SHALL append one `run-record.sh` line (role `RUN_ROLE`, action `run`, target `JOB_NAME`, `ok` on exit 0 else `error`, note `timeout` on 124 or 137) and tolerate a missing recorder; and SHALL mirror the agent's exit code (124 for a timeout). `install.sh <job-dir> --at HH:MM [--scheduler systemd|launchd|cron]` SHALL render through `scripts/lib/render-schedule.sh`, print the activation commands and never run them. `job.conf.example` SHALL contain exactly two commented `AGENT_CMD` examples (`claude` with `--model` and `--max-budget-usd`; `codex` with `-m`) and no permission-bypass flag.

#### Scenario: Any command works
- **WHEN** `AGENT_CMD='cat "$PROMPT_FILE"; echo "$GRID_CRON"'` and the prompt file contains `hello`
- **THEN** the run log contains `hello` and `1`, and the runner exits 0

#### Scenario: Preflight refusals
- **WHEN** `AGENT_CMD` is empty, or starts with a command that does not exist
- **THEN** the runner exits 2 and starts no process

#### Scenario: Agent in the user bin dir
- **WHEN** the agent binary exists only in `$HOME/.local/bin` and PATH lacks that dir
- **THEN** the run proceeds

#### Scenario: Cap enforced and recorded
- **WHEN** the agent sleeps longer than `TIMEOUT_SECS` with `GRID_RUN_LOG` set to a temp file
- **THEN** the runner exits 124 and the record outcome is `error` with note `timeout`
- **AND** a successful run adds one line with outcome `ok` and target equal to the job name

#### Scenario: Pruning and overlap
- **WHEN** `KEEP_LOGS=2` and four runs have happened
- **THEN** exactly the newest two log files remain
- **AND** a second run started while one is active exits 0 and logs that the job is already running

#### Scenario: Scheduler files printed, not activated
- **WHEN** `install.sh` runs with `--scheduler systemd --at 06:30` and `SYSTEMD_USER_DIR` set to a temp dir
- **THEN** a `.service` and `.timer` exist there and the timer contains `OnCalendar=*-*-* 06:30:00`
- **AND** with `--scheduler cron` a crontab line is printed and no crontab was modified

#### Scenario: Examples checked
- **WHEN** `job.conf.example` is read
- **THEN** the claude line contains `--model` and `--max-budget-usd`, the codex line contains `-m`, and `dangerously-skip-permissions` does not appear
