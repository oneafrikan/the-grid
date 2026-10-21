# Tasks

All groups: run from the repo root on a branch cut from `next` after `charter-files` and `knowledge-signals` are merged; verify with `bash scripts/gate.sh` unless stated. Tests use temp dirs and never touch the real `~/.claude`.

**Setup (a fresh worktree has neither bats nor the venv, and venv-gated tests skip silently without it):** `git submodule update --init tests/lib/bats-core` and `python3 -m venv agent-factory/.venv && agent-factory/.venv/bin/pip install -r agent-factory/requirements.txt` (same as CI).

**Docs index:** the front-door change requires every new tracked script, top-level directory or `docs/*.md` to appear in `docs/architecture.md` in the same PR (`tests/test_front_door.bats` case 2.6). This change adds no script under `scripts/`, no top-level directory and no `docs/*.md`; the one new tracked runtime file is `hooks/scripts/epistemic-stop.sh` (task 3.7). Nothing here assumes the issue loop exists. Every spec file is a SHALL requirement with a scenario; each task below names the scenario it satisfies.

## 1. map.py lint (map-lint)

Depends on: A1 (`scripts/map.py`, `map` gate check, `GUARDRAILS.md` format; this group changes its `--check` contract, see the proposal's Modified Capabilities) and A2 (`scripts/knowledge.py`, its project-template mirror, ledger, entry format) merged. Files: `scripts/map.py`, `tests/test_map_lint.bats`, `tests/fixtures/map-lint/` (small trees).

- [ ] 1.1 Read A2's merged `knowledge.py` and specs. Write into the PR a table `rule -> where it lives` for every requirement in `specs/map-lint/spec.md` (A2 function name or `map.py`). A rule found in both is deleted from `map.py`. If A2's `check` already prints codes, reuse them; add only missing ones. If `knowledge.py` exposes no importable tree walker, add the smallest one to `knowledge.py` in this PR (and say so); do not copy its logic into `map.py`. Verify: `grep -nE 're\.compile|hashlib|STOP_WORDS' scripts/map.py` shows no frontmatter, hash or warrant rule.
- [ ] 1.2 In `map.py --check`, after the drift check: `import knowledge` from `scripts/` (path from `__file__`), run the lint, print findings sorted as `E_<CODE> path[:line]: message`, exit 0/1/2 per spec. When `scripts/knowledge.py` is missing or neither `signals/` nor `knowledge/` exists: one notice line, drift check only. Comment each rule with the reason it exists (what goes wrong without it).
- [ ] 1.3 Stage enum (six values for entries and signals), stage vs directory (`canonical` <-> `canon/`), warrant and ceiling re-derivation (Decided 4), ledger consistency (Decided 3), and `E_EDITED` through A2's history check (also covering index/working-tree modification; if A2's routine only reads history, add the `git diff --name-status HEAD -- signals/` variant to `knowledge.py`). No content-hash comparison.
- [ ] 1.4 Address checks (Decided 5) over `supersedes`, `superseded_by`, `contradicts`, `confirms`, `guardrail`; `K-` form via A2's resolver; `GUARDRAILS#G<n>` against `GUARDRAILS.md` rule IDs (A1 format `- G<n>: ...`); generic `path[#slug]` with GitHub slugs and repeat suffixes; reject `signals/`, leading `/`, `..`.
- [ ] 1.5 `tests/test_map_lint.bats`: one case per scenario in `specs/map-lint/spec.md`, each on a fixture tree copied to a temp dir; one case lints A2's signal template and the examples in `signals/README.md` and `knowledge/README.md` (must be clean); one case runs with a `PATH` holding only system `python3`; one hand-filed signal with an arbitrary `hash6` is clean; one case where a commit adds a signal and another moves it to `done/` with its ledger line leaves `--check` green with MAP.md untouched; one case outside a git repo prints the notice; one asserts `git status --porcelain` unchanged after `--check`; one runs `--check` on the real repo (exit 0).
- Acceptance: all `map-lint` scenarios except the mirror and gate ones pass.
- Verify: `tests/lib/bats-core/bin/bats tests/test_map_lint.bats && bash scripts/gate.sh`

## 2. Gate proof (map-lint)

Depends on: 1. Files: `tests/test_gate.bats`, `CLAUDE.md`.

- [ ] 2.1 Confirm A2's `knowledge.py` mirror and `cmp` test exist in `project-factory/templates/_common/scripts/`; a temp cut project's `python3 scripts/map.py --check` exits 0 and its lint runs. If the mirror is missing, stop and report (A2 owns it; do not add one here).
- [ ] 2.2 Do NOT add a gate check. Confirm A1's `map` check exists in `scripts/gate.sh`; if it does not, stop and report (the brief and A1 disagree). `tests/test_gate.bats`: case with a bad-stage signal in a temp `GRID_DIR` fails with `map` in the failed list; case with `python3` hidden shows `map` in the skipped list. Confirm `.github/workflows/tests.yml` does not list `map` in `GRID_GATE_EXPECT_SKIPPED`. Project templates get the pre-commit gate only; add no CI job.
- [ ] 2.3 `CLAUDE.md` Key files: extend A1's `map.py` line with what `--check` now lints and the exit codes (one line).
- Acceptance: the feature-detection and gate scenarios in `map-lint` pass.
- Verify: `bash scripts/gate.sh`

## 3. Stop hook (completion-warrant-hook)

Depends on: nothing from 1-2. Files: `hooks/scripts/epistemic-stop.sh`, `hooks/catalogue.json`, `hooks/README.md`, `tests/test_epistemic_stop.bats`, `tests/test_hooks.bats`.

- [x] 3.1 HUMAN-observable probe first (UNVERIFIED facts, Decided 10): with the real `claude`, in a scratch dir, register a Stop hook that dumps its stdin JSON to a file and exits 2 once; record (a) the payload field names (`stop_hook_active`, last-message field if any, `transcript_path`), (b) whether exit 2 sends stderr to the model and continues the turn, (c) that the second stop has `stop_hook_active: true`. Paste the observed JSON into the PR. If any assumption fails, stop and report; do not write the script on a guess. Same style as `scripts/auto-handoff-preflight.sh` (capped, `timeout`); worst-case spend stated first.
  - Probe for 3.1: `bash scripts/epistemic-stop-probe.sh` prints the worst-case spend (USD 0.10, one capped `claude -p` call) and the plan; `bash scripts/epistemic-stop-probe.sh --yes` runs it against the real `claude` and prints PASS / FAIL / INCONCLUSIVE for (a), (b) and (c), plus the directory holding the captured JSON (`${GRID_STATE_DIR:-~/.grid}/probes/epistemic-stop-<timestamp>/`) to paste into the PR. Exit 0 only if all three PASS. Run by the operator on 2026-10-21 with claude 2.1.x; observed: the Stop stdin JSON keys are `session_id`, `transcript_path`, `cwd`, `prompt_id`, `permission_mode`, `effort`, `hook_event_name`, `stop_hook_active`, `last_assistant_message` (a string, so the last message is in the payload), `background_tasks`, `session_crons`; `transcript_path` is present and the file exists; a Stop hook that exits 2 with a one-line stderr reason makes the model receive the reason and the turn continues (a second assistant message, `num_turns` 2); the second Stop payload in that turn has `stop_hook_active: true` (the first has false).
- [x] 3.2 Write `epistemic-stop.sh` per Decided 10: source `hooks/lib/common.sh`, `grid_require_jq open`, read stdin, loop guard, last message from the payload field `last_assistant_message`, else (only when the key is absent) a bounded 64 KiB tail of the transcript, claim regex, whole-word case-sensitive `RAN|READ|UNTESTED` test, exit 2 with the one-line reason. Comment each decision and the false-positive trade-off. Bash 3.2-compatible (no `${var,,}`, no mapfile). shellcheck clean.
- [x] 3.3 `tests/test_epistemic_stop.bats` (run through `hooks/run.sh` with a stub payload): one case per scenario in `specs/completion-warrant-hook/spec.md`, plus a fixture list of 10 claim messages and 10 non-claim messages (chatty "I'm done thinking about X?" questions, a code review with the word "complete" in a quoted snippet) with the observed fire rate written in a comment, so a regex change shows up in review.
- [x] 3.4 `hooks/catalogue.json`: add the `epistemic-stop` entry (profile `strict`, `fail: open`, timeout 5, `model_cost: false`, `cost` text: "0 tokens to run; about 60 ms per stop; a block adds one model turn, once per turn"). `tests/test_hooks.bats:222-226`: change the length to 8 and exclude `event == "Stop"` from the PreToolUse/Bash/closed assertion; add an assertion for the new entry. Check `tests/test_deploy_hooks.bats:278` still passes (`on_failure` stays absent).
- [x] 3.5 `hooks/README.md`: hooks table row, profile table (`strict` adds `epistemic-stop`), one paragraph: advisory, bypassable, off unless a project sets `profile: strict`, a block costs one model turn.
- [x] 3.6 `deploy_hooks.py --check` and `--list` against the real catalogue exit 0; emit `--profile strict` into a temp project and confirm the `Stop` handler is present and absent under `standard`.
- [x] 3.7 `docs/architecture.md`: add `hooks/scripts/epistemic-stop.sh` (one line) wherever that file lists the other hook scripts; if it lists `hooks/` only as a directory, add nothing and say so in the PR. Nothing added: hooks/ is listed as a directory only. `tests/test_front_door.bats` stays green. No project is switched to `strict` in this change; the one-project trial is deferred.
- Acceptance: all `completion-warrant-hook` scenarios pass; no model call anywhere in the hook.
- Verify: `tests/lib/bats-core/bin/bats tests/test_epistemic_stop.bats tests/test_hooks.bats tests/test_deploy_hooks.bats && bash scripts/gate.sh`

## 4. Canon protection (canon-protection)

Depends on: A2 (`knowledge/canon/`, `knowledge.py apply`). Files: `.github/CODEOWNERS`, `.github/pull_request_template.md`, `CLAUDE.md`, `tests/test_canon_protection.bats`.

- [ ] 4.1 VERIFY current protection and quote it in the PR: `ls -a .github; find . -iname CODEOWNERS -not -path './repos/*'`; `gh api repos/oneafrikan/the-grid/rulesets`; `gh api repos/oneafrikan/the-grid/rulesets/<id>`; `gh api repos/oneafrikan/the-grid/branches/{next,main}/protection`. At spec time (2026-10-18): no CODEOWNERS; no classic protection on either branch; ruleset `next-needs-pr` on `next` (PR required, 0 approvals, no code-owner review, admin bypass always); nothing on `main`. Report any difference.
- [ ] 4.2 Add `.github/CODEOWNERS` with only `knowledge/canon/ @<operator-handle>` and a comment on why. Handle taken from `git remote get-url origin`'s owner after confirming with the operator; in a business repo it is that operator's handle.
- [ ] 4.3 PR template: add the checkbox "No path under `knowledge/canon/` changed, or a human is merging this: `git diff --name-only origin/next...HEAD -- knowledge/canon` (non-empty output = human merges)".
- [ ] 4.4 `CLAUDE.md`: one imperative block per Decided 8 (never merged under the standing approval; a human merges; QA/merger runs the command before `gh pr merge`). Keep it under 6 lines.
- [ ] 4.5 Test the direct-write ban (spec `canon-protection`): in `tests/test_canon_protection.bats`, run `knowledge.py apply` without `--proposal-for` on a fixture plan holding a `canonical` claim and assert `knowledge/canon/` unchanged and the claim reported escalated; add a static grep that every write to a `canon` path in `scripts/knowledge.py` is inside the `--proposal-for` branch. If A2's code fails this, report it as a finding; do not patch A2's code silently.
- [ ] 4.6 Do not touch rulesets or branch protection (operator decision). The PR description records only the read-only results of 4.1.
- [ ] 4.7 Test (same file as 4.5): grep CODEOWNERS for the canon line and nothing else, `CLAUDE.md` for `knowledge/canon/` + "never merged" + "human", and the PR template for the diff command.
- Acceptance: all `canon-protection` scenarios pass; first real canon PR shows the owner as requested reviewer (confirm by hand, then note it in the PR that adds the first canon entry).
- Verify: `bash scripts/gate.sh`

## 5. Role evals (role-evals)

Depends on: nothing. Files: `evals/cases/researcher/*.yaml`, `evals/cases/librarian/*.yaml`.

- [ ] 5.1 Write the six cases from the design table. Header comment on each: the role rule pinned (quote the sentence and file), `Baseline unknown`, date. `finding: "#0"`, `expect_today: unknown`, `runs` default. Prompts follow the existing style (scenario, then "Start your reply with exactly one line: ..."); no hints (spec). Put the passing option first in at most 2 of 6.
- [ ] 5.2 Verify: `agent-factory/.venv/bin/python agent-factory/run_evals.py --validate` (0 problems), `--list --role researcher`, `--dry-run --role researcher` (3 cases, worst case $2.25), same for `librarian`; `--changed` with a one-file range selects the right role.
- [ ] 5.3 HUMAN: approve spend, then `GRID_EVALS=1 agent-factory/.venv/bin/python agent-factory/run_evals.py --role researcher --yes` and the same for `librarian` (not both at once). Results land in git-ignored `evals/results/`. Update each case's `expect_today` and header with the measured pass rate and date; a FLIPPING case stays `unknown`. An errored run is re-run, not recorded.
- [ ] 5.4 If a case fails 0/3 on a rule the role plainly states, report it as a finding for the operator; do not edit the role in this change.
- Acceptance: all `role-evals` scenarios pass; `tests/test_eval_cases.bats` green (it skips without the venv: run Setup first and confirm the tests did not skip).
- Verify: `tests/lib/bats-core/bin/bats tests/test_eval_cases.bats tests/test_eval_selection.bats && bash scripts/gate.sh`
