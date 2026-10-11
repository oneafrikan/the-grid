#!/usr/bin/env bash
# hooks/scripts/instincts-capture-prompt.sh — launched by hooks/run.sh; opt-in through `learning: on`
# in .grid/project.yaml (see docs/instincts.md). One line: hand the hook payload on stdin
# to scripts/instincts.sh capture, which owns all the logic (flag re-check, scrubbing, storage).
# The repo root comes from this file's own path, so nothing absolute is stored anywhere.
exec bash "$(cd "$(dirname "$0")/../.." && pwd -P)/scripts/instincts.sh" capture
