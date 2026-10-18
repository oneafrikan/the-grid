# Tasks

Verify command for every group unless stated: `bash scripts/gate.sh`. Tests are bats and never touch the real `~/.claude` (use `SKILLS_DIR`, `AGENTS_DIR`, `GRID_DIR`, `GRID_HOST` overrides as `tests/helpers/setup.bash` does). Shell is bash and shellcheck-clean; comment generously.

## 1. Skill discovery exclusion

Depends on: none.

Files: `scripts/lib/find-skill-mds.sh`, new `scripts/lib/skill-excludes.txt`, new `tests/test_skill_discovery.bats`, `CLAUDE.md` (one bullet in "wire.sh contract").

- [x] 1.1 Add an `_skill_excluded <repo-name> <relative-path>` helper to `find-skill-mds.sh` implementing the three rules in design.md (translation dirs, root-level dot-dir, listed prefix from `scripts/lib/skill-excludes.txt` located via `BASH_SOURCE`). Apply it to the output of both branches (git `ls-files` and `find` fallback). Keep the output contract (`<repo>/<relative path>`, one per line). The repo name for rule 3 is `basename` of the argument.
- [x] 1.2 Create `scripts/lib/skill-excludes.txt` with the header comment and the single row `ecc | pi/`.
- [x] 1.3 Rewrite the header comment of `find-skill-mds.sh`: it currently says skills tracked inside dot-dirs are honoured; state the new rule and why.
- [x] 1.4 Write `tests/test_skill_discovery.bats` with fixtures under `mktemp -d` (both a plain dir and a `git init` + `git add` + commit fixture, so both branches run):
  - keeps `skills/a/SKILL.md` and a nested `engineering/b/SKILL.md`;
  - drops `docs/ja-JP/skills/a/SKILL.md`, `docs/tr/skills/a/SKILL.md`, `i18n/zh-CN/a/SKILL.md`;
  - keeps `docs/guides/a/SKILL.md` (not a locale);
  - drops `.kiro/skills/a/SKILL.md`, `.agents/skills/a/SKILL.md`;
  - drops `pi/core/a/SKILL.md` only when the fixture dir is named `ecc`;
  - a real-repo test (skipped when `repos/ecc` is uninitialised): no path from `find_skill_mds repos/ecc` contains `/docs/` or `/.`, every path is under `repos/ecc/skills/`, and the line count equals `git -C repos/ecc ls-files -- 'skills/*SKILL.md' | wc -l` (which must be greater than 0). No literal count: it moves with every ECC bump.
- [x] 1.5 `wire.sh` and `catalog.sh` need no code change (they source the helper); add one catalog test: a mock repo with a `.kiro` copy and a `skills/` skill reports count 1 in the section header.
- [x] 1.6 If `baseline-submodules.txt` exists on this machine, run `bash scripts/catalog.sh` and include the regenerated `SKILLS.md`; otherwise leave `SKILLS.md` untouched and write "SKILLS.md needs regeneration on a baseline machine" in the PR body.

Acceptance: `tests/lib/bats-core/bin/bats tests/test_skill_discovery.bats` passes; if `repos/ecc` is initialised, `find_skill_mds repos/ecc | wc -l` equals `git -C repos/ecc ls-files -- 'skills/*SKILL.md' | wc -l` (derived, not a literal; 293 at the 2026-10-09 pin).

## 2. CI that means the gate

Depends on: 1.

Files: `.github/workflows/tests.yml`, `scripts/wire.sh` (add `GRID_BASELINE`), `tests/test_wiring.bats`, new `tests/helpers/wired.bash`, `tests/test_skill_format.bats`, `tests/test_repo_health.bats`.

- [x] 2.1 `wire.sh`: replace the hard-coded `$GRID_DIR/baseline-submodules.txt` in the first `load_manifest` call (currently line 112) with `${GRID_BASELINE:-$GRID_DIR/baseline-submodules.txt}`; add `GRID_BASELINE` to the env-var list in the header comment. Add a test to `tests/test_wiring.bats`: a mock grid with two repos, `GRID_BASELINE` pointing at a temp file naming only one of them, wires only that repo's skills.
- [x] 2.2 Add `tests/helpers/wired.bash` with `wired_skill_dirs` exactly as sketched in design.md (the group-2 form: `SKILLS_DIR`/`AGENTS_DIR` in a temp dir, `GRID_HOST=__baseline__`). Task 8.5 switches it to `GRID_DRY_HOME`.
- [x] 2.3 `tests/test_skill_format.bats`: delete the baseline parsing, `repo_is_wired` and `all_wired_skill_dirs`; add `load helpers/setup` and `load helpers/wired` (setup defines `REPO_ROOT`) and have the three "wired" tests iterate `wired_skill_dirs`. Keep the "no duplicate skill names in root-level skills" test as is.
- [x] 2.4 `tests/test_repo_health.bats`: `skills dir exists` calls `skip "no skills dir on a CI runner"` when `CI=true` and the dir is absent; add `agent-factory venv exists when CI=true` (skips when `CI` is unset, fails when `CI=true` and `agent-factory/.venv/bin/python` is missing).
- [x] 2.5 Rewrite `.github/workflows/tests.yml` exactly as in design.md (triggers: pushes to `main` and `next`, every pull request; `permissions`, `concurrency`, `ubuntu-24.04`, `timeout-minutes`, `actions/checkout@v7`; build venv; `shellcheck --version`; run `bash scripts/gate.sh`). This group owns the only venv step in this file; `workflow-upgrades` task 2.7 depends on it and adds nothing.
- [x] 2.6 Run the venv-dependent tests locally with the venv built (`python3 -m venv agent-factory/.venv && agent-factory/.venv/bin/pip install -r agent-factory/requirements.txt`; the venv is gitignored). For any test that fails only because of the runner environment, add an explicit `skip "<reason>"`. Never delete a test.
- [ ] 2.7 Open the PR to `next` and read the PR's CI run (`gh run list --branch <branch> --limit 1`, then `gh run view <id> --log`): all steps green, and the bats output contains zero lines matching `skip agent-factory venv not built`. If the run fails on a shellcheck warning the local gate did not show, fix the script line; do not add a `disable` directive and do not drop the shellcheck step. If the failure is a venv-gated test, add an explicit `skip` per 2.6 and say so in the PR body. NOT DONE by the build agent: instructed not to open a PR, and tests.yml does not trigger on a bare feature-branch push (verified: `gh run list --branch build/foundations` is empty), so the CI run is still to be read once the PR exists.

Acceptance: new test `agent-factory venv exists when CI=true` passes in the PR's CI run; the PR's CI run has no `skip agent-factory venv not built` line and the three previously failing tests pass (this is also the proof that the gate passes with no personal baseline; do not rename or move the operator's `baseline-submodules.txt`). Push-to-`next` triggering is checked in group 7.

## 3. Pages, HTTPS submodule URLs, example-baseline fix

Depends on: 1 (the resolve test and the openspec subtraction removal rely on the exclusion rule).

Files: new `.nojekyll`, `.gitmodules`, `docs/SOURCES.md`, `baseline-submodules.example.txt`, new `tests/test_submodule_sources.bats`, `BOOTSTRAP.md`.

- [x] 3.1 Add an empty `.nojekyll` at the repo root.
- [x] 3.2 For each of the 22 `git@github.com:` entries in `.gitmodules`, confirm public with `GH_PAGER= gh repo view <owner>/<repo> --json isPrivate`; rewrite to `https://github.com/<owner>/<repo>.git`. List any private exception in the PR body and leave it SSH.
- [x] 3.3 Run `git submodule sync --recursive`; confirm `git -C repos/<name> fetch --dry-run` works for three of the converted repos.
- [x] 3.4 Regenerate `docs/SOURCES.md` per the Decided rule (script when a personal baseline exists, otherwise hand-remove the SSH marker and footnote).
- [x] 3.5 `baseline-submodules.example.txt`, exactly per the design.md table: gstack header `(29 skills)` to `(42 skills)`; replace `mattpocock/diagnose`, `to-issues`, `to-prd`, `write-a-skill` with `diagnosing-bugs`, `to-tickets`, `to-spec`, `writing-for-agents` (keep alphabetical order within the section); delete `mattpocock/edit-article`, `request-refactor-plan`, `ubiquitous-language`, `zoom-out`; mattpocock header `(21 skills)` to `(17 skills)`; delete the `-openspec/release-openspec` line and reword the comment sentence above it to say the maintainer skills under `.agents/skills/` are excluded by discovery. Change no other line.
- [x] 3.6 `BOOTSTRAP.md`: add "after pulling a change to `.gitmodules`, run `git submodule sync --recursive`" next to the submodule step.
- [x] 3.7 `tests/test_submodule_sources.bats`: (a) no `.gitmodules` URL starts with `git@` or `ssh://`; (b) `.nojekyll` exists at the repo root; (c) every section header `# --- <repo> … (N skills) ---` in the example baseline whose repo has `<repo>/` lines has N equal to that line count; (d) every positive `<repo>/<skill>` line, for every repo, matches the basename of a skill dir from `find_skill_mds repos/<repo>` (source `scripts/lib/find-skill-mds.sh`; entries of an uninitialised repo are printed to fd 3 and not failed; failures print each unresolved entry); (e) every positive whole-repo line names an existing `repos/<repo>` dir; subtraction lines (`-…`) and typed lines (text before the first `/` contains `:`, for example `project:`, `rules:`, `harness:`, `hook:`) are ignored; (f) `docs/SOURCES.md` contains no ` ᵍ`.

Acceptance: `tests/lib/bats-core/bin/bats tests/test_submodule_sources.bats` passes; `grep -c 'git@' .gitmodules` prints 0; with the old example baseline restored, test (d) fails naming the 8 mattpocock entries (check once, then restore the fix).

## 4. Bump the gstack pin

Depends on: 1, 3. Runs before group 5 so group 5's flag-guard test checks the shipped pin.

Files: `repos/gstack` (submodule pointer only), new test in `tests/test_submodule_sources.bats`.

- [x] 4.1 `git -C repos/gstack fetch origin`; check out the `origin/HEAD` commit (no tags exist; head moves daily). Read `repos/gstack/VERSION`; abort with a note in the PR body if it is below `1.91`. Check that `repos/gstack/setup` still contains each of `--no-team`, `--no-plan-tune-hooks`, `--no-timeline-stop-hook`, `--no-prefix`, `--host` and `-q`; if any is missing, stop and say so in the PR body (group 5 would otherwise ship a setup row that silently re-enables a global hook).
- [x] 4.2 Add test `gstack pin is at least 1.91` (reads `repos/gstack/VERSION`, compares major.minor numerically, skipped when uninitialised).
- [x] 4.3 Re-run `tests/test_submodule_sources.bats`; if an upstream rename removed a baseline `gstack/<skill>` entry, stop and list the missing entries in the PR body. Do not edit baseline curation.
- [x] 4.4 Commit message: `chore: bump gstack to <short sha> (VERSION <x.y.z.w>)`. Run `bash scripts/gate.sh`.

Acceptance: new version-floor test passes; no `gstack/<skill>` entry unresolved.

## 5. Runtime check in wire.sh plus the setup wrapper

Depends on: 2, 4, 8 (all edit or rely on `scripts/wire.sh`; the runtime link needs the fixed teardown).

Files: `scripts/wire.sh`, new `scripts/lib/runtimes.txt`, new `scripts/runtime-setup.sh`, new `tests/test_runtime.bats`, `CLAUDE.md`, `BOOTSTRAP.md`.

- [x] 5.1 Create `scripts/lib/runtimes.txt` with the header comment and the gstack row from design.md.
- [x] 5.2 `wire.sh`: after the repo-skills loop (step 2) and before the root-skills loop (step 3), read `$GRID_DIR/scripts/lib/runtimes.txt` (no file means skip). For each row whose repo passes `repo_is_wired || repo_has_skill_entries` (and not denied), create the runtime-root link (a real dir or a foreign symlink at that path: print `  skip (runtime root occupied, not managed): <link>` and a `skipped` manifest row) and run the marker check as specified. Emit manifest rows `runtime-link` and `runtime` (status `wired`/`skipped`, `ok`/`missing`). Exit status unaffected.
- [x] 5.3 `scripts/runtime-setup.sh <repo>` per design.md (steps 1-7, including the occupied-link pre-check in step 1, the `cmp`-based settings check, the snapshot-based removal in step 5 and the submodule-dirt report in step 6; exit codes 2 unknown/missing prerequisite/occupied link, 3 settings changed). Use `cp`, `cmp -s` and `diff`, not `sha256sum` or `shasum`. Env: `GRID_DIR`, `SKILLS_DIR`, `CLAUDE_CONFIG_DIR`, `HOME`. Support `--dry-run` that prints the command it would run and exits 0 without running it.
- [x] 5.4 `tests/test_runtime.bats` with a mock grid (`tests/helpers/setup.bash`): a `repos/gstack` with one skill, a copy of the map pointing at a stub `setup` script that logs its argv, creates a flat skill dir in the sandbox skills dir, and optionally edits the sandbox settings file when `STUB_TOUCH_SETTINGS=1`. Cases:
  - wire.sh with the marker missing: stdout contains `runtime MISSING: gstack`, exit 0, runtime link exists and resolves to `repos/gstack`;
  - marker present: no warning;
  - repo not in the baseline: no link, no warning;
  - second wire.sh run is byte-identical output and leaves the same symlinks (`wire.sh --check` exits 0);
  - runtime-setup: the stub's argv equals the flags in the map; flat dir removed; marker-independent wire re-run; a second run is a no-op;
  - runtime-setup with `STUB_TOUCH_SETTINGS=1` exits 3;
  - runtime-setup with `needs` command absent from `PATH` exits 2;
  - alias copy dirs survive and are listed;
  - the stub replaces a wired skill symlink with a real dir whose `SKILL.md` links outside `repos/gstack`: the wrapper removes it and the re-wire restores the symlink;
  - a real dir that existed before the run is left untouched;
  - `$SKILLS_DIR/gstack` pre-existing as a symlink to another dir: wire.sh prints `runtime root occupied` and leaves it; runtime-setup exits 2 and the stub never runs;
  - the stub modifies a tracked file in the mock `repos/gstack` (a git-init fixture): the wrapper prints the warning and still exits 0;
  - real-repo flag guard (skipped when `repos/gstack/setup` is absent): every `--flag` or `-q` token in the real `scripts/lib/runtimes.txt` gstack setup field appears in `repos/gstack/setup`.
- [x] 5.5 `CLAUDE.md`: add the runtime map, the exclusion rule, and `GRID_BASELINE` to the "wire.sh contract" section (three bullets). `BOOTSTRAP.md`: add a step "if a wired repo reports `runtime MISSING`, run `bash scripts/runtime-setup.sh <repo>`".
- [x] 5.6 Shellcheck clean: `shellcheck -S warning scripts/*.sh scripts/lib/*.sh`.

Acceptance: `tests/lib/bats-core/bin/bats tests/test_runtime.bats` passes.

## 6. HUMAN: gstack runtime setup on each machine

Depends on: 4, 5 merged to the working branch and pulled on the machine.

Files: none (run on each machine).

- [ ] 6.1 Prerequisites: `bun` installed (`./setup` exits with checksum-verified install instructions otherwise); network for Playwright Chromium (roughly 150 MB to 300 MB).
- [ ] 6.2 Back up the Claude settings file (`cp ~/.claude/settings.json ~/.claude/settings.json.pre-gstack`). If `~/.claude/skills/gstack` exists and is not a symlink to `<grid>/repos/gstack` (an earlier standalone gstack install), remove it first (`rm -rf ~/.claude/skills/gstack` after checking it holds nothing you want); the wrapper exits 2 until it is gone. Note that setup also persists gstack's own config under `~/.gstack/` (`skill_prefix`, `timeline_stop_hook`) and caches Playwright Chromium outside `~/.claude`; the settings check does not cover those.
- [ ] 6.3 `git pull`, `git submodule sync --recursive`, `git submodule update --init --recursive`.
- [ ] 6.4 `bash scripts/runtime-setup.sh gstack`. It runs `./setup --host claude --no-prefix --no-team --no-plan-tune-hooks --no-timeline-stop-hook -q`, aborts with exit 3 if the settings file changed, removes setup's flat skill dirs, and re-wires.
- [ ] 6.5 Verify: `bash scripts/wire.sh` prints no `runtime MISSING`; `test -x repos/gstack/browse/dist/browse`; `ls -l ~/.claude/skills/gstack` is a symlink to `repos/gstack`; `diff ~/.claude/settings.json ~/.claude/settings.json.pre-gstack` shows nothing; `repos/gstack/bin/gstack-settings-hook list-sources` lists no gstack sources; `git -C repos/gstack status --short` is empty (report any dirt, do not commit it).
- [ ] 6.6 In a throwaway repo, run `/browse` or `/qa` once and confirm the browse daemon starts.
- [ ] 6.7 Do this on each machine (macOS, Ubuntu, Arch). On Linux without the emoji font, `make-pdf` shows tofu for emoji; opt in with `GSTACK_SKIP_FONTS=0 bash scripts/runtime-setup.sh gstack` if sudo is acceptable.

Acceptance: 6.5 all true on each machine.

## 7. HUMAN: post-merge verification (Pages and catalogue)

Depends on: 2, 3, 9 merged to `main`.

Files: `SKILLS.md` (regenerated), none otherwise. One repo-settings change (7.2).

- [ ] 7.0 Apply the same mattpocock renames and deletions, and delete `-openspec/release-openspec`, in the personal `baseline-submodules.txt` and any machine overlay that lists them (gitignored, not committed).
- [ ] 7.1 On a machine with a personal `baseline-submodules.txt`, run `bash scripts/wire.sh` (regenerates `SKILLS.md`), then `bash scripts/gate.sh`; commit the regenerated `SKILLS.md`.
- [ ] 7.2 Switch the Pages source to GitHub Actions: repo Settings, Pages, Source = "GitHub Actions" (or `gh api -X PUT repos/<owner>/<repo>/pages -f build_type=workflow`, using the token of the account that owns the repo). Then re-run the latest `pages` workflow run on `main` (`gh run rerun <id>`, or `gh workflow run pages --ref main`).
- [ ] 7.3 After that run, check the `pages` run concluded `success` (`gh run list --workflow pages --branch main --limit 1`) and `curl -sI <pages-url> | head -1` is `200` (the repo is under a personal account: use that account's token for `gh`). Also confirm a push to `next` started a `tests` run (`gh run list --branch next --limit 1`), and confirm `repos/` is not served (`curl -sI <pages-url>repos/` returns 404).
- [ ] 7.4 If the `pages` run fails, open an issue with the failing step's log excerpt. Do not fix it inside this change; the legacy source with `.nojekyll` can be restored by switching the source back.
- [ ] 7.5 Confirm CI is green on `main` and that the ECC section count in `SKILLS.md` equals `find_skill_mds repos/ecc | wc -l` (source `scripts/lib/find-skill-mds.sh`).

Acceptance: Pages source is "GitHub Actions", the site returns 200 and `repos/` returns 404 (or the 7.4 issue exists); `SKILLS.md` committed and `bash scripts/catalog.sh --check` passes.

## 8. wire.sh teardown fixes and GRID_DRY_HOME

Depends on: 2 (both edit `scripts/wire.sh`). Other changes depend on this group as `foundations#8` (`multi-harness` task 1.5(c)).

Files: `scripts/wire.sh`, `tests/test_wiring.bats`, `tests/helpers/wired.bash`, `CLAUDE.md`.

- [x] 8.1 `teardown_grid_links` in `scripts/wire.sh`: change `[[ "$target" == "$GRID_DIR"* ]]` to `[[ "$target" == "$GRID_DIR"/* ]]`; change `find "$dir" -maxdepth 1 -type l` to `find -H "$dir" -maxdepth 1 -type l`. In the `--check` block, change `find "$1" -maxdepth 1 -type l` in `links()` to `find -H "$1" -maxdepth 1 -type l`. Add a comment on each saying why (sibling-prefix; symlinked skills dir).
- [x] 8.2 `tests/test_wiring.bats` (mock grid via `common_setup`): (a) a symlink in `$SKILLS_DIR` pointing into a sibling dir `${MOCK_GRID}-private/x` (create the sibling dir, remove it in the test) survives `wire.sh`; (b) a stale grid link `old -> $MOCK_GRID/repos/gone` in a real dir that `SKILLS_DIR` reaches through a symlink (`ln -s real link; SKILLS_DIR=link`) is removed by `wire.sh`; (c) the same setup with `wire.sh --check` exits 0 after a wire and exits 1 after planting a stale grid link; (d) existing wiring tests still pass. Before the fix (a) and (b) fail: confirm once by running them against the unfixed script.
- [x] 8.3 `CLAUDE.md` "wire.sh contract": one bullet saying teardown matches targets under `$GRID_DIR/` exactly and follows a symlinked skills/agents dir; one bullet for `GRID_DRY_HOME` (forces every home-derived target under it, skips catalog/manifest writes; every dry-run caller must use it).
- [x] 8.4 `GRID_DRY_HOME` in `scripts/wire.sh`, exactly per the design.md section "Dry home": immediately after `GRID_DIR` is set and before any home-derived default, if `GRID_DRY_HOME` is non-empty, `mkdir -p` it, `export HOME="$GRID_DRY_HOME"`, and force (not default) `SKILLS_DIR="$GRID_DRY_HOME/.claude/skills"`, `AGENTS_DIR="$GRID_DRY_HOME/.claude/agents"`, `CLAUDE_CONFIG_DIR="$GRID_DRY_HOME/.claude"`, `RULES_DIR="$GRID_DRY_HOME/.claude/rules"`, `GRID_HARNESS_HOME="$GRID_DRY_HOME"` (the last three exported), ignoring inherited values. It also sets `GRID_SKIP_CATALOG=1`, so a dry run writes neither `SKILLS.md` nor `.wired.manifest` in the repo. Add it to the header env-var list with the sentence "RULES_DIR and GRID_HARNESS_HOME are forced under it; every later home-derived target (~/.grid state) MUST be forced under it in this same block." The `--check` child run is switched from `SKILLS_DIR="$tmp/skills" AGENTS_DIR="$tmp/agents"` to `GRID_DRY_HOME="$tmp/home"`, and its comparison reads `$tmp/home/.claude/skills` and `$tmp/home/.claude/agents`.
- [x] 8.5 `tests/helpers/wired.bash`: replace the `SKILLS_DIR=… AGENTS_DIR=…` pair with `GRID_DRY_HOME="$tmp/home"` and read links from `$tmp/home/.claude/skills` (design.md sketch, final form).
- [x] 8.6 `tests/test_wiring.bats` (mock grid via `common_setup`): (a) fake real home: `HOME=$BATS_TEST_TMPDIR/realhome` with a sentinel file `realhome/.claude/skills/SENTINEL`, a stale grid link `realhome/.claude/skills/old -> $MOCK_GRID/repos/gone`, and `SKILLS_DIR`/`AGENTS_DIR`/`CLAUDE_CONFIG_DIR`/`RULES_DIR` exported pointing into `realhome` (`RULES_DIR=realhome/.claude/rules`, holding its own sentinel); run `wire.sh` with `GRID_DRY_HOME=$BATS_TEST_TMPDIR/dry`; assert `find realhome -exec ls -ld {} + | LC_ALL=C sort` is byte-identical before and after (sentinels and stale link untouched, nothing new under `realhome/.claude/rules`), `dry/.claude/skills` holds the mock skill link, and neither `$MOCK_GRID/.wired.manifest` nor `$MOCK_GRID/SKILLS.md` was created or changed; (b) the same with `wire.sh --check`: exit status 0 or 1, `realhome` listing unchanged; (c) `wire.sh --check` against a correctly wired live dir still exits 0 (regression for the 8.4 child switch).

Acceptance: `tests/lib/bats-core/bin/bats tests/test_wiring.bats` passes, including 8.6 (a) to (c).

## 9. Pages via GitHub Actions (index.html + assets only)

Depends on: none. `front-door` appends its assets to `site-files.txt`.

Files: new `.github/workflows/pages.yml`, new `site-files.txt`, new `scripts/stage-site.sh`, new `tests/test_pages_site.bats`, `CLAUDE.md` (one bullet under "Key files": `site-files.txt` + `scripts/stage-site.sh` define what Pages publishes). README does not mention Pages today; leave it.

- [x] 9.1 `site-files.txt` at the repo root: header comment ("Files published to GitHub Pages, one repo-relative path per line; directories are copied whole; `#` comments. front-door appends its assets here."), then `index.html` and `the-grid.png`.
- [x] 9.2 `scripts/stage-site.sh <out-dir>` per design.md "Pages deploy": `LC_ALL=C`, reads `$GRID_DIR/site-files.txt` (`GRID_DIR` default: parent of `scripts/`), skips blank and `#` lines, rejects (exit 2, message names the line) any path that is absolute, contains `..`, or starts with `repos/`, `.git` or `.github`; exits 1 naming the path when a listed path does not exist; recreates `<out-dir>` empty and copies each path to the same relative location (`mkdir -p` the parent, `cp -R`). Shellcheck clean.
- [x] 9.3 `.github/workflows/pages.yml` exactly as in design.md (push to `main` and `workflow_dispatch`; no submodules; `bash scripts/stage-site.sh _site`; `actions/configure-pages@v6`, `actions/upload-pages-artifact@v5` with `path: _site`, `actions/deploy-pages@v5`).
- [x] 9.4 `tests/test_pages_site.bats` (temp `GRID_DIR` fixtures, plus one real-repo case): (a) stages `index.html` and an image into the out dir and nothing else; (b) a missing listed path exits 1 and names it; (c) `repos/x`, `../x`, `/etc/x` and `.github/x` lines each exit 2; (d) a second run into the same out dir yields the same file list (stale files removed); (e) real repo: `bash scripts/stage-site.sh "$BATS_TEST_TMPDIR/site"` exits 0 and the staged dir contains `index.html` and no `repos/` dir; (f) real repo: every relative `src="…"`/`href="…"` in `index.html` (not `http`, `https`, `mailto`, `#`) exists in the staged dir.
- [x] 9.5 Keep `.nojekyll` (group 3.1) and its test 3.7(b): it is harmless under an Actions deploy and keeps the legacy source working if the switch in 7.2 is ever reverted.

Acceptance: `tests/lib/bats-core/bin/bats tests/test_pages_site.bats` passes; `bash scripts/gate.sh` passes. The live deploy is verified in HUMAN group 7.
