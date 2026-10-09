# Tasks

All groups: add the code comments the repo expects, keep shellcheck clean (`shellcheck -S warning`), keep `scripts/grid` runnable on Python 3.8+ with no third-party imports, never touch real `~/.claude` or `~/.grid` in tests (use `common_setup` from `tests/helpers/setup.bash` and export `GRID_STATE_DIR` to a temp dir). Default verify command: `bash scripts/gate.sh`. Design reference: `design.md` (file formats, algorithms, `Decided:` list); copy its formats exactly, do not redesign.

## 1. grid CLI skeleton, grid.yaml, typed-entry reader, audit passthrough

Depends on: foundations#3 (HTTPS `.gitmodules`), vetting#1 (`scripts/lib/miniyaml.py`), vetting#3 (`scripts/audit.sh`).

- [ ] 1.1 Create `scripts/grid` (executable, `#!/usr/bin/env python3`, stdlib only, `sys.path` insert of `scripts/lib` from `__file__`). `argparse` subcommands registered as stubs that exit 2 with "not implemented": `lock`, `install`, `doctor`, `repair`, `uninstall`, `drift`, `schedule`. Shared helpers: grid-dir resolution (`--grid-dir`, `GRID_DIR`, else parent of `scripts/`), state dir (`GRID_STATE_DIR`, else `$HOME/.grid`), atomic write (temp + `os.replace`, skip when content unchanged), run-git helper (env `LC_ALL=C`, raises on non-zero with the command in the message), exit codes 0/1/2.
- [ ] 1.2 Implement `load_grid_yaml(grid_dir)` using `miniyaml.loads` with the key validation in design.md "File formats" (required `version: 1`, `sources.<name>.url`, optional `ref` default `HEAD`, required `wired.baseline`; reserved `rules`/`harnesses` ignored with the exact notice; any other unknown key exit 2 naming it; `miniyaml.ParseError` exit 2 with its line).
- [ ] 1.3 Implement `read_wired_entries(paths)` per design.md "Typed entries": strips `#` comments and whitespace like `wire.sh`'s `load_manifest`; returns untyped adds and denies; ignores every typed entry (`<kind>:...` and `-<kind>:...`, any kind).
- [ ] 1.4 Implement `grid audit [args...]`: run `bash <grid>/scripts/audit.sh args...`, return its exit code unchanged.
- [ ] 1.5 Create `grid.yaml` with the header comment from design.md, one source per repo referenced by an untyped entry in `baseline-submodules.example.txt` (key = `repos/` dir name, `url` copied from `.gitmodules`), and `wired.baseline: baseline-submodules.example.txt`.
- [ ] 1.6 Add `tests/test_grid_manifest.bats`: real `grid.yaml` loads; a list where a scalar is expected, an unknown key, and `version: 2` each exit 2 naming the line or key; `rules:` and `harnesses:` top-level keys load with the notice; `read_wired_entries` (via a tiny `python3 -c` import of `scripts/grid` as a module using `importlib.machinery.SourceFileLoader`) ignores `project:x`, `-project:x`, `rules:sql`, `-rules:sql`, `harness:codex`, `-harness:codex`, `future:y` and keeps `repo`, `repo/skill`, `-repo`, `-repo/skill`; `grid audit --owned` in a fixture grid with a stub `scripts/audit.sh` that exits 7 returns 7.
- Files: `scripts/grid`, `grid.yaml`, `tests/test_grid_manifest.bats`.
- Acceptance: new bats pass; `python3 -m py_compile scripts/grid` clean; every repo in an untyped line of `baseline-submodules.example.txt` is a key under `sources`.
- Verify: `bash scripts/gate.sh`.

## 2. grid lock, grid.lock, gate check

Depends on: 1, foundations#1 (skill exclusions), foundations#2 (`GRID_BASELINE`), foundations#5 (runtime-root link exists, must be excluded).

- [ ] 2.1 Implement the content-hash helpers in `scripts/grid` exactly per design.md: from git (`git ls-tree -r <sha> -- <path>`, mode to class, `git cat-file blob` for content) and from disk (class from `os.path.islink` / execute bits, every file under the dir); symlink-escape check (exit 2 naming the file).
- [ ] 2.2 Implement `grid lock` per design.md "grid lock" (wire.sh environment exactly as listed, link selection, gitlink sha, dirty/mismatch exit 2, `../` warning, entries with `kind: "skill"`, sort order, atomic write).
- [ ] 2.3 Implement `grid lock --check` (in-memory regeneration and diff, exit 1 listing added/removed/changed; manifest checks: HTTPS, URL equals `.gitmodules`, every untyped baseline repo has a source). Implement the lock reader with the unknown-`kind` skip and notice.
- [ ] 2.4 Generate `grid.lock` from the real submodules (`python3 scripts/grid lock`) and commit it.
- [ ] 2.5 `scripts/gate.sh`: add `run_lock_check` and `check lock run_lock_check` after `catalog`; skip loudly (append `lock` to `SKIPPED`, like `run_catalog_check`) when `python3` or `scripts/grid` is missing, or any `repos/<source>` named in `grid.lock` has no `.git`. Update the header comment list. Add a case to `tests/test_gate.bats` proving the check self-skips in the throwaway repo without `scripts/grid`.
- [ ] 2.6 Create `tests/helpers/grid_fixture.bash` with `make_upstream <dir>` (git repo, two skills `skills/alpha` and `nested/cat/beta`, one executable file, `uploadpack.allowFilter` and `uploadpack.allowAnySHA1InWant` true) and `make_grid_fixture <grid> <upstream>` (parent git repo; copies `scripts/grid`, `scripts/wire.sh`, `scripts/lib/find-skill-mds.sh`, `scripts/lib/miniyaml.py`; `repos/up` cloned from upstream and registered as a gitlink via `git update-index --add --cacheinfo 160000,<sha>,repos/up`; `grid.yaml` with `url: file://<upstream>`; baseline file `up`).
- [ ] 2.7 Add `tests/test_grid_lock.bats`: lock content and sorting, every entry has `kind: "skill"`, 40-hex `sha`, `sha256:` hash; second run byte-identical; dirty skill dir exits 2; checkout at another commit exits 2; changed content committed upstream and checked out without relock makes `--check` exit 1 naming the skill; symlink escaping the skill dir exits 2; a baseline containing `rules:sql`, `harness:codex`, `project:core` produces the same lock as without them; a lock containing a `kind: "rule"` entry is read with a notice and exit 0 by `--check`'s reader.
- Files: `scripts/grid`, `grid.lock`, `scripts/gate.sh`, `tests/test_gate.bats`, `tests/helpers/grid_fixture.bash`, `tests/test_grid_lock.bats`.
- Acceptance: `python3 scripts/grid lock --check` exits 0 on the real repo after 2.4; the entry count equals the number of repo-sourced skill links `wire.sh` makes for the example baseline (excluding the runtime-root link).
- Verify: `bash scripts/gate.sh`.

## 3. grid install, vetting at install, ledger, GRID_NO_CATALOG

Depends on: 2, vetting#1 (`scripts/audit.py`, `policy.yaml`).

- [ ] 3.1 `scripts/wire.sh`: wrap step 4 (`catalog.sh` refresh) so it also requires `-z "${GRID_NO_CATALOG:-}"`; add `GRID_NO_CATALOG=1` to the header env list. Nothing else in `wire.sh` changes.
- [ ] 3.2 Implement the fetch, verify and place routine per design.md "Fetch mechanism" and "Install algorithm" step 7 (staging `<grid>/.grid-tmp/<pid>/`, removed in `finally`; `-c protocol.file.allow=always` only when `GRID_ALLOW_FILE=1`; `GRID_TRACE_FETCH` append).
- [ ] 3.3 Implement the audit step per design.md "Vetting the staged copy" (per-source `audit.py` call, per-entry failure from JSON, `GRID_AUDIT=warn`, loud skip when `audit.py` or `policy.yaml` is absent).
- [ ] 3.4 Implement ledger read/write per design.md (path `${GRID_STATE_DIR:-$HOME/.grid}/installed.manifest`, columns, sort, atomic, unchanged-content skip, unknown-`kind` skip) as functions reused by group 4.
- [ ] 3.5 Implement `grid install` steps 1-12 exactly as in design.md, including the runtime-source skip (`scripts/lib/runtimes.txt`), the checkout skip, the no-op path and `GRID_NO_CATALOG=1 bash wire.sh`.
- [ ] 3.6 Add `tests/test_grid_install.bats` using `grid_fixture.bash`, but with `repos/up` left as an EMPTY dir that is still a gitlink in the parent index (no clone) and `grid.lock` written by running `grid lock` in a maintainer copy of the fixture first. Copy the real `policy.yaml` and `scripts/audit.py` into the fixture grid. Cases: fresh install places both skills under `repos/up/...` with no `.git` in `repos/up`, links exist in `SKILLS_DIR`, `git -C <grid> status --porcelain --untracked-files=no` is empty, `SKILLS.md` not created; second run appends nothing to `GRID_TRACE_FETCH` and leaves the ledger mtime unchanged; tampered lock hash exits 1 and places nothing for that skill; non-HTTPS URL without `GRID_ALLOW_FILE` exits 2 and appends nothing to the trace; overlay `-up/beta` skips beta; overlay containing `rules:sql` and `harness:codex` changes nothing; a skill whose file contains a `curl ... | sh` line is not placed and exit is 1, while the other skill is placed; same with `GRID_AUDIT=warn` places both; a source listed in a fixture `scripts/lib/runtimes.txt` is skipped with the notice; a `repos/up/.git` checkout is left untouched with the notice; ledger rows have `dest` starting `repos/` and no absolute path; `wire.sh` with `GRID_NO_CATALOG=1` writes `.wired.manifest` but not `SKILLS.md`.
- Files: `scripts/grid`, `scripts/wire.sh`, `.gitignore` (add `.grid-tmp/`), `tests/test_grid_install.bats`.
- Acceptance: new tests pass offline; existing `tests/test_wiring.bats` and `tests/test_catalog.bats` pass unmodified.
- Verify: `bash scripts/gate.sh`.

## 4. grid doctor, repair, uninstall

Depends on: 3.

- [ ] 4.1 Implement `grid doctor [--json]` per design.md (four checks, finding format, sorting, exit 0/1, maintainer-mode message when no ledger).
- [ ] 4.2 Implement `grid repair [--prune]` reusing group 3's fetch, verify, audit and place routine, then ledger rewrite and `GRID_NO_CATALOG=1 bash wire.sh`.
- [ ] 4.3 Implement `grid uninstall [--yes] [--force]` per design.md (plan listing, dry-run default, containment via `realpath` plus `commonpath`, `.git` refusal, `os.lstat` symlink refusal, link removal by exact `readlink` match, empty-parent cleanup stopping at `repos/<source>`, modified-dir protection, ledger removal, `nothing to remove` on a second run).
- [ ] 4.4 Add `tests/test_grid_health.bats` (fixture from `grid_fixture.bash` plus a completed install): clean doctor exits 0; edited file reports `disk skill <name> modified`; deleted dir, then repair, then doctor exits 0; lock `sha`/`hash` bumped to a second upstream commit reports `stale`, repair fixes it; no ledger prints maintainer mode; `--json` output parses with `python3 -m json.tool`; uninstall without `--yes` changes nothing (compare `find` listings); `--yes` removes only owned dirs and links, leaving a foreign symlink, a real dir in `SKILLS_DIR`, and `repos/up` itself; modified skill skipped then removed with `--force`; second uninstall exits 0 with `nothing to remove`.
- Files: `scripts/grid`, `tests/test_grid_health.bats`.
- Acceptance: new tests pass; `py_compile` clean.
- Verify: `bash scripts/gate.sh`.

## 5. grid drift and schedule

Depends on: 2, loops#3 (`scripts/lib/render-schedule.sh`).

- [ ] 5.1 Implement `grid drift [--quiet]` per design.md "Drift report" (ls-remote, trees-only fetch into `.grid-tmp/<pid>/`, classification, report path under `${GRID_STATE_DIR:-$HOME/.grid}/reports/`, `drift-latest.md` copy, exit codes, no absolute paths or hostname in the body).
- [ ] 5.2 Implement `grid schedule install|remove` per design.md "Schedule": OS choice (`GRID_OS`, else `uname -s` plus the `systemctl --user show-environment` probe), rendering through `scripts/lib/render-schedule.sh` with the arguments documented in its header, output dirs from `LAUNCH_AGENTS_DIR` / `SYSTEMD_USER_DIR`, printed activation and deactivation commands, cron line printed only. Never run `launchctl`, `systemctl` (other than the read-only probe) or `crontab`.
- [ ] 5.3 Add `tests/test_grid_drift.bats`: fixture upstream with a second commit changing `alpha` only and a third deleting `beta`; report lists `alpha` changed with both short shas and counts the rest; removed path listed; unchanged upstream says all current and appends nothing to `GRID_TRACE_FETCH`; unreachable `file://` path listed as unreachable with exit 0; `grid.lock`, the ledger and `repos/` are byte-identical before and after (`shasum` of a sorted file listing); schedule with `GRID_OS=Darwin` writes the plist, `GRID_OS=Linux` writes both units, `GRID_OS=Other` writes nothing and prints a line ending `# the-grid drift`; a second `install` leaves files byte-identical; `remove` deletes them; a `PATH` containing stub `launchctl`/`systemctl`/`crontab` that write a marker file proves none was called (except the probe, which the `GRID_OS` override skips).
- Files: `scripts/grid`, `tests/test_grid_drift.bats`.
- Acceptance: new tests pass offline; manual (not in CI): `python3 scripts/grid drift` against the real lock writes a report and exits 0.
- Verify: `bash scripts/gate.sh`.

## 6. Drop the empty skills-factory from docs (#40)

PR body: `Closes #40`. Depends on: none.

- [ ] 6.1 `README.md`: delete the table row on the `skills-factory/` line (line 94) and the layout line (line 221); change nothing else.
- [ ] 6.2 `automation-factory/README.md` (lines 3-5) and `project-factory/README.md` (line 4): remove the `skills-factory/` cross-reference; where a sentence needs a replacement, say skills are authored as `skills/<name>/SKILL.md` or with the wired `skill-creator` skill.
- [ ] 6.3 `rmdir skills-factory` if it exists and is empty (it is untracked); do not edit `index.html`.
- [ ] 6.4 Add `tests/test_docs_factories.bats`: no `skills-factory` match in `README.md`, `CLAUDE.md`, `automation-factory/README.md`, `project-factory/README.md`; `skills-factory/` absent or has tracked files (`git ls-files skills-factory` non-empty).
- Files: `README.md`, `automation-factory/README.md`, `project-factory/README.md`, `tests/test_docs_factories.bats`.
- Acceptance: new test passes.
- Verify: `bash scripts/gate.sh`.

## 7. Docs for the install path

Depends on: 3, 4, 5, 6. PR body: `Closes #6` plus the comment "Folded into manifest-lock-install: not populating agent-factory/skills/; installed skills sit at the same repos/<source>/<path> as on the maintainer path, so a future resolve-by-name works on both."

- [ ] 7.1 `BOOTSTRAP.md`: add an "Install without submodules" section: `git clone --filter=blob:none https://github.com/<your-username>/the-grid.git ~/.the-grid && python3 ~/.the-grid/scripts/grid install` (same placeholder as the existing clone line), then `grid doctor`, `grid repair`, `grid uninstall`, `grid audit --wired`, `grid schedule install`; note that re-wiring on such a machine is `GRID_NO_CATALOG=1 bash scripts/wire.sh`; note that `git submodule update --init` refuses a source that `grid` populated (run `grid uninstall --yes` first to switch to the maintainer path); keep the existing submodule path as "Maintainer path". State prerequisites (`python3` 3.8+, `git` 2.25+).
- [ ] 7.2 `CLAUDE.md`: add `grid.yaml`, `grid.lock`, `scripts/grid`, `~/.grid/installed.manifest` to Key files; add `GRID_NO_CATALOG` and "`grid` ignores typed entries (`project:`, `rules:`, `harness:`)" to the `wire.sh` contract; add a Learnings bullet only if a real gotcha surfaced during groups 1-5.
- [ ] 7.3 Add one bats case to `tests/test_grid_manifest.bats`: every `grid <subcommand>` named in the new `BOOTSTRAP.md` section appears in `python3 scripts/grid --help`.
- Files: `BOOTSTRAP.md`, `CLAUDE.md`, `tests/test_grid_manifest.bats`.
- Acceptance: the new case passes.
- Verify: `bash scripts/gate.sh`.
