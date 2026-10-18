#!/usr/bin/env bash
# hooks/scripts/instincts-inject.sh — launched by hooks/run.sh; opt-in through `learning: on`
# in .grid/project.yaml (see docs/instincts.md). Hands the hook payload on stdin to
# scripts/instincts.sh inject, which owns all the logic (flag re-check, scrubbing, storage).
# The repo root comes from this file's own path, so nothing absolute is stored anywhere.
# A SessionStart hook must never fail or print noise: stderr is dropped and the status is
# always 0, even when bash, dirname or python3 are missing from PATH.
d="${BASH_SOURCE[0]%/*}"
[ "$d" = "${BASH_SOURCE[0]}" ] && d=.
bash "$d/../../scripts/instincts.sh" inject 2>/dev/null
exit 0
