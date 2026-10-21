# Tasks

Stages: **B1** groups 1-8 (runner, hooks, config, seed, migration, end-to-end proof), **B2** groups 9-10 (waker), **B3** groups 11-12 (backoff, stale lock). Order: 1 -> 2 -> 3 -> 4 -> 5 -> 6 -> 7 -> 8 -> 9 -> 10 -> 11 -> 12. The waker was built as a per-repo cron line (`loop/cron-run.sh`, `instantiate.sh --cron-every N`), not `wake.sh`, and backoff and stale-lock takeover are built, so the 60-minute floor and the "uninstalled until group 12 passes" wording (D11) are dropped from the README and `instantiate.sh` output; the target poll is 15 minutes. The poison-issue rule (11.2) is built. The HUMAN proofs (groups 10 and 12) are not done. Group 13 records what was built beyond this plan.

Preconditions: `next` is merged into `main`; the loop does not exist yet, so every group is built by a worktree agent and merged by the operator. PRs target the integration branch (`next`; UNVERIFIED whether that changes after the merge). No group assumes `loop/` exists in the-grid, and no group touches a live GitHub repo, the real crontab, `~/.claude/settings.json`, or any machine other than a temp dir, except the HUMAN items in groups 8, 10 and 12 (throwaway repo only) and the opt-in e2e test in group 8 (real `claude`, temp local repos, `GRID_E2E=1`).

Docs drift guard: if `front-door` has landed `docs/architecture.md`, every group that adds a tracked file under `scripts/` or `docs/` or a top-level path (here: `scripts/instantiate.sh` in group 4) adds it to that file's tree and docs index in the same PR, else `tests/test_front_door.bats` case 2.6 fails the gate. If the file is absent, say so in the PR and skip.

Conventions for every new bash file: bash 3.2 compatible, `set -euo pipefail`, shellcheck-clean at `-S warning` (the gate already globs `automation-factory/patterns/*/*.sh` and `.../hooks/*.sh`), generously commented, no machine-specific values, idempotent. Every bats file: `load helpers/setup`, `common_setup` (temp `HOME`), `load helpers/stubs` + `make_stubs`, `GRID_RUN_LOG` in a temp dir, temp git repos with a bare temp "origin". Default verify: `bash scripts/gate.sh`. The runner is driven in tests through `GRID_CLAUDE` (stub) and the stub `gh`; tests never call a real model or the network.

Evidence labels for PR descriptions: RAN (observed output pasted), READ (read in the code), UNTESTED. The HUMAN groups paste RAN output.

## 1. B1: Hooks (guard, worktree helper, review hook)

Files: `automation-factory/patterns/issue-loop/hooks/guard-main-push.sh`, `hooks/new-agent-worktree.sh`, `hooks/post-commit-review.sh` (all exist on `next`; edit), new `tests/test_issue_loop_hooks.bats` (start from `_retired/issue-loop/tests/test_issue_loop_hooks.bats`; its paths are stale and its "shared parser" fixture must not be reused).
Spec: `loop-hooks`.

- [x] 1.1 Guard: replace `git_segments()` (the `< <(...)` process substitution that makes the shared parser print nothing) with a direct call of `grid_check_cmd_cap`, `grid_git_segments`, `grid_check_balanced`, reading `GIT_SUB/GIT_START/GIT_LEN/GIT_FLAG`; keep the built-in splitter for when `common.sh` is absent. One decision function used by both paths. Comment the F1 history in the header.
- [x] 1.2 Guard: normalise words (strip `"`, `'`, `\`), match `git` and `gh` by basename, on the built-in path and on the `gh` side.
- [x] 1.3 Guard header and a "Known gaps" comment: `bash -c`, `eval`, aliases, scripts calling git.
- [x] 1.4 `new-agent-worktree.sh` and `post-commit-review.sh`: review against `loop-hooks`; change only what a scenario fails (both are expected to pass as written on `next`: READ, not RAN).
- [x] 1.5 `tests/test_issue_loop_hooks.bats`: the full decision table run three ways (no `GRID_DIR`; `GRID_DIR` -> empty dir; `GRID_DIR` -> a temp copy of the REAL `hooks/lib/common.sh`) asserting identical exit codes; the F1 regression row; quoted refspec; path-qualified `git`/`gh`; chained `cd x && git -C y push origin HEAD:main`; the pinned `bash -c` gap; unbalanced quote exits 2 with the real parser; worktree helper (no upstream, from a linked worktree); review hook (worktree cwd, regex negatives, dedupe, recursion guard, headless stand-down, argv caps, PR-then-issue-then-log) with stub `claude`/`gh` and a real temp git repo.
- Acceptance: `tests/lib/bats-core/bin/bats tests/test_issue_loop_hooks.bats` passes; on a checkout with the 1.1 change reverted the F1 regression row FAILS (run once, paste both outputs).
- Verify: `bash scripts/gate.sh`

## 2. B1: setup.sh, templates, loop.conf.template

Files: `automation-factory/patterns/issue-loop/setup.sh`, `loop-prompt.template.md`, new `worker-prompt.template.md`, `loop.conf.template`, `.gitignore`; extend `tests/test_issue_loop_hooks.bats` (setup part).
Spec: `loop-hooks` (setup.sh), `loop-config-and-seed` (templates, conf keys).

- [x] 2.1 `loop.conf.template`: the key table in `loop-config-and-seed` (including `WORKER_PERMISSIONS`, `WORKER_ALLOWED_TOOLS`), `KEY=${KEY:-{{KEY}}}` lines, no `MAX_TURNS`/`REVIEW_MODEL`/`LABEL_BUDGETS`/App keys. Placeholders are filled with single-quoted values by group 4.
- [x] 2.2 `loop-prompt.template.md`: keep `next`'s MODE blocks and `reset --hard && clean -fd`; ensure `{{BASE_BRANCH}}` everywhere `main` was; the pr block never pushes the base.
- [x] 2.3 `worker-prompt.template.md`: placeholders `{{ISSUE_NUMBER}} {{ISSUE_TITLE}} {{ISSUE_BODY}} {{AGENT_BRIEF}} {{WORKING_DIR}} {{VERIFY_CMD}}`; the instructions from `loop-runner` "Context given to the worker"; the no-human-present sentence naming the check-in/ask-first rules; the outcome-line protocol; no GitHub write commands.
- [x] 2.4 `setup.sh` (D4): default run renders the prompt, self-tests the guard and writes NOTHING to `.claude/settings.json`; `--interactive` runs `next`'s jq merge function (review hook, guard) for a repo where the operator chose an interactive loop session; `--unwire` removes our entries. Add rendering of `loop/loop-prompt.md` from template + `loop.conf` (awk `ENVIRON` substitution, keep one MODE block, no sed delimiter injection); extend the self-test with the quoted-refspec and path-qualified cases; invalid JSON exits 1 untouched.
- [x] 2.5 Tests: every `loop-hooks` setup.sh scenario and the `loop-config-and-seed` template scenarios (direct block, pr block, worker prompt writes nothing remote).
- Acceptance: the setup and template cases of `tests/test_issue_loop_hooks.bats` pass.
- Verify: `bash scripts/gate.sh`

## 3. B1: run-issue.sh

Files: new `automation-factory/patterns/issue-loop/run-issue.sh`, new `tests/test_issue_loop_runner.bats`, `tests/helpers/stubs.bash` (extend only if a needed `gh api` answer is missing; do not fork it).
Spec: `loop-runner` (everything not marked B3).

- [x] 3.1 Implement the algorithm in `design.md` steps 1-14. Use `next`'s `run-issues.sh` only as reading material (lock `mkdir` + trap, `run_child` background-and-wait so a trapped signal lands, `cut_bytes`, `subst_all`, PATH append); do not copy its token, App, trust-history, review or multi-issue code.
- [x] 3.2 Gates: severity labels, existing PR/branch, trust gate via `gh api repos/$ISSUE_REPO/issues/N` (`ISSUE_REPO` defaults to `GH_REPO`; the existing-PR and branch checks use `GH_REPO`) and `.../comments` (`gh issue view --json` has no author association); null or failed API answer = untrusted.
- [x] 3.3 Worker: argv as in design step 9 as a non-empty bash array, with `--allowedTools "$WORKER_ALLOWED_TOOLS"` by default and `--dangerously-skip-permissions` only under `WORKER_PERMISSIONS=bypass`; write the per-run `$TMP/worker-settings.json` (guard only), pass it with `--settings`, never touch `.claude/settings.json`; `GRID_LOOP_HEADLESS=1`, `LOOP_OUTCOME_FILE`; stdin `/dev/null`; pid to `lock/worker`; `--session-id` only when a uuid source exists.
- [x] 3.4 Runner-side verify, push with explicit refspec, `gh pr create`, label swap, comment, run record, `runs.log`, daily cap, cleanup on every path.
- [x] 3.5 `tests/test_issue_loop_runner.bats`: every B1 scenario in `loop-runner`, with stub `claude` (via `GRID_CLAUDE`; it commits a file and writes `done` when `STUB_WORKER_COMMIT=1`), stub `gh`, a temp bare origin with a base branch `next`, a temp clone with the guard entry in `.claude/settings.json`. Must include: red gate with a confident worker (nothing pushed); the F3 invariant on each gate; infra failure keeps the label and exits 1; SIGTERM mid-worker leaves no worktree or lock; `env -i` PATH test; canary `GH_TOKEN` absent from output and comments; lock busy; daily cap; role routing four ways; argv has no `--max-turns`.
- Acceptance: `tests/lib/bats-core/bin/bats tests/test_issue_loop_runner.bats` passes; mutate the runner so verify is skipped and confirm "red gate with a confident worker" fails (paste).
- Verify: `bash scripts/gate.sh`

## 4. B1: instantiate.sh

Files: `scripts/instantiate.sh` (from `git show main:scripts/instantiate.sh`, 539 lines), new `tests/test_instantiate.bats` (start from `_retired/issue-loop/tests/test_instantiate.bats` for the temp-repo scaffolding only), `README.md` tree line for `instantiate.sh` is group 7.
Spec: `loop-config-and-seed` (instantiate requirement and scenarios), `loop-hooks` (.claude ignore).

- [x] 4.1 Start from `main`'s file. Remove: the guard and worktree heredocs, the launchd plist heredoc and `--launchd-hour`, `bash -l`, `--dangerously-skip-permissions` in the plist.
- [x] 4.2 Add options `--base-branch --mode --setup-cmd --worker-model --agent-labels`; profile-to-mode defaults; default label `ready-for-agent`; base-branch detection; read an existing `loop.conf` or `loop.conf.seed` first (as `_retired/.../instantiate.sh` lines 130-139 do).
- [x] 4.3 Render `loop.conf` once with single-quote escaping; awk/`ENVIRON` placeholder fill; copy shipped files verbatim (not `wake.sh`: B2); append `.claude/settings.json` to the target `.gitignore` once.
- [x] 4.4 Label creation (`--limit 200`), `agent:<name>` labels; print the first-run command (`bash loop/run-issue.sh`); write no scheduler file and no `.claude/settings.json` entry; add `scripts/instantiate.sh` to `docs/architecture.md` if present.
- [x] 4.5 Generated `CLAUDE.md` text: new flow (worktree, runner verify, PR), never overwrites an existing one. It SHALL NOT claim the loop is unattended by default.
- [x] 4.6 `tests/test_instantiate.bats`: every scenario in `loop-config-and-seed` for instantiate (idempotent, template verbatim, profiles, labels, default label, business repo with `GRID_DIR` unset and no `~/.the-grid`, `.claude` ignored, quoting), temp git repo, stub `gh`, temp `HOME`.
- Acceptance: `bats tests/test_instantiate.bats` passes; second run prints no `wrote:` line.
- Verify: `bash scripts/gate.sh`

## 5. B1: Project seed and template docs

Files: delete `project-factory/templates/_common/prompts/autonomous-coding-loop.template.md`; new `project-factory/templates/_common/loop/loop.conf.seed`, `loop/ENABLE.md`; edit `project-factory/README.md:38`, `project-factory/scripts/cut-project.sh` (header comment), `templates/lamp-agents-base/{README.md:39,CLAUDE.md:31}`, `templates/python-agents-base/CLAUDE.md:17`, `templates/python-astro-content-agent/CLAUDE.md:15`, `templates/finance-agents-base/{README.md:60,CLAUDE.md:30}`; extend `tests/test_project_factory.bats`.
Spec: `loop-config-and-seed` (seed, template docs).

- [x] 5.1 Write the seed and `ENABLE.md` (at most 40 lines) per spec. Check that `cut-project.sh` copies a `loop/` subdirectory and the `.seed` extension unchanged (read it; add a test).
- [x] 5.2 Rewrite the seven files that mention `autonomous-coding-loop` (`project-factory/README.md` and the six template docs) and the `cut-project.sh` header comment; keep each template's verify command; lamp's `scripts/worktree-setup.sh` becomes the suggested `SETUP_CMD`.
- [x] 5.3 `tests/test_project_factory.bats`: seed lands and `loop/run-issue.sh` does not; retrofit with a differing seed skips and reports; no `autonomous-coding-loop` or `{{VERIFY_CMD}}` match in the seven files.
- Acceptance: `bats tests/test_project_factory.bats` passes.
- Verify: `bash scripts/gate.sh`

## 6. B1: Restored doc and pattern README

Files: new `automation-factory/docs/gh-triage-to-issue-loop.md`, `automation-factory/patterns/issue-loop/README.md`, `automation-factory/README.md` (lines 50-63), `tests/test_depersonalise.bats` (lines 15, 28).
Spec: `loop-migration` (restored, rewritten).

- [x] 6.1 Write the doc (at most 80 lines) from `git show main:automation-factory/docs/gh-triage-to-issue-loop.md` keeping only the ideas the spec lists; HUMAN reads it once for anything personal the denylist would not catch.
- [x] 6.2 Rewrite the pattern README per spec: runner, `loop.conf` table, waker section (B2/B3 marked "planned" until those groups land; update in their PRs), hooks and Known gaps list, role routing, "what the worker can and cannot do".
- [x] 6.3 Remove the two entries from `tests/test_depersonalise.bats`.
- Acceptance: `GRID_REQUIRE_DENYLIST=1 bash scripts/check-personal.sh automation-factory/docs/gh-triage-to-issue-loop.md` exits 0 (on a machine with the private denylist; otherwise the generic half, labelled UNTESTED for the denylist); `bats tests/test_depersonalise.bats` passes.
- Verify: `bash scripts/gate.sh`

## 7. B1: Migration (drops and fallout)

Files: everything in `loop-migration` "What is dropped" and the fallout table.
Depends on: 1-6 merged. HUMAN gate on `_retired/` (7.0).

- [ ] 7.0 HUMAN: operator states in the PR whether the GitHub-side cleanup in `_retired/issue-loop/RETIRED.md` is done (UNVERIFIED today). If not done, 7.4 is left out.
- [x] 7.1 `git rm` `run-issues.sh`, `secure-agent-loop.md`, `tests/test_docs_loop_secrets.bats`; trim `docs/uplift-runbook.md` per spec (re-find the line ranges by heading) and re-title it.
- [x] 7.2 Fallout table, row by row: tests first (`test_docs_factories.bats`, `test_gate.bats`, `test_depersonalise.bats`), then `scripts/gate.sh`, `scripts/stage-site.sh`, `CLAUDE.md`, `README.md`, `USAGE.md`, `index.html`, `automation-factory/README.md`, `tests/helpers/stubs.bash`.
- [x] 7.3 Add `openspec/changes/loops/SUPERSEDED.md` and a `TODO.md` line for the deferred Phase B.
- [ ] 7.4 `git rm -r _retired/` (only if 7.0 says done).
- [x] 7.5 Add the two grep tests (no retirement language; no old-design strings) to `tests/test_docs_factories.bats`.
- Acceptance: the two greps in `loop-migration` return nothing; the stub-dependent bats files listed in the spec pass.
- Verify: `bash scripts/gate.sh`; plus `git grep -niE 'retired.*loop|loop.*retired|quarantined.*loop|RETIRED - do not deploy|LOOP_OPERATOR_HOME|gh-app-token|run-issues\.sh' -- automation-factory scripts tests docs project-factory hooks README.md USAGE.md CLAUDE.md index.html` printing nothing. The paths are listed, not excluded, so the roles, `dist/` and `plugins/` copies of "do not deploy" never match, and the result is the same whether or not `_retired/` was deleted (7.0).

## 8. B1: Scripted end-to-end proof, then HUMAN live run

Nothing here touches the-grid or a live repo. 8.1-8.6 are one opt-in bats file using the REAL `claude`, a stub `gh` and a temp bare origin (no GitHub repo needed, a few dollars at `MAX_BUDGET_USD=1`); 8.7-8.9 use one throwaway PRIVATE GitHub repo the operator creates and deletes. Models are not deterministic: the scripted checks inspect what actually happened (transcript, git state) and are run twice; a flake is reported, not retried until green.
Files: new `tests/test_issue_loop_e2e.bats` (skipped unless `GRID_E2E=1`; the one exception to "tests never touch the real `~/.claude`": it must load the operator's real rules to answer 8.4, and it writes one session transcript there), fixes to `run-issue.sh` found here.
Spec: `loop-runner` (scripted scenarios), `loop-hooks`.

- [x] 8.1 Agent: write the test. Fixture repo: tracked `CLAUDE.md` saying end every commit message with `CANARY-7`; `PURPOSE.md`, `MAP.md`, `GUARDRAILS.md` each holding a distinct canary word; temp bare origin with base branch `next`; stub `gh` serving one labelled issue ("write the three canary words from PURPOSE.md, MAP.md and GUARDRAILS.md into out.txt and commit"); `loop/` cut with `instantiate.sh`. It runs the real `run-issue.sh` and asserts (jq over the transcript `find ~/.claude/projects -name '<session-id>.jsonl'`, UNVERIFIED format, adjust the parser to the real one): `out.txt` has all three words; commit message ends `CANARY-7` (CLAUDE.md loads from the worktree cwd); first Read of `PURPOSE.md` and of `MAP.md` precede the first Edit/Write; first Read of `GUARDRAILS.md` precedes the first Edit, Write or `git commit` call; the push happened via the runner (origin has `issue-N`, the transcript has no `git push`/`gh` call).
- [x] 8.2 Same file, red gate: `VERIFY_CMD=false`, nothing pushed, issue `blocked`.
- [x] 8.3 Same file, guard live: a prompt that tells the worker to run `git push origin next` ends with a denial (allowlist) or the guard's BLOCKED text (bypass) in the transcript, and origin's `next` is unchanged.
- [x] 8.4 Same file, D6: an issue needing at least five tool calls (create five small files, one commit) with the operator's real `~/.claude` loaded: exit 0, one commit with all five, at least five tool-use blocks, and the final assistant text does not ask for a go-ahead. If it stalls, record the transcript tail and stop for the operator (design Risk 1).
- [x] 8.5 Same file, D5: run 8.1 and 8.4 under `WORKER_PERMISSIONS=allowlist` with, in turn, `--allowedTools` alone, plus `--permission-mode acceptEdits`, plus `--permission-mode dontAsk`. Record which combination completes with no prompt and no hang, set that as the runner default, and write it in the PR. Only if none completes does the report recommend `WORKER_PERMISSIONS=bypass`; the operator decides, and the decision is written in the PR (proposal assumption 1).
- [x] 8.6 Record the real `claude -p --output-format json` field names (`is_error`, `subtype`, `total_cost_usd`) and the subtype when `--max-budget-usd 0.01` is exhausted; fix `run-issue.sh` and the UNVERIFIED list.
- [ ] 8.7 HUMAN: create the throwaway private repo (`loop-sandbox`, `next` branch, trivial `README.md`, four issues labelled `ready-for-agent`: a trivial edit; one whose `VERIFY_CMD` will fail; one also labelled `severity:high`; one labelled `agent:grid-backend-dev`). Run `instantiate.sh ... --profile work --base-branch next --verify-cmd "test -s README.md" --agent-labels grid-backend-dev`, `bash loop/setup.sh`, then `bash loop/run-issue.sh` by hand four times. Paste: PR to `next` from `issue-N` opened by the runner, issue `ready-for-human` and open; `blocked` with the verify tail and no push; `severity:high` refused with no session; `--agent grid-backend-dev` in the log and the role in the run record. The stranger-author gate is covered by stubbed association in group 3 and stays UNTESTED live.
- [ ] 8.8 HUMAN: `claude -p --agent grid-backend-dev --model haiku --max-budget-usd 0.1 --output-format json "Reply with the model you are"`; record whether `--model` or the agent's `model:` wins.
- [ ] 8.9 HUMAN: delete the throwaway repo; confirm no `issue-loop` lock or `<repo>-loop` worktree dir remains.
- Acceptance: 8.1-8.6 pass twice with `GRID_E2E=1` (output pasted) or each failure is explained; 8.7-8.9 have pasted output.
- Verify: `bash scripts/gate.sh` (the e2e file is skipped there) unchanged after any fix.

## 9. B2: Waker

Files as built: new `automation-factory/patterns/issue-loop/cron-run.sh` (replaces the planned `wake.sh`), `scripts/lib/render-schedule.sh` (additive `every:N`), `scripts/instantiate.sh` (`--cron-every`, `--cron-log`), pattern README ("Unattended" section), and `tests/test_issue_loop_cron_verify.bats` (replaces the planned `test_issue_loop_waker.bats`).
Spec: `loop-waker`.

- [x] 9.1 `render-schedule.sh`: `_rs_parse_schedule` accepts `every:N` (1..59); `render_crontab_line` emits `*/N`; the systemd and launchd renderers return 2 "every: is cron-only". Daily/weekly output byte-identical.
- [x] 9.2 Built as `cron-run.sh` instead of `wake.sh`: sources `loop/cron.env`, `cd`s to the repo, `exec bash loop/run-issue.sh`. No `gh issue list` pre-check: the runner's lock, backoff and empty-queue exit do that job (see `loop-waker`).
- [x] 9.3 `instantiate.sh`: `--cron-every N` (pr mode, 1-59) and `--cron-log` print one crontab line per repo plus the idempotent command that adds it, and write the gitignored `loop/cron.env`; never runs `crontab`. No `--waker-interval`, and no "do not install until B3" sentence (backoff and stale lock now exist).
- [x] 9.4 Tests in `tests/test_issue_loop_cron_verify.bats`: `every:N` render (valid, 0, 60, junk, systemd refuses), `--cron-every` output and `cron.env`, stub `crontab` never called, no output without the option. Not covered: a stripped-environment run of `cron-run.sh`, the two-ticks race.
- [x] 9.5 README "Unattended: one cron line per repo" section with the stripped-environment check and the 15-minute poll. The 60-minute floor and "uninstalled until B3 passes" wording is intentionally absent.
- Acceptance: `bats tests/test_issue_loop_cron_verify.bats tests/test_render_schedule.bats tests/test_usage_schedule.bats tests/test_instincts_schedule.bats` passes.
- Verify: `bash scripts/gate.sh`

## 10. B2, HUMAN: Prove the waker on the throwaway repo

- [ ] 10.1 Recreate the throwaway repo (as 8.1) with one labelled issue. As the operator, from a stripped environment that mimics cron: `env -i HOME="$HOME" PATH=/usr/bin:/bin bash loop/wake.sh`. Paste the result.
- [ ] 10.2 Specifically record whether `gh` and `claude` authenticate with no desktop session (the keyring question, proposal assumption 10). If `gh` cannot read its token: record the options (`gh auth login --insecure-storage`, or run the waker from a session that has the keyring) and stop for the operator's decision; do not invent a token file.
- [ ] 10.3 Idle poll: with no labelled issue, `wake.sh` prints nothing and writes no run-record line. Busy poll: start a run, start `wake.sh` again, observe "busy" behaviour (no second runner).
- [ ] 10.4 Simulate cron ticks by hand, installing nothing: run the stripped-environment `wake.sh` twice in a row while a run is in progress; the second leaves it alone. No `crontab -e` in this group (D11).
- [ ] 10.5 Delete the throwaway repo.
- Acceptance: pasted output for 10.1-10.4. Installing a waker for a real repo is a separate operator decision after group 12.

## 11. B3: Backoff, poison issue, stale lock

Files: `automation-factory/patterns/issue-loop/run-issue.sh`, `tests/test_issue_loop_runner.bats`, pattern README (no `wake.sh` exists).
Spec: `loop-runner` ("Backoff on infra failure and rate limits", "Stale lock takeover").

- [x] 11.1 `backoff` state file, written on infra failure (including a worker cut off by a usage or rate limit); deleted on any issue-level outcome and on an empty queue; checked at start by `run-issue.sh` (an explicit issue number ignores it). As built: the file holds `until=<epoch> fails=<n> issue=<n> issue_fails=<n>` (the last two are the poison counter, 11.2), and the rate-limit pattern list is an inline `grep -E` in the no-outcome branch, not a variable at the top.
- [x] 11.2 Poison rule (commit 3e1eb3f): `infra_fail <message> [poison]` counts `issue=<n> issue_fails=<n>` in `backoff` for worker crashes and error results the service patterns do not explain; the third consecutive failure on the same issue relabels it `blocked`, posts one comment, records outcome `error` with a `poison:` note, deletes `backoff` and exits 0. Outages (logins, `gh`, origin, usage limits) never count. If the relabel fails, the normal backoff applies. Test: `poison: the third consecutive worker failure on one issue blocks it ...` in `tests/test_issue_loop_runner.bats`; documented in the pattern README ("Poison issue").
- [x] 11.3 Stale lock takeover: `ps -p PID` finds no process, or its command line lacks `run-issue.sh`; atomic `mv` to `lock.stale.$$` then `mkdir`; logs "took over a stale lock". Also built: a lock with no pid file older than 5 minutes (`find LOCK -maxdepth 0 -mmin +5`) is stale and taken over; a fresher one is busy (test: `lock: a lock with no pid file is busy while fresh and taken over once it is older than 5 minutes`). Not built, and left out of the spec: `kill -0` EPERM handling (`ps -p` is used), and removal of another issue's leftover worktree.
- [ ] 11.4 Tests, partly done: the doubling (first two windows), inside-window quiet exit, reset, usage-limit backoff, dead-pid takeover, pid-reuse takeover, the pid-less lock and the poison scenario are in `tests/test_issue_loop_runner.bats`. Still missing: the `GRID_LOOP_NOW` hook and the full doubling table with the 6 h cap mutation, the parallel-reclaim race, and a SIGKILL of a real stub-worker run. Original list: all B3 scenarios including the doubling table with a test hook for "now" (`GRID_LOOP_NOW`), the race (two reclaimers in parallel, repeated 20 times), SIGKILL of a stub-worker run, pid reuse (lock names `$$` of the test shell, which is not a runner), and that B1 behaviour (busy exit) is unchanged for a live holder.
- Acceptance: the B3 cases pass; the B1 cases still pass; the doubling test fails if `min(..., 6h)` is removed (mutate and paste).
- Verify: `bash scripts/gate.sh`

## 12. B3, HUMAN: Prove B3 on the throwaway repo

- [ ] 12.1 Kill -9 a running `run-issue.sh` (worker mid-flight); start `wake.sh`; observe "reclaimed stale lock" and a completed run. Confirm no orphan `claude` process (`ps`) or, if one remains, record it as the documented R10.qa.F10 gap.
- [ ] 12.2 Backoff with a fake `claude`: set `GRID_CLAUDE` to a script that exits 1; run twice; observe the second run exit 0 "backing off until", no `gh` write; a third failure on the same issue (using `GRID_LOOP_NOW` or a hand-edited `until`) marks it `blocked`.
- [ ] 12.3 Capture one real rate-limit sample if one occurs naturally (do not provoke one); paste the text/JSON, and set the pattern list from it. Until a sample exists the signal list is UNVERIFIED and unknown errors fall back to the generic infra backoff.
- [ ] 12.4 (The sentence removal is done: the "do not install until B3 passes / 60-minute floor" wording is gone from the README and `instantiate.sh` output, without the group 12 proof. Still open:) Delete the throwaway repo after the proof; keep the 15-minute default. Delete the throwaway repo. Operator then decides whether to install a waker for a real repo (and the-grid cut is a separate step, see `loop-migration`).
- Acceptance: pasted output for 12.1-12.3.

## 13. Built beyond the original plan

Added after the groups above, each with tests in `tests/test_issue_loop_runner.bats`, `tests/test_instantiate.bats` or `tests/test_issue_loop_cron_verify.bats`. Specs: `loop-runner`, `loop-waker`.

- [x] 13.1 Headless `MODE=direct`: after the runner's own verify, rebase onto the base (re-verify if it moved), push to `BASE_BRANCH` without force, comment the sha, relabel `ready-for-human`, close the issue. Rebase conflict or rejected push: `blocked`, work kept on local `issue-N`. `instantiate.sh --mode direct` ships no runner, so headless direct is selected by `MODE=direct` in `loop.conf` of a `pr` cut.
- [x] 13.2 `MAX_ISSUES_PER_DAY=0` means unlimited and is the default.
- [x] 13.3 Infra failures keep the label (exit 1) and back off; a failing `gh pr list`/`ls-remote` or unreadable issue is infra; an issue number that is a pull request is refused (exit 2).
- [x] 13.4 `--fast-verify` and `loop/verify.sh` (changed-files check; an explicit `--verify-cmd` wins).
- [x] 13.5 `MODE=pr` opens draft PRs; a cross-repo PR title is the fixed `issue-loop: work for <tracker>#N`.
- [x] 13.6 A timed-out worker's uncommitted work is saved as a WIP commit on local `issue-N`; a worker that wrote its outcome but never exits is stopped after `WORKER_EXIT_GRACE`.
