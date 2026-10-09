# Tasks

All groups: add the code comments the repo expects, keep shellcheck clean (`shellcheck -S warning`), keep `scripts/grid` runnable on Python 3.8+ with no third-party imports, never touch real `~/.claude` in tests (use `common_setup` from `tests/helpers/setup.bash`). Default verify command: `bash scripts/gate.sh`. Design reference: `design.md` (file formats, algorithms, `Decided:` list).

## 1. HTTPS submodule URLs (#37)

PR body: `Closes #37`. Depends on: none.

- [ ] 1.1 For each `git@github.com:` URL in `.gitmodules` (22), check `gh repo view <owner>/<repo> --json isPrivate`; rewrite public ones to `https://github.com/<owner>/<repo>.git`. Leave any private repo as SSH and list it in 1.3.
- [ ] 1.2 Run `git submodule sync`; regenerate `docs/SOURCES.md` with `bash scripts/sources.sh`; confirm `bash scripts/sources.sh --check` exits 0.
- [ ] 1.3 Add `tests/test_gitmodules_https.bats`: fails if any `.gitmodules` URL starts with `git@`, except names in an allowlist array at the top of the test (empty unless 1.1 found a private repo).
- Files: `.gitmodules`, `docs/SOURCES.md`, `tests/test_gitmodules_https.bats`.
- Acceptance: new bats test passes; `docs/SOURCES.md` has no `ᵍ` markers for converted entries; `git -C repos/<sample> fetch --dry-run` works for three converted repos.
- Verify: `bash scripts/gate.sh`.

## 2. grid CLI skeleton, grid.yaml, path

Depends on: none (can run parallel with 1).

- [ ] 2.1 Create `scripts/grid` (executable, `#!/usr/bin/env python3`, stdlib only). `argparse` subcommands registered now as stubs that exit 2 with "not implemented": `lock`, `install`, `doctor`, `repair`, `uninstall`, `drift`, `schedule`. Implemented now: `path`. Shared helpers: grid-dir resolution (`GRID_DIR` env, `--grid-dir`, else parent of `scripts/`), `LC_ALL=C` sorting, atomic write (temp + `os.replace`), run-git helper that fails loudly, exit codes 0/1/2 per design.
- [ ] 2.2 Implement the `grid.yaml` subset parser and validator in `scripts/grid` per design (comments, `key: scalar`, 2-space nesting; reject everything else with line number). Expose sources with `url`, `ref` default `HEAD`, `needs-setup` default false; require `version: 1` and `wired.baseline`.
- [ ] 2.3 Implement `grid path <source>/<skill>`: print the dir (submodule checkout if `repos/<source>/.git` exists, else store); search by directory basename among tracked skill dirs; exit 1 if none.
- [ ] 2.4 Create `grid.yaml` listing every source referenced by `baseline-submodules.example.txt` (names = `repos/` dir names; URLs identical to `.gitmodules` as of group 1 — if group 1 has not merged, use the HTTPS form and expect the check in 4.x to pass only after it). Mark `gstack` with `needs-setup: true`. `wired.baseline: baseline-submodules.example.txt`.
- [ ] 2.5 Add `tests/test_grid_manifest.bats`: valid parse; list item rejected with line number; missing source for a baseline repo; `git@` URL refused; `path` finds a skill in a fixture grid dir (fixture `GRID_DIR` under `mktemp`).
- Files: `scripts/grid`, `grid.yaml`, `tests/test_grid_manifest.bats`.
- Acceptance: `python3 -I scripts/grid path <source>/<skill>` works on the real repo; new bats pass; `python3 -m py_compile scripts/grid` clean.
- Verify: `bash scripts/gate.sh`.

## 3. wire.sh store fallback and GRID_BASELINE

Depends on: none (parallel with 1, 2).

- [ ] 3.1 In `scripts/wire.sh`: replace the baseline path with `${GRID_BASELINE:-$GRID_DIR/baseline-submodules.txt}` (document it in the header comment env list). Do not change `catalog.sh`.
- [ ] 3.2 In the repo-wiring loop, iterate the `LC_ALL=C` sorted union of directory names in `repos/` and `.grid/store/`; per name set `repo_dir` to `repos/<name>` if `-e repos/<name>/.git`, else `.grid/store/<name>` if it is a directory, else skip. Keep the existing whole-repo and per-skill branches and alphabetical precedence untouched.
- [ ] 3.3 Add `.grid/` and `.installed.manifest` to `.gitignore` (next to `.wired.manifest`).
- [ ] 3.4 Add `tests/test_wiring_store.bats`: store used when `repos/<n>` is an empty dir; submodule checkout (a `git init` dir) wins over store; no store gives identical links to before; `GRID_BASELINE` override honoured; `wire.sh --check` stays clean when wired from the store.
- Files: `scripts/wire.sh`, `.gitignore`, `tests/test_wiring_store.bats`.
- Acceptance: existing `tests/test_wiring.bats` passes unmodified; new tests pass.
- Verify: `bash scripts/gate.sh`.

## 4. grid lock and grid.lock

Depends on: 2, 3 (and 1 for URL equality).

- [ ] 4.1 Implement content hash, tree id and sha helpers in `scripts/grid` exactly per design (tracked files via `git ls-tree -r <sha> -- <path>`, mode class `x`/`-`/`l`, symlink escape check).
- [ ] 4.2 Implement `grid lock`: run `wire.sh` with `GRID_SKIP_CATALOG=1 GRID_BASELINE=<wired.baseline file> GRID_HOST=lock-none SKILLS_DIR=<tmp> AGENTS_DIR=<tmp>`; take symlinks whose target is under `repos/<source>/`; derive `source`, `path`; get `sha` from `git ls-files -s repos/<source>`; fail (exit 2) if the checkout `HEAD` differs or `git status --porcelain -- <path>` is non-empty; write `grid.lock` atomically. Warn (stderr, not failure) when a `SKILL.md` mentions `../`.
- [ ] 4.3 Implement `grid lock --check`: regenerate in memory, diff against `grid.lock`, exit 1 listing added/removed/changed skills; also run the manifest checks (every baseline repo has a source; source URL equals `.gitmodules`; HTTPS).
- [ ] 4.4 Generate and commit `grid.lock` from the real submodules (`python3 -I scripts/grid lock`).
- [ ] 4.5 Add the gate check: in `scripts/gate.sh` add `lock` check running `python3 -I scripts/grid lock --check`; skip loudly (SKIPPED, like the venv case) if `scripts/grid` or `python3` is missing, or any locked submodule is uninitialised. Update the header comment list. Extend `tests/test_gate.bats` so the existing copy-of-gate tests still pass (the check must self-skip when `scripts/grid` is absent in the throwaway repo).
- [ ] 4.6 Add `tests/test_grid_lock.bats` using a fixture: a temp parent git repo with a temp submodule-like checkout (`git init` under `repos/fix`, committed, gitlink added via `git update-index --add --cacheinfo 160000,<sha>,repos/fix`), a `grid.yaml` and a baseline file. Cases: lock content and sorting; second run byte-identical; dirty skill dir exits 2; changed content then `--check` exits 1; symlink escape exits 2.
- Files: `scripts/grid`, `grid.lock`, `scripts/gate.sh`, `tests/test_gate.bats`, `tests/test_grid_lock.bats`.
- Acceptance: `grid lock --check` exits 0 on the real repo after 4.4; entry count equals the number of repo-sourced links `wire.sh` makes for the example baseline.
- Verify: `bash scripts/gate.sh`.

## 5. grid install and the ledger

Depends on: 2, 3, 4.

- [ ] 5.1 Implement the fetch/verify/place routine in `scripts/grid` per design (init, `sparse-checkout set --cone`, `fetch --depth 1 --filter=blob:none origin <sha>`, checkout FETCH_HEAD, verify sha, tree, hash, copy without `.git`, swap via rename, stage under `.grid/tmp/` removed in a `finally`). URL policy: `https://` only unless `GRID_ALLOW_FILE=1` and `file://`.
- [ ] 5.2 Implement `grid install [--skills-dir DIR]`: seed `baseline-submodules.txt` and `machines/<host>.txt` from the tracked examples if absent (host via `GRID_HOST` else `hostname -s`); select lock entries minus deny lines; skip entries already matching ledger and lock; group by source; place; remove store dirs dropped from the selection; write the ledger; run `bash scripts/wire.sh`; print `needs-setup` and not-in-lock notices.
- [ ] 5.3 Implement ledger read/write (`.installed.manifest`, TSV columns per design, sorted `LC_ALL=C`, atomic, rewrite only on change) as functions reused by groups 6 and 7.
- [ ] 5.4 Add `tests/test_grid_install.bats` with a `file://` fixture upstream (bare-ish repo with `uploadpack.allowFilter=true` and `uploadpack.allowAnySHA1InWant=true`, two skills, one in a nested dir) and a fixture grid dir containing `grid.yaml`, `grid.lock` (generated by the fixture), the `wire.sh` and `find-skill-mds.sh` copied from `$REPO_ROOT/scripts`. Cases: fresh install places skills, no `.git` in store, links exist in `SKILLS_DIR`; second run does no fetch (assert via a `GRID_TRACE_FETCH` log file the code appends to on each fetch, empty on second run); tampered lock hash exits 1 and places nothing; non-HTTPS URL without the flag exits 2; overlay `-source/skill` skips it; `needs-setup` notice; ledger rows have no absolute paths; ledger mtime unchanged on no-op re-run.
- Files: `scripts/grid`, `tests/test_grid_install.bats`.
- Acceptance: new tests pass offline; manual (not in CI): in an empty temp dir, `git clone --filter=blob:none <repo> g && GRID_DIR=g SKILLS_DIR=$tmp/skills python3 g/scripts/grid install` installs a handful of real skills.
- Verify: `bash scripts/gate.sh`.

## 6. grid doctor, repair, uninstall

Depends on: 5.

- [ ] 6.1 Implement `grid doctor [--json]` per design (four checks, finding line format `<check> <kind> <name> <detail>`, exit 0/1, maintainer-mode message when no ledger; check 4 runs `bash scripts/wire.sh --check`).
- [ ] 6.2 Implement `grid repair [--prune]` reusing the group 5 fetch routine for missing/stale/absent/modified entries, then ledger rewrite and `wire.sh`.
- [ ] 6.3 Implement `grid uninstall [--yes] [--force]` per design: plan listing, dry-run default, path containment under `.grid/store/` via `os.path.realpath` plus `os.path.commonpath`, never follow symlinks (`os.lstat`), remove store-pointing links in the skills dir, remove empty parents it created, remove the ledger; skip modified dirs unless `--force`; second run reports nothing to remove.
- [ ] 6.4 Add `tests/test_grid_health.bats` (reuse the install fixture via `tests/helpers/`): clean doctor exit 0; edited file reports `modified`; deleted dir then repair then doctor 0; lock sha bump reports `stale` then repair; no ledger gives maintainer-mode message; uninstall dry run changes nothing; `--yes` removes only owned items and leaves a foreign symlink and a real dir; modified skill protected, `--force` removes it; second uninstall exits 0.
- Files: `scripts/grid`, `tests/test_grid_health.bats`, optionally `tests/helpers/grid_fixture.bash` (shared fixture builder extracted from group 5's test).
- Acceptance: new tests pass; `shellcheck` and `py_compile` clean.
- Verify: `bash scripts/gate.sh`.

## 7. grid drift and schedule

Depends on: 4 (parallel with 5 and 6).

- [ ] 7.1 Implement `grid drift [--quiet]` per design: `git ls-remote <url> <ref>` per source; for moved sources a trees-only fetch (`--depth 1 --filter=blob:none`) into a temp bare repo, compare `rev-parse FETCH_HEAD:<path>` with lock `tree`; classify unchanged/changed/removed/unreachable; write `drift-YYYY-MM-DD.md` and `drift-latest.md` to `${GRID_REPORT_DIR:-$HOME/.grid/reports}`; exit 0 on success. Report body has no absolute paths and no hostname.
- [ ] 7.2 Implement `grid schedule install|remove|status [--dry-run]`: detect Darwin, Linux with a working `systemctl --user show-environment`, else cron; generate plist / service+timer / tagged crontab line from in-code templates, command `<abs scripts/grid> drift --quiet`; idempotent; with `GRID_SCHEDULE_DIR` set write there and run no `launchctl`/`systemctl`/`crontab`; print the `loginctl enable-linger` notice on Linux. Add an override `GRID_SCHEDULER=launchd|systemd|cron` used by tests to force a branch.
- [ ] 7.3 Add `tests/test_grid_drift.bats`: fixture upstream with a second commit changing one of two skills; assert report lists the changed one, counts the other, lists a removed path, no-drift case says all current; `grid.lock`, ledger, store byte-identical before/after (checksum compare); schedule tests for each of the three mechanisms via `GRID_SCHEDULER` and `GRID_SCHEDULE_DIR`; double install yields one job; remove yields none.
- Files: `scripts/grid`, `tests/test_grid_drift.bats`.
- Acceptance: new tests pass offline; manual: `python3 scripts/grid drift` against the real lock writes a report and exits 0.
- Verify: `bash scripts/gate.sh`.

## 8. Drop the empty skills-factory from docs (#40)

PR body: `Closes #40`. Depends on: none.

- [ ] 8.1 `README.md`: delete the table row at the `skills-factory/` line (about 94) and the layout line (about 221); change nothing else (workstream 12 rewrites the README).
- [ ] 8.2 `automation-factory/README.md` (line 5) and `project-factory/README.md` (line 4): remove the `skills-factory/` cross-reference, saying skills are authored as `skills/<name>/SKILL.md` or via the wired `skill-creator` skill.
- [ ] 8.3 `rmdir skills-factory` if it exists (untracked, empty); `index.html` is NOT edited (workstream 12 owns the "four factories" copy).
- [ ] 8.4 Add `tests/test_docs_factories.bats`: no `skills-factory` match in `README.md`, `CLAUDE.md`, `automation-factory/README.md`, `project-factory/README.md`; `skills-factory/` absent or has tracked files.
- Files: `README.md`, `automation-factory/README.md`, `project-factory/README.md`, `tests/test_docs_factories.bats`.
- Acceptance: new test passes.
- Verify: `bash scripts/gate.sh`.

## 9. Docs for the install path

Depends on: 5, 6, 7, 8. PR body: `Closes #6` plus the comment text "Folded into manifest-lock-install: not populating agent-factory/skills/; `grid path <source>/<skill>` is the resolve-by-name primitive if option C is ever built."

- [ ] 9.1 `BOOTSTRAP.md`: add a "Install without submodules" section: `git clone --filter=blob:none <url> ~/.the-grid && ~/.the-grid/scripts/grid install`, then `grid doctor`, `grid repair`, `grid uninstall`, `grid schedule install`; keep the existing submodule path as "Maintainer path". State prerequisites (`python3` 3.8+, `git` 2.25+).
- [ ] 9.2 `CLAUDE.md`: add `grid.yaml`, `grid.lock`, `scripts/grid`, `.installed.manifest`, `.grid/store/` to Key files; add the `wire.sh` contract lines for the store fallback and `GRID_BASELINE`; add a Learnings bullet only if a real gotcha surfaced during groups 2-7.
- [ ] 9.3 `docs/` : do not add new files; no README changes (workstream 12).
- Files: `BOOTSTRAP.md`, `CLAUDE.md`.
- Acceptance: every command shown in the new BOOTSTRAP section exists in `python3 scripts/grid --help` output (verified by a one-line bats test added to `tests/test_grid_manifest.bats`).
- Verify: `bash scripts/gate.sh`.
