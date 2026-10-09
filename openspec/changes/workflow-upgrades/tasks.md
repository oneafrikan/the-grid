# Tasks

Each group is one PR on `next`. Default verify command: `bash scripts/gate.sh`. Tests never touch the real `~/.claude`; they use temp dirs and the existing `GRID_DIR` / `SKILLS_DIR` / `AGENTS_DIR` / `GRID_PRIVATE_ROLES_DIR` overrides. Bats tests that need Python skip when `agent-factory/.venv` is absent, as existing tests do.

## 1. Context modes and alias snippet

Files: `contexts/dev.md`, `contexts/research.md`, `contexts/review.md`, `contexts/aliases.sh`, `scripts/contexts-hint.sh`, `tests/test_contexts.bats`, `scripts/gate.sh` (add `contexts/*.sh` to the shellcheck line), `CLAUDE.md` (one "Key files" bullet), `USAGE.md` (short "Context modes" section before "Growing what's wired").

- [ ] 1.1 Write the three context files (mode, focus, behaviours, tools to favour, output shape), each at most 1200 bytes, harness-neutral, no personal data. Model structure on `repos/ecc/contexts/` but in the-grid's own words; `review.md` says to hand release-gate reviews to `qa-engineer` and `security-reviewer` if available.
- [ ] 1.2 Write `contexts/aliases.sh` per design section 1: starts with `# shellcheck shell=bash`, header comment with usage, resolves its directory (`GRID_DIR` first, then `BASH_SOURCE` or zsh `%x`, then `$HOME/.the-grid`), defines `claude-dev`, `claude-research`, `claude-review` only if the file exists. Alias bodies use `--append-system-prompt-file` and the comment explains why not `--system-prompt-file`.
- [ ] 1.3 Write `scripts/contexts-hint.sh` (bash, `set -euo pipefail`): prints the exact line to add to `~/.zshrc` or `~/.bashrc` using the script's own repo path. It writes nothing anywhere.
- [ ] 1.4 Write `tests/test_contexts.bats` covering: each context file exists and is at most 1200 bytes; in bash with `shopt -s expand_aliases`, sourcing `aliases.sh` defines the three aliases, each containing `--append-system-prompt-file` and the right file path; with a stub `claude` first on `PATH`, `claude-dev foo` passes `--append-system-prompt-file <dev.md> foo` (argv captured by the stub); the same alias check under `zsh -c` (skip if zsh is absent); `GRID_DIR` override is honoured; `contexts-hint.sh` prints a line containing `aliases.sh` and leaves a temp `HOME` with no files created.
- [ ] 1.5 Extend the shellcheck line in `scripts/gate.sh` to include `contexts/*.sh`; update its header comment.

Acceptance: `tests/lib/bats-core/bin/bats tests/test_contexts.bats` passes. Verify: `bash scripts/gate.sh`.

## 2. Compose golden-output conformance tests (closes #23)

Files: `agent-factory/compose.py` (env override only), `tests/fixtures/compose/{fixture.yaml,user.yaml,roles/**,golden/**}`, `scripts/compose-goldens.sh`, `tests/test_compose_golden.bats`, `agent-factory/README.md` (one paragraph on the goldens and the update command).

- [ ] 2.1 In `compose.py`, make `USER_CONFIG_PATH` honour `GRID_USER_CONFIG` (non-empty path replaces `agent-factory/user.yaml`). Comment why: fixtures must not read the personal file. No other behaviour change.
- [ ] 2.2 Create the fixture config and five fixture roles exactly as in design section 2 (role names `ceo-orchestrator`, `tech-lead`, `growth-hacker`, `product-manager`, `fx-eng`; each with `role.yaml`, `SOUL.md`, `SKILL.md`, `AGENTS.md`; the two delegating orchestrators carry `{{ROSTER_TABLE}}`). Add `tests/fixtures/compose/user.yaml` with operator `Fixture Operator`, machine `fixture-host`, channels `none`. Comment in `fixture.yaml` that these roles intentionally shadow real role names.
- [ ] 2.3 Write `scripts/compose-goldens.sh` (bash, shellcheck-clean, comments throughout): `--check` (default) renders each of `claude-code`, `openclaw`, `paperclip`, `openclaw-native` with `GRID_PRIVATE_ROLES_DIR` and `GRID_USER_CONFIG` pointed at the fixtures into a temp dir and `diff -r` against `${GOLDEN_DIR:-tests/fixtures/compose/golden}`; `--update` replaces the golden tree. Uses `agent-factory/.venv/bin/python`; exits 0 with a "venv absent, skipped" notice if it is missing. Idempotent: a second `--update` changes nothing.
- [ ] 2.4 Run `--update` once and commit the goldens. Read through the generated files: no hostname, date, absolute path or `/Users/` string may appear (grep for them; if one does, fix the leak, do not commit it).
- [ ] 2.5 Write `tests/test_compose_golden.bats`: (a) `--check` passes on the committed goldens; (b) `--update` into a temp `GOLDEN_DIR` twice yields byte-identical trees; (c) negative case: copy the goldens to a temp dir, append a line to one file, run `--check` with `GOLDEN_DIR` pointing there, expect exit 1 and the file named in the output; (d) negative case: delete one golden file from a temp copy and `--check` exits 1. Mutating an expected file is the same drift an emitter edit causes. Skips without the venv.

Acceptance: all four tests above pass; real `agent-factory/user.yaml` is never read (test sets `GRID_USER_CONFIG`). Verify: `bash scripts/gate.sh`.

## 3. Decision-brief fragment for orchestrators

Depends on: 2 (this change alters orchestrator output; goldens must be updated in the same PR).

Files: `agent-factory/_core/DECISION_BRIEF.md`, `agent-factory/compose.py`, `agent-factory/docs/role-authoring.md`, `tests/fixtures/compose/golden/**` (regenerated), `tests/test_decision_brief.bats`, `evals/cases/ceo-orchestrator/decision-brief-format.yaml`.

- [ ] 3.1 Create `_core/DECISION_BRIEF.md` with the exact text in design section 3 (HTML-comment header explaining purpose; the comment is stripped on render).
- [ ] 3.2 In `compose.py`, add `render_decision_brief()` (reads the fragment, strips comments) and append it, for `is_orchestrator(role)` only: in `render_agent` after `inject_roster` and before the stack overlay, and in `render_lean_body` after the role's AGENTS sections and before the stack overlay. Specialists unchanged. Update the lean-profile comment block to list it as a kept addition.
- [ ] 3.3 Add `lint_decision_brief()` to `--lint-roles`: `E_DECISION_BRIEF` if the file is missing, larger than 1500 bytes, or lacks the string `D<N>`. Include it in the problem count.
- [ ] 3.4 In `role-authoring.md` (Orchestrator variant), add one bullet: the decision-brief section is appended automatically from `_core/DECISION_BRIEF.md`; do not restate it in `AGENTS.md`; the 5120-byte cap counts the role file only.
- [ ] 3.5 Run `bash scripts/compose-goldens.sh --update`; review that only orchestrator trees changed and that the `openclaw-native` diff is explained in the PR description (it may or may not change).
- [ ] 3.6 Write `tests/test_decision_brief.bats`: fixture-composed orchestrator output contains `## Decision briefs`, specialist output does not; a real lean deploy (`deploy.py <tmp> --roles tech-lead,qa-engineer --profile lean`) contains it for `tech-lead` only; `compose.py --lint-roles` exits 0; an oversize fragment makes the lint report `E_DECISION_BRIEF` (run via `python -c` with `compose.CORE_DIR` pointed at a temp copy); `wc -c` of `roles/tech-lead/AGENTS.md` is unchanged from the committed value.
- [ ] 3.7 Add the eval case: a `ceo-orchestrator` scenario with two real options (for example "ship the migration this week or hold until the audit finishes") asking it to put the decision to the human; `must_match` a `D\d+` label, at least two lettered options, and the word `recommend`; no hint about the format in the prompt. `finding: "#0"`, `expect_today: unknown`. Validate only, do not run it.
- [ ] 3.8 Recompose locally if this machine has composed output (`compose.py examples/{core,grid,finance-desk}.yaml --target claude-code`); `projects/` is git-ignored, nothing to commit.

Acceptance: `bats tests/test_decision_brief.bats` and `bats tests/test_compose_golden.bats` pass. Verify: `bash scripts/gate.sh`.

## 4. Two-reviewer release gate in tech-lead

Files: `agent-factory/roles/tech-lead/SKILL.md`, `evals/cases/tech-lead/gate-qa-pass-security-missing.yaml`, `evals/cases/tech-lead/gate-one-reviewer-blocks.yaml`, `tests/test_two_reviewer_gate.bats`.

- [ ] 4.1 Replace "Step 6 - QA handoff" in `tech-lead/SKILL.md` with "Step 6 - Release gate: two independent reviewers", using the six steps in design section 4 and keeping the existing QA handoff code block as the shared packet. Do not edit `AGENTS.md` (5113 of 5120 bytes). Exempt docs-only and draft work in one line.
- [ ] 4.2 Add eval `gate-qa-pass-security-missing`: qa-engineer's report is a clean PASS with command and output, the PR touches a login handler, no security review has run; ask for a first line `GATE: PASSED`, `GATE: PENDING` or `GATE: BLOCKED`. `must_match`: `^GATE:\s*PENDING` and `security-reviewer`. The prompt must not mention security review or hint at the gate procedure.
- [ ] 4.3 Add eval `gate-one-reviewer-blocks`: security-reviewer reports a High finding with location and attack path, qa-engineer reports PASS. `must_match`: `^GATE:\s*BLOCKED`; `must_not_match`: `GATE:\s*PASSED`. Both cases `finding: "#0"`, `expect_today: unknown`. Validate only, do not run.
- [ ] 4.4 Write `tests/test_two_reviewer_gate.bats`: `tech-lead/SKILL.md` names both `qa-engineer` and `security-reviewer`, says both must pass, and states the 3-round cap; a lean deploy of `tech-lead` into a temp project contains the section text; `compose.py --lint-roles` exits 0; `run_evals.py --validate` exits 0.

Acceptance: `bats tests/test_two_reviewer_gate.bats` passes. Verify: `bash scripts/gate.sh`.

## 5. Eval selection by touched roles (`--changed`)

Files: `agent-factory/run_evals.py`, `evals/touchfiles.yaml`, `evals/README.md`, `tests/test_eval_selection.bats`.

- [ ] 5.1 Create `evals/touchfiles.yaml` exactly as in design section 5.
- [ ] 5.2 In `run_evals.py` add `--repo` (default repo root), `--changed RANGE`, `--max-total USD` (default 5.00). Implement: `git -C <repo> diff --name-only -z --no-renames RANGE` (nonzero exit prints `E_RANGE: ...` to stderr, exit 2); built-in mapping for `agent-factory/roles/<role>/` and `evals/cases/<role>/`; then touchfile rules, first match wins per file, `fnmatch.fnmatchcase`, `roles` of `all` / `orchestrators` (via `compose.is_orchestrator`) / list. Intersect with roles that have cases and with `--role` / `--case`. Print `changed: N file(s); selected roles: a, b; no cases: c`. Nothing selected: print `no eval-relevant changes`, exit 0, no `GRID_EVALS` needed. With `--changed`, refuse (exit 2, before any spend) when runs x `--budget` exceeds `--max-total`, naming `--role` and `--max-total` as the ways out. Update the module docstring usage block.
- [ ] 5.3 Extend `--validate` to check `touchfiles.yaml`: only `rules` key; each rule has non-empty `paths` list and valid `roles`; named roles exist; reports as `E_CASE: touchfiles.yaml: ...` so the gate's existing call covers it.
- [ ] 5.4 Update `evals/README.md`: `--changed` usage, the touchfile map, the cap, and one line saying the issue loop or CI should call `--changed origin/next...HEAD --dry-run` first.
- [ ] 5.5 Write `tests/test_eval_selection.bats` using a temp git repo (two commits; `evals/touchfiles.yaml` copied from the real one) passed via `--repo`, with `--dry-run` or a stub `GRID_CLAUDE`: changing `agent-factory/roles/qa-engineer/AGENTS.md` selects only `qa-engineer`; changing `evals/cases/tron/x.yaml` selects `tron`; changing `agent-factory/_core/DECISION_BRIEF.md` selects `tech-lead` and `ceo-orchestrator` but not `qa-engineer`; changing `README.md` prints `no eval-relevant changes` and exits 0; changing `agent-factory/compose.py` exits 2 over the default cap and succeeds with `--max-total 50 --dry-run`; a bad range exits 2 with `E_RANGE`; a real stub run for the qa-engineer selection works only with `GRID_EVALS=1` and `--yes` and writes results to a temp `--results-dir`; a touchfile naming a missing role fails `--validate`.

Acceptance: `bats tests/test_eval_selection.bats` and the existing `tests/test_eval_cases.bats` pass. Verify: `bash scripts/gate.sh`.

## 6. HUMAN: read the wording and install the aliases

Depends on: 1, 3.

- [ ] 6.1 HUMAN: read `contexts/{dev,research,review}.md` and `agent-factory/_core/DECISION_BRIEF.md`; edit anything that does not sound right (taste).
- [ ] 6.2 HUMAN: run `bash scripts/contexts-hint.sh` on each machine and add the printed line to the shell rc (or through the dev-env repo's own conventions).
- [ ] 6.3 HUMAN: after pulling, recompose and re-wire on each machine (`compose.py` for the three public configs, then `bash scripts/wire.sh`).

Acceptance: `claude-review` starts a session on each machine. Verify: `type claude-review` in a new shell.
