## Why

Installing the-grid today means cloning about 36 submodules to use roughly 120 wired skills. Nothing records what was installed, so drift cannot be detected, repaired or cleanly removed. Nothing pins a skill to a reviewed commit with a content hash, and upstream changes to wired skills are invisible until someone updates a submodule by hand. A stranger or a thin client needs one command that fetches only the curated set, verifies it, vets it, and can prove later that it is unmodified.

## What Changes

- Add `grid.yaml` (tracked): upstream sources (HTTPS URL, optional ref) and a pointer to the default wired set, which keeps the existing baseline grammar, including the typed entries other changes add (`project:`, `rules:<pack>`, `harness:<name>`).
- Add `grid.lock` (tracked, generated JSON): per wired skill, `kind`, source, 40-char commit sha, path, git tree id, content hash.
- Add one stdlib Python dispatcher, `scripts/grid`, with `lock`, `install`, `doctor`, `repair`, `uninstall`, `drift`, `schedule`, `audit`.
- `grid install` fetches only the locked skill directories over HTTPS (git partial clone plus sparse checkout at the pinned sha), verifies sha, tree and content hash, checks each source URL with `audit.py --check-url`, refuses to place anything when the `vetting` scanner is absent (unless `GRID_AUDIT=warn`), runs the scanner on the staged copy, re-checks and re-hashes the copy just before placing it, and places each verified skill at its normal `repos/<source>/<path>` inside the uninitialised submodule directory. `wire.sh` then wires it unchanged. No submodule is cloned.
- Add an install ledger at `~/.grid/installed.manifest` (machine-local state, per the `~/.grid/` convention).
- `grid install` and `grid repair` take `--dry-run`, validate every lock field before any write (no path can escape `repos/<source>`), and never overwrite a directory that differs from both the ledger and the lock without `--force`.
- `grid doctor` reports drift against ledger, lock and links; `grid repair` restores only what drifted; `grid uninstall` removes only ledger-listed files.
- `grid audit` is a passthrough to `scripts/audit.sh` (owned by `vetting`).
- Add an opt-in weekly upstream-drift report for wired skills (`~/.grid/reports/`); `grid schedule install` writes a launchd plist or systemd user units rendered by the shared `scripts/lib/render-schedule.sh` (owned by `loops`), or prints a crontab line. It never activates anything and never updates the lock.
- `wire.sh` gains one env var, `GRID_NO_CATALOG=1`, that skips only the `SKILLS.md` refresh, so wiring a partial install never dirties a tracked file.
- Fold #6 as a decision (no `agent-factory/skills/` population); resolve #40 by dropping the empty `skills-factory/` from docs.

## Capabilities

### New Capabilities

- `skill-manifest`: `grid.yaml` format, HTTPS-only sources matching `.gitmodules`, and the typed-entry reservation for rule packs and harnesses.
- `skill-lock`: `grid.lock` generation and check from submodule checkouts.
- `skill-install`: harness-neutral, submodule-free fetch, verify, vet and place.
- `install-ledger`: record of what grid wrote, where, with what hash.
- `install-health`: `grid doctor`, `grid repair`, `grid uninstall`.
- `upstream-drift`: weekly drift report and per-OS schedule files.
- `docs-accuracy`: public docs name only factories that exist.

### Modified Capabilities

None. `openspec/specs/` is empty; everything here is new.

## Impact

- New: `grid.yaml`, `grid.lock`, `scripts/grid`, `tests/test_grid_*.bats`, `tests/helpers/grid_fixture.bash`, `tests/test_docs_factories.bats`, `.grid-tmp/` (gitignored staging).
- Edited: `scripts/wire.sh` (one env var), `scripts/gate.sh` (one check), `.gitignore`, `BOOTSTRAP.md`, `CLAUDE.md`, `README.md` (two `skills-factory` lines only), `automation-factory/README.md`, `project-factory/README.md`.
- Machine-local, never committed: `~/.grid/installed.manifest`, `~/.grid/reports/drift-*.md`.
- Depends on: `foundations` (`GRID_BASELINE`, `GRID_DRY_HOME`, HTTPS `.gitmodules`, skill exclusions, runtime map), `vetting` (`scripts/lib/miniyaml.py`, `scripts/audit.py` incl. `--check-url`, `scripts/audit.sh`), `loops` (`scripts/lib/render-schedule.sh`, `tests/helpers/stubs.bash`).
- Requires `python3` (3.8+), `git` 2.25+ and network access to the source hosts for `install`, `repair` and `drift` only.
- Use case: a stranger or a thin client (macOS, Ubuntu, Arch) gets the curated skill set in one command at a small fraction of the clone weight, reproducibly, vetted, and can prove it is unmodified.

## Non-goals

- No composed agents, `project:` entries, rule packs or harness selection in the lock. Typed entries pass through to `wire.sh` untouched; the lock grammar reserves `kind` so a later change can add rule entries without a version bump. Root-owned `skills/` ship with the clone and are not locked.
- No auto-update. The lock changes only via the maintainer command, reviewed in a PR.
- No tarball or alternate fetch backend, and no non-HTTPS install (except `file://` in tests behind an env flag).
- No transitive dependency resolution, no marketplace, no lock for library-tier repos, no per-skill version ranges.
- No new vetting rules; `install` only calls the `vetting` scanner.
- No multi-harness emission (`multi-harness` owns it via `wire.sh`); placed files are harness-neutral.
- No runtime setup: sources listed in `scripts/lib/runtimes.txt` (gstack) are skipped by `install` with a notice pointing at the maintainer path for that one source.
- No timer activation (`launchctl`, `systemctl`, `crontab`, `loginctl` are printed, never run).
- No change to `compose.py` or `agent-factory/skills/`; populating it (#6) is not done.
- No Windows.
- No edit to `index.html` or the README beyond two lines; `front-door` owns both.
