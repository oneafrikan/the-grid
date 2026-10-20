#!/usr/bin/env bash
# loop/cron-run.sh — what a cron line runs: pin the environment, then hand over to the runner.
#
# cron starts jobs with a bare PATH (/usr/bin:/bin) and no login shell, so `gh`, `claude`, `jq`
# and `timeout` may not resolve. The installer (scripts/instantiate.sh --cron-every) resolves
# those directories at install time and writes them to loop/cron.env (machine-local, gitignored,
# never tracked). This script sources it, cds into the repo and `exec`s the runner, so the cron
# child IS the runner. Overlap guard: the runner's own lock (a second tick exits 0 "busy");
# different repos each have their own lock and run concurrently.
#
# Bash 3.2 compatible.
set -u

LOOP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd -P)"
cd "$LOOP_DIR/.." || exit 1

# shellcheck disable=SC1091
[ ! -f "$LOOP_DIR/cron.env" ] || . "$LOOP_DIR/cron.env"

exec bash "$LOOP_DIR/run-issue.sh"
