## Purpose

Start a loop run when there is work and nothing is running, without anyone typing. Use case: the operator's server or laptop, a cron line the operator installs by hand, working the `ready-for-agent` backlog gh-triage prepared. The first run is started by hand in B1; the waker is B2. It starts runs; it never decides what is in the queue, and never installs itself.

## ADDED Requirements

### Requirement: wake.sh starts a run only when needed
`loop/wake.sh` SHALL, in this order: set PATH as `run-issue.sh` does; read `loop/loop.conf`; exit 0 silently if the lock is held by a live run; (once B3 exists) exit 0 with one log line if a `backoff` window is open; count open issues carrying `ISSUE_LABEL` with `gh issue list --label ... --state open --json number`; exit 0 silently if the count is 0; else `exec bash loop/run-issue.sh` so the cron child is the runner. It SHALL NOT pass an issue number, and SHALL NOT start a second runner when a run exists.

#### Scenario: Idle
- **WHEN** no open issue carries `ISSUE_LABEL`
- **THEN** exit 0, no output on stdout or stderr, no run-record line, `run-issue.sh` not started

#### Scenario: Work waiting
- **WHEN** one open issue carries the label and no lock exists
- **THEN** `run-issue.sh` is started once and its pid is the waker's pid (`exec`)

#### Scenario: Run in progress
- **WHEN** the lock is held by a live run
- **THEN** exit 0 without calling `gh`

#### Scenario: Two ticks race
- **WHEN** two wakers start within the same second
- **THEN** one run proceeds and the other `run-issue.sh` exits 0 "busy"

#### Scenario: Gh failure is loud
- **WHEN** `gh issue list` fails (stub)
- **THEN** exit 1 with one stderr line naming the cause (cron will mail or log it), and `run-issue.sh` is not started

### Requirement: Stripped cron environment works
`wake.sh` SHALL NOT depend on a login shell, on `XDG_*` variables, or on a TTY. It SHALL print the missing prerequisite (not authenticated, tool absent) and exit 1 instead of hanging on a prompt.

#### Scenario: Minimal environment
- **WHEN** run as `env -i HOME=$HOME PATH=/usr/bin:/bin bash loop/wake.sh` with stub tools in `$HOME/.local/bin`
- **THEN** it finds them and completes

#### Scenario: Not logged in
- **WHEN** `gh auth status` fails (stub)
- **THEN** exit 1, stderr "gh is not logged in for this user", no `claude` call

### Requirement: Rendered as text the operator installs
`scripts/lib/render-schedule.sh` SHALL accept the schedule form `every:N` (N an integer 1 to 59, minutes) in `render_crontab_line`, producing `*/N * * * *` with the existing `mkdir -p <logdir> && cd <workdir> && <cmd> >> <log> 2>&1` shape. `render_systemd_timer` and `render_launchd_plist` SHALL return 2 for `every:` with a one-line stderr "every: is cron-only". `daily:` and `weekly:` output SHALL be byte-identical to before. `instantiate.sh` (the B2 version) SHALL copy `wake.sh` into `loop/`, print the rendered line (with `--waker-interval N`, default 15) and the instruction to add it with `crontab -e`, and SHALL NOT run `crontab` or write any scheduler file. The printed text SHALL say: do not install until B3 passes; until then use an interval of at least 60 minutes.

#### Scenario: Cron line
- **WHEN** `render_crontab_line every:15 /home/user/.grid/logs/loop.log /home/user/proj bash /home/user/proj/loop/wake.sh` is called
- **THEN** stdout is one line starting `*/15 * * * * mkdir -p /home/user/.grid/logs && cd /home/user/proj && bash /home/user/proj/loop/wake.sh >> /home/user/.grid/logs/loop.log 2>&1`

#### Scenario: Malformed
- **WHEN** the schedule is `every:0`, `every:60`, `every:x` or `every:`
- **THEN** return 2, nothing on stdout

#### Scenario: Regression
- **WHEN** the existing `daily:` and `weekly:` cases of `tests/test_render_schedule.bats` run
- **THEN** they pass unchanged

#### Scenario: Not installed
- **WHEN** `instantiate.sh` runs with a stub `crontab` on PATH
- **THEN** the stub is never called, `loop/wake.sh` exists, and the printed text names the file the operator must edit and carries the do-not-install-until-B3 sentence

#### Scenario: B1 instantiate has no waker
- **WHEN** the B1 version of `instantiate.sh` runs
- **THEN** no `wake.sh` is copied and no cron line is printed

### Requirement: Installation is gated (D11)
The target poll is every 15 minutes. The cron line SHALL stay uninstalled until B3 (backoff and stale lock) has passed its proof; until then the interval SHALL be no shorter than 60 minutes. The documentation SHALL also state that before installing, `env -i HOME=$HOME PATH=/usr/bin:/bin bash loop/wake.sh` must have been observed to authenticate `gh` and `claude` on that machine. B2's own proof SHALL run `wake.sh` by hand and SHALL NOT edit any crontab.

#### Scenario: README states it
- **WHEN** the pattern README's waker section is read
- **THEN** it contains the stripped-environment command, the 15-minute target, the 60-minute floor and "uninstalled until B3 passes"
