## Why

Four cheap workflow gaps show up when comparing the-grid with ECC and gstack. Behaviour modes need hand-typed prompts. Orchestrators ask the human open-ended questions that cannot be answered by number. Release gates rely on one reviewer. Paid evals are all-or-nothing. Golden-output tests for the compiler (#23) are also still missing, and they are what make the decision-brief change (and the later multi-harness and plugin work) safe to ship.

## What Changes

- Add a `GRID_USER_CONFIG` env override to `compose.py` and a tracked, neutral `agent-factory/user.public.yaml`, so composed output can be made machine-independent. This is the only place the override is introduced; `multi-harness` and `plugin-marketplace` depend on it.
- Add golden-output conformance tests for `compose.py` (closes #23): fixture roles and config, byte-compared goldens per target, one script to check or update them, run in CI once `foundations` has the CI venv in place.
- Add a numbered decision-brief fragment (`agent-factory/_core/DECISION_BRIEF.md`) that `compose.py` appends to every orchestrator role, full and lean profiles, plus a lint check on it.
- `deploy.py --profile full` renders the IDENTITY nameplate from `user.public.yaml` by default; `--identity PATH` opts in to another identity file.
- Add a two-reviewer release gate to the `tech-lead` operating procedure: `qa-engineer` and `security-reviewer` review independently and both must PASS, with a capped fix loop.
- Add `--changed <git-range>` to `run_evals.py` and an `evals/touchfiles.yaml` map, so paid evals run only for roles whose files changed, still opt-in and capped.
- Add three opt-in context-mode files (`contexts/dev.md`, `research.md`, `review.md`) and a sourced bash/zsh alias snippet: `claude-dev`, `claude-research`, `claude-review`, each `claude --append-system-prompt-file <file>`. Use case: switching working mode per session.

## Capabilities

### New Capabilities

- `compose-conformance`: golden-output tests that pin what each compose target emits, and the machine-independent identity config they and full-profile deploys use.
- `decision-briefs`: one numbered decision-brief format shared by all orchestrator roles.
- `two-reviewer-gate`: independent qa plus security review, both must pass.
- `eval-selection`: choose paid eval roles from a git diff.
- `context-modes`: opt-in dev/research/review context files and shell aliases.

### Modified Capabilities

None. `openspec/specs/` is empty; these are all new.

## Impact

- New: `agent-factory/user.public.yaml`, `scripts/compose-goldens.sh`, `tests/fixtures/compose/`, `agent-factory/_core/DECISION_BRIEF.md`, `evals/touchfiles.yaml`, `contexts/`, five bats files, three eval cases.
- Edited: `agent-factory/compose.py` (user-config env override, brief append, brief lint), `agent-factory/deploy.py` (`--identity`, neutral default for full profile), `agent-factory/run_evals.py`, `agent-factory/roles/tech-lead/SKILL.md`, `agent-factory/docs/role-authoring.md`, `agent-factory/README.md`, `evals/README.md`, `scripts/gate.sh` (shellcheck covers `contexts/*.sh`), `CLAUDE.md`, `USAGE.md`.
- Composed output (`agent-factory/projects/`, git-ignored) and per-project deploys (`deploy.py` locks) go stale for orchestrators; machines recompose after pulling.
- Token cost: contexts are opt-in per session; briefs add about 1.2 KB to each orchestrator prompt. No model calls are added to the gate or CI.

## Non-goals

- Installing the aliases into any rc file or dev-env; the snippet's header shows the line to add, a human adds it.
- Aliases for harnesses other than Claude Code (that is `multi-harness`).
- Calling `claude` from the gate or CI; `--changed` only selects, and real runs stay `GRID_EVALS=1` plus `--yes`.
- Wiring `--changed` into the issue loop or a GitHub workflow (that is `loops`).
- Decision briefs for specialist roles, a brief tool call (AskUserQuestion), per-option completeness scores, or session-log capture of briefs.
- A two-reviewer gate for `ceo-orchestrator`, `growth-hacker` or `finance-manager`, and a new top-level `two-reviewer-gate` skill.
- Lean-profile goldens (`tests/test_deploy.bats` covers lean) and goldens for targets that do not exist yet (new targets add themselves to the same script).
- Opt-out switches for the brief or per-machine context customisation.
