Grid-wide agent defaults live in `agent-factory/_core/AGENTS_base.md`; this file lists this project's additions only.

## Markdown-only changes

- A markdown-only change (all changed files `*.md`, none generated, none under `knowledge/canon/` or `tests/`) is edited in the main checkout directly on `main`, unless the operator asks for a feature branch.
- No worktree, no submodule init.
- Run `bash scripts/gate.sh --fast`, commit, push to `main`. Do not wait for CI.
- Code, scripts, tests, CI, compose output and `repos/*` pointers keep the full `bash scripts/gate.sh` and a PR.
- `knowledge/canon/` is still merged by a human (`GUARDRAILS#G7`).
