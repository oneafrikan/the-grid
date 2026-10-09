# Tasks

Cross-change: lands after `foundations` (D9); every group depends on `foundations` CI being green.
Order: 1 and 2 are independent. 3 needs 1 and 2. 4 needs 3 (same OpenClaw files). 5 needs 2. 6 needs 3, 4, 5. 7 needs 6.
Design, file formats and every judgement call are in `design.md`. Until group 6 lands, edit groups verify with `bash scripts/check-personal.sh <touched files>` instead of the whole-tree scan.

## 1. HUMAN: archive personal material into the private repo

Needs the private repo checkout and the operator's own strings; commits to a second repo, so not for the unattended loop. No public PR.
Files (all under `~/.the-grid-private/`): `archive/clawguides/`, `archive/design/`, `archive/prompts/`, `archive/MANIFEST.sha256`, `LOGS/todo-done-history.md`, `denylist.txt`.
Acceptance: `cd ~/.the-grid-private/archive && sha256sum -c MANIFEST.sha256` (macOS: `shasum -a 256 -c`) prints OK for every line; `git -C ~/.the-grid-private status -sb` shows the commit pushed.
Verify: the two commands above.
Depends on: none.

- [ ] 1.1 Copy `__assets/ClawGuides.zip` and the `__assets/ClawGuides/` tree to `archive/clawguides/` (preserve structure, byte-exact).
- [ ] 1.2 Copy `agent-factory/docs/openclaw-paperclip-targets-plan.md`, `docs/openclaw-portfolio-desk-blueprint.md`, `automation-factory/docs/gh-triage-to-issue-loop.md` to `archive/design/`; copy `prompts/2026-06-13-openclaw-lamp-team-prompt.md` to `archive/prompts/`.
- [ ] 1.3 Cut the "Pending rollout" paragraph and the whole "Status: Done" section out of `TODO.md` into `LOGS/todo-done-history.md`, verbatim (the cut itself happens in public in group 3; here only save the text).
- [ ] 1.4 Write `archive/MANIFEST.sha256` (relative paths, one line per archived file) and commit + push the private repo.
- [ ] 1.5 Write `denylist.txt` in the format given in `design.md` (kind, scope, label, regex): every machine host name, work/employer and personal-project names, GitHub handles other than the public owner, family and third-party private names, private product and infrastructure names that appear in the current tree. Use `deny-i` with `\b...\b` for words that collide with ordinary English or other skill names, and check them against `git grep` before saving. Commit + push.

## 2. Add the scan script and its tests (new files only)

Files: `scripts/check-personal.sh`, `scripts/personal-patterns.txt`, `scripts/personal-allow-paths.txt`, `scripts/personal-denylist.example.txt`, `tests/test_check_personal.bats`.
Acceptance: new bats tests pass: (a) email, `/Users/<name>/`, token-shaped string, private IP each flagged with exit 1; (b) `you@example.com`, `git@github.com`, `https://user:tok@github.com/o/r.git`, `/Users/you/x`, `/Users/alice/x`, `AKIAIOSFODNN7EXAMPLE` and `finance-desk-finance-risk-officer` not flagged; (c) scoped `Gareth` rule flags `skills/x/SKILL.md` but not `README.md`; (d) denylist hit prints `[private:N]` and not the matched text; (e) absent denylist prints the "generic patterns only" notice and exits 0 on a clean tree; (f) empty `GRID_PRIVATE_DENYLIST=` disables the private half; (g) path in `personal-allow-paths.txt` is skipped; (h) tracked `x.zip` and a file over `GRID_MAX_BYTES` flagged; (i) positional args restrict the scan; (j) untracked files and gitlinks ignored; (k) tests set `GRID_DIR` to a temp repo and never read `$HOME`.
Verify: `bash scripts/gate.sh` (the new script must be shellcheck-clean; it is not yet a gate check).

- [ ] 2.1 Write `scripts/personal-patterns.txt` with the generic rules shown in `design.md` plus a header comment explaining the four columns.
- [ ] 2.2 Write `scripts/check-personal.sh` per the "Scan design" section: bash 3.2-safe, `LC_ALL=C`, comments on every block, env `GRID_DIR`, `GRID_PRIVATE_DENYLIST`, `GRID_MAX_BYTES`, exit codes 0/1/2.
- [ ] 2.3 Write `scripts/personal-allow-paths.txt` with the six initial globs and their reasons; write `scripts/personal-denylist.example.txt` containing only comments and placeholder rows (`deny-i * example-label \bexample-host\b`).
- [ ] 2.4 Write `tests/test_check_personal.bats` covering (a) to (k) using throwaway repos under `$BATS_TEST_TMPDIR`.

Depends on: none.

## 3. Remove archived material from the public tree

Files: delete `__assets/` (22 files), `docs/playbook-ai-dev-team.md`, `agent-factory/docs/openclaw-paperclip-targets-plan.md`, `docs/openclaw-portfolio-desk-blueprint.md`, `automation-factory/docs/gh-triage-to-issue-loop.md`, `prompts/2026-06-13-openclaw-lamp-team-prompt.md`; edit `TODO.md`, `README.md`, `agent-factory/compose.py` (comments only), `agent-factory/README.md`, `agent-factory/openclaw/README.md`, `agent-factory/openclaw/templates/orchestrator/BOOT.md`, `agent-factory/openclaw/roster.json` (`description` text only), `agent-factory/scripts/deploy_openclaw.sh` and `agent-factory/scripts/deploy_paperclip.py` (comments only), `docs/reference-resources.md`; add `tests/test_depersonalise.bats`.
Guard: before any `git rm`, the task checks each path is listed in `~/.the-grid-private/archive/MANIFEST.sha256` (or is the duplicate playbook) and the archived hash equals the working-tree hash; if the manifest is missing, stop and label the issue `blocked`. Re-running when the paths are already gone is a no-op.
Acceptance: `tests/test_depersonalise.bats` asserts each removed path is absent (`[ ! -e path ]`) and that `git grep -F <basename> -- . ':!openspec' ':!repos'` returns nothing for each removed filename.
Verify: `bash scripts/gate.sh`.

- [ ] 3.1 Run the guard, then `git rm -r` the paths listed above.
- [ ] 3.2 In `TODO.md` delete the pending-rollout paragraph and everything from "## Status: Done" to the end; leave one line "Shipped-work history is kept privately; see git log." Reword the issue-map row that names a host to a neutral label.
- [ ] 3.3 Repoint every remaining mention of a removed doc to `agent-factory/openclaw/README.md`: `compose.py` comments (lines ~812, ~943), `agent-factory/README.md` (the "plan" link, ~276), `openclaw/README.md` (~3, ~79), `openclaw/templates/orchestrator/BOOT.md` (~24), `roster.json` `description`, `deploy_openclaw.sh` header (~17), `deploy_paperclip.py` docstring (~5), and the `TODO.md` issue-map line (~64). Find them all with `git grep -n -F openclaw-paperclip-targets-plan -- . ':!openspec' ':!repos'` before and after.
- [ ] 3.4 In `README.md` drop the `playbook-ai-dev-team.md, openclaw-portfolio-desk-blueprint.md` tree line and the `prompts/` tree line, and update the `docs/` heading text so it no longer says "playbooks".
- [ ] 3.5 In `docs/reference-resources.md` section 13, replace "uploaded"/"available in outputs" wording with "kept privately"; keep the bibliography entries.
- [ ] 3.6 Write `tests/test_depersonalise.bats` with the removed-path and no-dangling-reference assertions (path list inline, no personal strings).

Depends on: 1, 2.

## 4. Genericise in place: identity, OpenClaw target, gh-triage, loop pattern, comments

Files: `agent-factory/user.yaml.example`, `agent-factory/openclaw/roster.json`, `agent-factory/openclaw/README.md`, `agent-factory/openclaw/templates/orchestrator/{AGENTS,BOOT,EXPERTISE,HEARTBEAT,IDENTITY,MEMORY,TOOLS,USER}.md`, `agent-factory/scripts/deploy_openclaw.sh`, `agent-factory/scripts/deploy_paperclip.py`, `agent-factory/docs/gh-triage-spec.md`, `agent-factory/roles/gh-triage/deployment-scope.template.md`, `automation-factory/patterns/issue-loop/README.md`, `baseline-submodules.example.txt`, `scripts/lib/find-skill-mds.sh`, `agent-factory/README.md`, `LEARNINGS.md`, `README.md`, `index.html`.
Rules to apply: no real name/email (use `Your Name <you@example.com>`); example machine label `my-laptop`; "the operator" in any text rendered into agent workspaces; comments describe the mechanism, not the author's install ("a self-hosted OpenClaw gateway", "a Linux box"); deployment tables replaced by one sentence saying each install keeps its own table in its own infra repo; downstream repo names become "a downstream repo"; in `LEARNINGS.md` replace the host segment of `Source: LOGS/...` file names with `<host>`; comments in `baseline-submodules.example.txt` say "machine overlays" without naming hosts.
Behaviour must not change: code lines, JSON keys/values used by code, regexes and tokens stay as they are; `roster.json` edits touch `description` and `_comment` text only.
Acceptance: `bash scripts/check-personal.sh <every file above>` exits 0 on a machine with the private denylist (generic-only elsewhere); `tests/lib/bats-core/bin/bats tests/` still green, including the roster test; `compose.py --check` for core, grid, finance-desk reports no drift.
Verify: `bash scripts/gate.sh`.

- [ ] 4.1 `user.yaml.example`: placeholder operator, `machine` example, nothing else changes.
- [ ] 4.2 OpenClaw files: `roster.json`, `openclaw/README.md`, all `templates/orchestrator/*.md`; the hostname/hardware line in `TOOLS.md` becomes a sentence pointing at `user.yaml` `machine`; the "alongside other agents" line becomes generic.
- [ ] 4.3 `deploy_openclaw.sh` and `deploy_paperclip.py`: comments only.
- [ ] 4.4 `gh-triage-spec.md` and `deployment-scope.template.md`: replace deployment tables/"known deployments" with the one-sentence rule; keep the contract text.
- [ ] 4.5 `issue-loop/README.md`, `baseline-submodules.example.txt`, `find-skill-mds.sh`, `agent-factory/README.md`, `LEARNINGS.md`.
- [ ] 4.6 `index.html` status bullet ("It is opinionated and partly personal", ~line 1978): replace the claim that machine names and account routing are still personal with one true sentence saying personal config is gitignored or private and a gate enforces it. One-sentence edit only (`front-door` rewrites the file later). `README.md`'s matching bullet (~397) is already accurate; leave it.

Depends on: 2, 3.

## 5. Handoff skill: neutral defaults, optional private location table

Files: `skills/handoff/SKILL.md`, `skills/handoff/handoff-template.md`, `skills/handoff/session-template.md`, `skills/handoff/context-template.md` (only if it has hits).
Acceptance: `bash scripts/check-personal.sh skills/handoff/SKILL.md skills/handoff/handoff-template.md skills/handoff/session-template.md skills/handoff/context-template.md` exits 0; `bash scripts/catalog.sh --check` still passes; `tests/lib/bats-core/bin/bats tests/test_skill_format.bats` passes.
Verify: `bash scripts/gate.sh`.

- [ ] 5.1 Retitle the two "(author SOP)" headings neutrally; filename rule keeps `<machine>` from `hostname -s` with examples `my-laptop`, `build-box`.
- [ ] 5.2 Replace the Document locations table with the default (`LOGS/`, ask before creating) and a paragraph: "If `~/.the-grid-private/handoff-locations.md` exists, read its table first (rows: `| directory-name-or-glob | location |`); first matching row wins." Keep the case-handling paragraph unchanged.
- [ ] 5.3 In the templates, replace example topics that name private projects with neutral ones ("cron setup", "Phase 0 - CLI only").

Depends on: 2.

## 6. Wire the scan into the gate and enforce in CI

Files: `scripts/gate.sh`, `tests/test_depersonalise.bats` (add repo-wide case), `tests/test_gate.bats` (add a `scripts/check-personal.sh` stub, `exit 0`, to the fake grid in `setup()`, next to the `catalog.sh` stub), `CLAUDE.md` (Key files entry + one line in "Drift checks").
Acceptance: `tests/test_depersonalise.bats` gains a test running `GRID_PRIVATE_DENYLIST= bash scripts/check-personal.sh` on the real repo and expecting exit 0 (this is what CI runs); `gate.sh` prints `==> personal` with PASS; on a machine without the private denylist the gate prints `gate: PASS (skipped: personal-denylist)` rather than failing; a deliberately added home-directory path line in a scratch copy makes the gate FAIL.
Verify: `bash scripts/gate.sh`.

- [ ] 6.1 Add `run_personal_check` and `check personal run_personal_check` to `gate.sh` between `check compose` and `check bats`, and list it in the header comment: runs `bash scripts/check-personal.sh`; pushes `personal-denylist` onto `SKIPPED` when the script reports the absent-denylist notice.
- [ ] 6.2 Add the repo-wide generic test to `tests/test_depersonalise.bats`.
- [ ] 6.3 Document in `CLAUDE.md`: script, the three rule sources (public patterns, private denylist, allow-paths), the voice rule, and "add a path to `personal-allow-paths.txt` only with a reason".
- [ ] 6.4 Run the full suite twice; the second run must be identical (idempotent, no tracked file changed: `git status --porcelain` empty).

Depends on: 3, 4, 5.

## 7. HUMAN: close-out

- [ ] 7.1 Comment on #42: the OpenClaw target is now genericised; personas and a parameterised deploy script remain; issue stays open. Comment on #54: the only constraint applied was "values stay local"; persona fields and voice layer remain; issue stays open.
- [ ] 7.2 Decide whether to rewrite history for the moved paths (single `git filter-repo` pass) and whether anything in the old files was ever a live credential needing rotation.
- [ ] 7.3 Decide whether GitHub issue titles that name hosts should be edited.
- [ ] 7.4 Confirm the overnight build host has the private repo cloned so the denylist half of the gate runs there.

Depends on: 6.
