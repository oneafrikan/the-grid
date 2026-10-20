## Purpose

Start a loop run when there is work and nothing is running, without anyone typing. Use case: the operator's server or laptop, one cron line per repo that the operator installs by hand, working the `ready-for-agent` backlog gh-triage prepared. The first run is started by hand; the cron line comes after. The waker starts runs; it never decides what is in the queue, and never installs itself.

Built differently from the first draft of this delta: there is no `loop/wake.sh` and no `gh issue list` pre-check. The cron line runs `loop/cron-run.sh`, which sources `loop/cron.env` and `exec`s `run-issue.sh`; the runner's own lock, backoff window and empty-queue exit do what `wake.sh` was to do. The option is `--cron-every N` (not `--waker-interval`).

## ADDED Requirements

### Requirement: cron-run.sh starts a run only when needed
`loop/cron-run.sh` SHALL source `loop/cron.env` if it exists, `cd` to the repo root and `exec bash loop/run-issue.sh` with no issue number, so the cron child is the runner. It SHALL NOT start a second runner when a run exists. The checks `wake.sh` was to make are the runner's: lock held by a live run (exit 0 "busy"), an open `backoff` window (exit 0, one log line), an empty queue (exit 0, no run-record line).

#### Scenario: Idle
- **WHEN** no open issue carries `ISSUE_LABEL`
- **THEN** exit 0, one log line, no run-record line, no worker started

#### Scenario: Work waiting
- **WHEN** one open issue carries the label and no lock exists
- **THEN** `run-issue.sh` runs once and its pid is the cron child's pid (`exec`)

#### Scenario: Run in progress
- **WHEN** the lock is held by a live `run-issue.sh`
- **THEN** exit 0 "busy" with no `gh` write and no `claude` call

#### Scenario: Two ticks race
- **WHEN** two ticks start within the same second
- **THEN** one run proceeds and the other exits 0 "busy"

#### Scenario: Infrastructure failure is loud and backs off
- **WHEN** `gh` or `claude` is logged out, or `gh` or origin is unreachable
- **THEN** exit 1 with one stderr line naming the cause (cron logs it), the issue keeps its label, and the next ticks exit 0 inside the backoff window

### Requirement: Stripped cron environment works
The cron line SHALL NOT depend on a login shell, on `XDG_*` variables, or on a TTY. `loop/cron.env` (machine-local, gitignored, written by `instantiate.sh --cron-every`) SHALL export `HOME` and a `PATH` of `/usr/local/bin:/usr/bin:/bin` plus the directories of `gh`, `claude`, `jq`, `git`, `awk` and `timeout` as resolved at install time (system directories first; a tool that cannot be found prints a warning). A missing prerequisite exits non-zero with a message instead of hanging on a prompt.

#### Scenario: Minimal environment
- **WHEN** run as `env -i HOME=$HOME PATH=/usr/bin:/bin bash loop/cron-run.sh` with stub tools in a directory named in `cron.env`
- **THEN** it finds them and completes

#### Scenario: Not logged in
- **WHEN** `claude auth status` or `gh auth status` fails (stub)
- **THEN** exit 1, the failure is recorded as infrastructure with a backoff window, nothing is relabelled and no worker starts

### Requirement: Rendered as text the operator installs
`scripts/lib/render-schedule.sh` SHALL accept the schedule form `every:N` (N an integer 1 to 59, minutes) in `render_crontab_line`, producing `*/N * * * *` with the existing `mkdir -p <logdir> && cd <workdir> && <cmd> >> <log> 2>&1` shape. `render_systemd_timer` and `render_launchd_plist` SHALL return 2 for `every:` with a one-line stderr "every: is cron-only". `daily:` and `weekly:` output SHALL be byte-identical to before. `instantiate.sh --cron-every N` (pr mode only; N is 1 to 59) SHALL print one crontab line for that repo (log `--cron-log`, default `~/.grid/logs/issue-loop-<repo>.log`) running `bash loop/cron-run.sh`, plus the idempotent command that adds it, and SHALL write `loop/cron.env`. It SHALL never run `crontab`. Without the option nothing cron-related is printed or written.

#### Scenario: Cron line
- **WHEN** `render_crontab_line every:15 /home/user/.grid/logs/loop.log /home/user/proj bash loop/cron-run.sh` is called
- **THEN** stdout is one line starting `*/15 * * * * mkdir -p /home/user/.grid/logs && cd /home/user/proj && bash loop/cron-run.sh >> /home/user/.grid/logs/loop.log 2>&1`

#### Scenario: Malformed
- **WHEN** the schedule is `every:0`, `every:60`, `every:x` or `every:`
- **THEN** return 2, nothing on stdout

#### Scenario: Regression
- **WHEN** the existing `daily:` and `weekly:` cases of `tests/test_render_schedule.bats` run
- **THEN** they pass unchanged

#### Scenario: Not installed
- **WHEN** `instantiate.sh --cron-every 15` runs with a stub `crontab` on PATH
- **THEN** the stub is never called, `loop/cron-run.sh` and `loop/cron.env` exist, and the printed text carries the line and the command that adds it

#### Scenario: One line per repo
- **WHEN** two repos are cut with `--cron-every`
- **THEN** each prints its own line and has its own `loop/`, lock and log, so the runs may overlap across repos and never within one

#### Scenario: No option, no cron output
- **WHEN** `instantiate.sh` runs without `--cron-every`
- **THEN** no "Cron" section is printed and `loop/cron.env` is not written

### Requirement: Installation is gated (D11), now lifted
The target poll is every 15 minutes. The first draft held the cron line uninstalled, and the interval at 60 minutes or more, until backoff and stale-lock handling existed. Both are built (see `loop-runner`), so the 60-minute floor and the "do not install until B3 passes" wording are gone from the pattern README and from `instantiate.sh` output. The documentation SHALL still state that, before installing, the printed line's command must have been observed under `env -i HOME=$HOME PATH=/usr/bin:/bin sh -c '...'` to authenticate `gh` and `claude` on that machine. The poison-issue rule (three infra failures on one issue block it) is NOT built; until it is, a repeatedly failing issue is retried once per backoff window, at most every 6 hours.

#### Scenario: README states it
- **WHEN** the pattern README's "Unattended" section is read
- **THEN** it contains the stripped-environment check, says nothing is installed for the operator, and says the poison-issue rule is not built yet
