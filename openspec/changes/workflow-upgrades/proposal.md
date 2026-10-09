## Why

Four cheap workflow gaps show up when comparing the-grid with ECC and gstack. Behaviour modes need hand-typed prompts. Orchestrators ask the human open-ended questions that cannot be answered by number. Release gates rely on one reviewer. Paid evals are all-or-nothing. Golden-output tests for the compiler (#23) are also still missing, and they are what make the second and third items safe to change.

## What Changes

- Add three opt-in context-mode files (`contexts/dev.md`, `research.md`, `review.md`) and a bash/zsh alias snippet: `claude-dev`, `claude-research`, `claude-review`, each `claude --append-system-prompt-file <file>`.
- Add a printed, non-installing hint script that tells the user which line to add to their shell rc.
- Add golden-output conformance tests for `compose.py` (issue #23): fixture roles and config, byte-compared goldens per target, one script to check or update them.
- Add a numbered decision-brief fragment (`agent-factory/_core/DECISION_BRIEF.md`) that `compose.py` appends to every orchestrator role, full and lean profiles, plus a lint check on it.
- Add a two-reviewer release gate to the `tech-lead` operating procedure: `qa-engineer` and `security-reviewer` review independently and both must PASS, with a capped fix loop.
- Add `--changed <git-range>` to `run_evals.py` and a `evals/touchfiles.yaml` map, so paid evals run only for roles whose files changed, still opt-in and capped.

## Capabilities

### New Capabilities

- `context-modes`: opt-in dev/research/review context files and shell aliases.
- `compose-conformance`: golden-output tests that pin what each compose target emits.
- `decision-briefs`: one numbered decision-brief format shared by all orchestrator roles.
- `two-reviewer-gate`: independent qa plus security review, both must pass.
- `eval-selection`: choose paid eval roles from a git diff.

### Modified Capabilities

None. `openspec/specs/` is empty; these are all new.

## Impact

- New: `contexts/`, `scripts/contexts-hint.sh`, `scripts/compose-goldens.sh`, `tests/fixtures/compose/`, `evals/touchfiles.yaml`, `agent-factory/_core/DECISION_BRIEF.md`, five bats files, three eval cases.
- Edited: `agent-factory/compose.py` (user-config env override, brief append, brief lint), `agent-factory/run_evals.py`, `agent-factory/roles/tech-lead/SKILL.md`, `agent-factory/docs/role-authoring.md`, `evals/README.md`, `scripts/gate.sh` (shellcheck covers `contexts/*.sh`), `CLAUDE.md`, `USAGE.md`.
- Composed output (`agent-factory/projects/`, git-ignored) and per-project deploys (`deploy.py` locks) go stale for orchestrators; machines recompose after pulling.
- Token cost: contexts and briefs are opt-in or orchestrator-only; briefs add about 1.2 KB to each of 4 public orchestrator prompts. No model calls are added to the gate.

## Non-goals

- Installing the aliases into any rc file or into dev-env; the hint script only prints.
- Aliases for harnesses other than Claude Code (multi-harness is workstream 11).
- Calling `claude` from the gate or CI; `--changed` only selects, and real runs stay `GRID_EVALS=1` plus `--yes`.
- Wiring `--changed` into the issue loop or a GitHub workflow (workstream 10 and 1).
- Decision briefs for specialist roles, a brief tool call (AskUserQuestion), per-option completeness scores, or session-log capture of briefs.
- A two-reviewer gate for `ceo-orchestrator`, `growth-hacker` or `finance-manager`, and a new top-level `two-reviewer-gate` skill.
- Lean-profile goldens (deploy.py has its own tests) and a `--target` for any emitter that does not exist yet.
- Opt-out switches for the brief (`decision_brief: false`) or per-machine context customisation.
