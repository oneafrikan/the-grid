# Tasks

Verify command for every group unless stated: `bash scripts/gate.sh`. Tests are bats and never touch the real `~/.claude` (use `SKILLS_DIR`, `AGENTS_DIR`, `GRID_DIR`, `GRID_HOST` overrides as `tests/helpers/setup.bash` does). Shell is bash and shellcheck-clean; comment generously.

## 1. Skill discovery exclusion

Depends on: none.

Files: `scripts/lib/find-skill-mds.sh`, new `scripts/lib/skill-excludes.txt`, new `tests/test_skill_discovery.bats`, `CLAUDE.md` (one bullet in "wire.sh contract").

- [ ] 1.1 Add an `_skill_excluded <repo-name> <relative-path>` helper to `find-skill-mds.sh` implementing the three rules in design.md (translation dirs, root-level dot-dir, listed prefix from `scripts/lib/skill-excludes.txt` located via `BASH_SOURCE`). Apply it to the output of both branches (git `ls-files` and `find` fallback). Keep the output contract (absolute paths, one per line).
- [ ] 1.2 Create `scripts/lib/skill-excludes.txt` with the header comment and the single row `ecc | pi/`.
- [ ] 1.3 Rewrite the header comment of `find-skill-mds.sh`: it currently says skills tracked inside dot-dirs are honoured; state the new rule and why.
- [ ] 1.4 Write `tests/test_skill_discovery.bats` with fixtures under `mktemp -d` (both a plain dir and a `git init` + `git add` + commit fixture, so both branches run):
  - keeps `skills/a/SKILL.md` and a nested `engineering/b/SKILL.md`;
  - drops `docs/ja-JP/skills/a/SKILL.md`, `docs/tr/skills/a/SKILL.md`, `i18n/zh-CN/a/SKILL.md`;
  - keeps `docs/guides/a/SKILL.md` (not a locale);
  - drops `.kiro/skills/a/SKILL.md`, `.agents/skills/a/SKILL.md`;
  - drops `pi/core/a/SKILL.md` only when the fixture dir is named `ecc`;
  - a real-repo test (skipped when `repos/ecc` is uninitialised): no path from `find_skill_mds repos/ecc` contains `/docs/` or `/.`, and every path is under `skills/`.
- [ ] 1.5 `wire.sh` and `catalog.sh` need no code change (they source the helper); add one catalog test: a mock repo with a `.kiro` copy and a `skills/` skill reports count 1 in the section header.
- [ ] 1.6 If `baseline-submodules.txt` exists on this machine, run `bash scripts/catalog.sh` and include the regenerated `SKILLS.md`; otherwise leave `SKILLS.md` untouched and write "SKILLS.md needs regeneration on a baseline machine" in the PR body.

Acceptance: `tests/lib/bats-core/bin/bats tests/test_skill_discovery.bats` passes; `find_skill_mds repos/ecc | wc -l` prints 293 (if `repos/ecc` is initialised).

## 2. CI that means the gate

Depends on: 1.

Files: `.github/workflows/tests.yml`, `scripts/wire.sh` (add `GRID_BASELINE`), new `tests/helpers/wired.bash`, `tests/test_skill_format.bats`, `tests/test_repo_health.bats`.

- [ ] 2.1 `wire.sh`: replace the hard-coded `$GRID_DIR/baseline-submodules.txt` in the first `load_manifest` call with `${GRID_BASELINE:-$GRID_DIR/baseline-submodules.txt}`; document the variable in the header comment.
- [ ] 2.2 Add `tests/helpers/wired.bash` with `wired_skill_dirs` exactly as sketched in design.md.
- [ ] 2.3 `tests/test_skill_format.bats`: delete the baseline parsing and `all_wired_skill_dirs`; load the helper and have the three "wired" tests iterate `wired_skill_dirs`. Keep the "no duplicate skill names in root-level skills" test as is.
- [ ] 2.4 `tests/test_repo_health.bats`: `skills dir exists` calls `skip "no skills dir on a CI runner"` when `CI=true` and the dir is absent; add `agent-factory venv exists when CI=true` (skips when `CI` is unset, fails when `CI=true` and `agent-factory/.venv/bin/python` is missing).
- [ ] 2.5 Rewrite `.github/workflows/tests.yml` as in design.md (triggers `main` and `next` pushes plus pull requests; build venv; run `bash scripts/gate.sh`).
- [ ] 2.6 Run the venv-dependent tests locally with the venv built; for any test that fails only because of the runner environment, add an explicit `skip "<reason>"`. Never delete a test.
- [ ] 2.7 Push the branch and read the CI run: all steps green, and the bats output contains zero lines matching `skip agent-factory venv not built`.

Acceptance: new test `agent-factory venv exists when CI=true` passes in CI; `CI=true bash scripts/gate.sh` passes locally with no personal baseline (rename it temporarily to prove it, restore after); the three previously failing tests pass.

## 3. Pages, HTTPS submodule URLs, example-baseline fix

Depends on: none (touches different files from 1 and 2).

Files: new `.nojekyll`, `.gitmodules`, `docs/SOURCES.md`, `baseline-submodules.example.txt`, new `tests/test_submodule_sources.bats`, `BOOTSTRAP.md`.

- [ ] 3.1 Add an empty `.nojekyll` at the repo root.
- [ ] 3.2 For each of the 22 `git@github.com:` entries in `.gitmodules`, confirm public with `GH_PAGER= gh repo view <owner>/<repo> --json isPrivate`; rewrite to `https://github.com/<owner>/<repo>.git`. List any private exception in the PR body and leave it SSH.
- [ ] 3.3 Run `git submodule sync --recursive`; confirm `git -C repos/<name> fetch --dry-run` works for three of the converted repos.
- [ ] 3.4 Regenerate `docs/SOURCES.md` per the Decided rule (script when a personal baseline exists, otherwise hand-remove the SSH marker and footnote).
- [ ] 3.5 `baseline-submodules.example.txt`: change `(29 skills)` on the gstack header to `(42 skills)`.
- [ ] 3.6 `BOOTSTRAP.md`: add "after pulling a change to `.gitmodules`, run `git submodule sync --recursive`" next to the submodule step.
- [ ] 3.7 `tests/test_submodule_sources.bats`: (a) no `.gitmodules` URL starts with `git@` or `ssh://`; (b) `.nojekyll` exists at the repo root; (c) the gstack header count in the example baseline equals its number of `gstack/` entry lines; (d) every `gstack/<skill>` entry in the example baseline matches a skill dir from `find_skill_mds repos/gstack` (skip when the submodule is uninitialised); (e) `sources.sh` output has no ` ᵍ` marker (run `bash scripts/sources.sh /dev/stdout` if it supports an output path, else grep `docs/SOURCES.md`).

Acceptance: `tests/lib/bats-core/bin/bats tests/test_submodule_sources.bats` passes; `grep -c 'git@' .gitmodules` prints 0.

## 4. Bump the gstack pin

Depends on: 1, 3.

Files: `repos/gstack` (submodule pointer only), new test in `tests/test_submodule_sources.bats`.

- [ ] 4.1 `git -C repos/gstack fetch origin`; check out the `origin/HEAD` commit. Read `repos/gstack/VERSION`; abort with a note in the PR body if it is below `1.91`.
- [ ] 4.2 Add test `gstack pin is at least 1.91` (reads `repos/gstack/VERSION`, compares major.minor numerically, skipped when uninitialised).
- [ ] 4.3 Re-run groups 3.7(c) and (d); if an upstream rename removed a baseline `gstack/<skill>` entry, stop and list the missing entries in the PR body. Do not edit baseline curation beyond the header count.
- [ ] 4.4 Commit message: `chore: bump gstack to <short sha> (VERSION <x.y.z.w>)`. Run `bash scripts/gate.sh`.

Acceptance: new version-floor test passes; no `gstack/<skill>` entry unresolved.

## 5. Runtime check in wire.sh plus the setup wrapper

Depends on: 2 (both edit `scripts/wire.sh`).

Files: `scripts/wire.sh`, new `scripts/lib/runtimes.txt`, new `scripts/runtime-setup.sh`, new `tests/test_runtime.bats`, `CLAUDE.md`, `BOOTSTRAP.md`.

- [ ] 5.1 Create `scripts/lib/runtimes.txt` with the header comment and the gstack row from design.md.
- [ ] 5.2 `wire.sh`: after the repo-skills loop (step 2) and before the root-skills loop (step 3), read `$GRID_DIR/scripts/lib/runtimes.txt` (no file means skip). For each row whose repo passes `repo_is_wired || repo_has_skill_entries` (and not denied), create the runtime-root link and run the marker check as specified. Emit manifest rows `runtime-link` and `runtime` (status `wired`/`skipped`, `ok`/`missing`). Exit status unaffected.
- [ ] 5.3 `scripts/runtime-setup.sh <repo>` per design.md (steps 1-7; exit codes 2 unknown/missing prerequisite, 3 settings changed). Env: `GRID_DIR`, `SKILLS_DIR`, `CLAUDE_CONFIG_DIR`, `HOME`. Support `--dry-run` that prints the command it would run and exits 0 without running it.
- [ ] 5.4 `tests/test_runtime.bats` with a mock grid (`tests/helpers/setup.bash`): a `repos/gstack` with one skill, a copy of the map pointing at a stub `setup` script that logs its argv, creates a flat skill dir in the sandbox skills dir, and optionally edits the sandbox settings file when `STUB_TOUCH_SETTINGS=1`. Cases:
  - wire.sh with the marker missing: stdout contains `runtime MISSING: gstack`, exit 0, runtime link exists and resolves to `repos/gstack`;
  - marker present: no warning;
  - repo not in the baseline: no link, no warning;
  - second wire.sh run is byte-identical output and leaves the same symlinks (`wire.sh --check` exits 0);
  - runtime-setup: the stub's argv equals the flags in the map; flat dir removed; marker-independent wire re-run; a second run is a no-op;
  - runtime-setup with `STUB_TOUCH_SETTINGS=1` exits 3;
  - runtime-setup with `needs` command absent from `PATH` exits 2;
  - alias copy dirs survive and are listed.
- [ ] 5.5 `CLAUDE.md`: add the runtime map, the exclusion rule, and `GRID_BASELINE` to the "wire.sh contract" section (three bullets). `BOOTSTRAP.md`: add a step "if a wired repo reports `runtime MISSING`, run `bash scripts/runtime-setup.sh <repo>`".
- [ ] 5.6 Shellcheck clean: `shellcheck -S warning scripts/*.sh scripts/lib/*.sh`.

Acceptance: `tests/lib/bats-core/bin/bats tests/test_runtime.bats` passes.

## 6. HUMAN: gstack runtime setup on each machine

Depends on: 4, 5 merged to the working branch and pulled on the machine.

Files: none (run on each machine).

- [ ] 6.1 Prerequisites: `bun` installed (`./setup` exits with checksum-verified install instructions otherwise); network for Playwright Chromium (roughly 150 MB to 300 MB).
- [ ] 6.2 Back up the Claude settings file (`cp ~/.claude/settings.json ~/.claude/settings.json.pre-gstack`).
- [ ] 6.3 `git pull`, `git submodule sync --recursive`, `git submodule update --init --recursive`.
- [ ] 6.4 `bash scripts/runtime-setup.sh gstack`. It runs `./setup --host claude --no-prefix --no-team --no-plan-tune-hooks --no-timeline-stop-hook -q`, aborts with exit 3 if the settings file changed, removes setup's flat skill dirs, and re-wires.
- [ ] 6.5 Verify: `bash scripts/wire.sh` prints no `runtime MISSING`; `test -x repos/gstack/browse/dist/browse`; `ls -l ~/.claude/skills/gstack` is a symlink to `repos/gstack`; `diff ~/.claude/settings.json ~/.claude/settings.json.pre-gstack` shows nothing; `repos/gstack/bin/gstack-settings-hook list-sources` lists no gstack sources; `git -C repos/gstack status --short` is empty (report any dirt, do not commit it).
- [ ] 6.6 In a throwaway repo, run `/browse` or `/qa` once and confirm the browse daemon starts.
- [ ] 6.7 Do this on each machine (macOS, Ubuntu, Arch). On Linux without the emoji font, `make-pdf` shows tofu for emoji; opt in with `GSTACK_SKIP_FONTS=0 bash scripts/runtime-setup.sh gstack` if sudo is acceptable.

Acceptance: 6.5 all true on each machine.

## 7. HUMAN: post-merge verification (Pages and catalogue)

Depends on: 2, 3 merged to `main` (the Pages source branch).

Files: `SKILLS.md` (regenerated), none otherwise.

- [ ] 7.1 On a machine with a personal `baseline-submodules.txt`, run `bash scripts/wire.sh` (regenerates `SKILLS.md`), then `bash scripts/gate.sh`; commit the regenerated `SKILLS.md`.
- [ ] 7.2 After the `main` push, check `gh api repos/<owner>/<repo>/pages/builds/latest --jq .status` is `built` and `curl -sI <pages-url> | head -1` is `200`.
- [ ] 7.3 If the build still errors or the published size is over 1 GB, open a follow-up issue "Pages: deploy via Actions (index.html + assets only)". Do not fix it inside this change.
- [ ] 7.4 Confirm CI is green on `main` and that `ECC` shows 293 in `SKILLS.md`.

Acceptance: Pages returns 200 or the follow-up issue exists; `SKILLS.md` committed and `bash scripts/catalog.sh --check` passes.
