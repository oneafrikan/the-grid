Grid-wide agent defaults live in `agent-factory/_core/AGENTS_base.md`; this file lists this project's additions only.

## Markdown-only changes

- A markdown-only change (all changed files `*.md`, none generated, none under `knowledge/canon/`, `tests/`, `rules/`, `hooks/`, `evals/`, `project-factory/`, `automation-factory/` or `.github/`) is edited in the main checkout directly on `main`, unless the operator asks for a feature branch.
- No worktree, no submodule init.
- Run the one directly relevant `--check` (for example `python3 scripts/map.py --check`), commit, push to `main`. Do not wait for CI.
- Code, scripts, tests, CI, compose output and `repos/*` pointers keep the full `bash scripts/gate.sh` and a PR.
- `knowledge/canon/` is still merged by a human (`GUARDRAILS#G7`).

## Working rules

- Parallel workstreams use a feature branch and a PR. When the operator hasn't said, ask once: "PR or straight to main?". Push straight to main only when the operator says so. Removals, text and config-only edits need no worktree, no full gate and no waiting on CI; run only the one directly relevant `--check`. The bats suite runs nightly, on release tags and on demand, never per branch.
