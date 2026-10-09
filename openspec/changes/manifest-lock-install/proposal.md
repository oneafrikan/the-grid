## Why

Installing the-grid today means cloning about 36 submodules to use roughly 120 skills, and 22 of the submodule URLs are SSH, so a fresh machine can fail at step one (#37). Nothing records what was installed, so drift cannot be detected, repaired or cleanly removed. Nothing pins a skill to a reviewed commit with a content hash. Upstream changes to wired skills are invisible until someone updates a submodule by hand.

## What Changes

- Add `grid.yaml` (tracked): upstream sources (HTTPS URL, optional ref) and a pointer to the default wired set, which keeps the existing baseline grammar.
- Add `grid.lock` (tracked, generated): per wired skill, source, 40-char commit sha, path, git tree id, content hash.
- Add one stdlib Python dispatcher, `scripts/grid`, with `lock`, `install`, `doctor`, `repair`, `uninstall`, `drift`, `schedule`, `path`.
- `grid install` fetches only the locked skill directories over HTTPS (git partial and sparse fetch at the pinned sha), verifies hashes, and places them in a gitignored store that `wire.sh` reads. No submodule is cloned.
- Add an install ledger, `.installed.manifest`, next to `.wired.manifest`.
- `grid doctor` reports drift against ledger, lock and links; `grid repair` restores only what drifted; `grid uninstall` removes only ledger-listed files.
- Add an opt-in weekly upstream-drift report for wired skills, scheduled by launchd, a systemd user timer, or cron. It writes a report and never updates anything.
- Convert the 22 SSH submodule URLs to HTTPS (#37); fold #6 as a decision (no `agent-factory/skills/` population, `grid path` instead); resolve #40 by dropping the empty `skills-factory/` from docs.
- `wire.sh` gains two small additive features: a store fallback per repo name, and a `GRID_BASELINE` override. The maintainer path (submodules, `bootstrap.sh`, `wire.sh`) behaves exactly as before.

## Capabilities

### New Capabilities

- `skill-manifest`: `grid.yaml` format and its consistency with `.gitmodules`; HTTPS-only sources.
- `skill-lock`: `grid.lock` generation and check from submodule checkouts.
- `skill-install`: harness-neutral, submodule-free fetch, verify and place.
- `skill-wiring`: `wire.sh` reads the install store; maintainer path unchanged.
- `install-ledger`: record of what grid wrote, where, with what hash.
- `install-health`: `grid doctor`, `grid repair`, `grid uninstall`.
- `upstream-drift`: weekly drift report and per-OS scheduler.
- `docs-accuracy`: public docs name only factories that exist.

### Modified Capabilities

None. `openspec/specs/` is empty; everything here is new.

## Impact

- New: `grid.yaml`, `grid.lock`, `scripts/grid`, `tests/test_grid_*.bats`, `.installed.manifest` and `.grid/` (both gitignored).
- Edited: `.gitmodules` (22 URLs), `docs/SOURCES.md` (regenerated), `scripts/wire.sh` (additive), `scripts/gate.sh` (one check), `.gitignore`, `BOOTSTRAP.md`, `CLAUDE.md`, `README.md` (two `skills-factory` lines only), `automation-factory/README.md`, `project-factory/README.md`.
- Requires `python3` (3.8+), `git` 2.25+ and network access to the source hosts for `install`/`drift` only.
- Use case: a stranger or a thin client (Mac, Ubuntu, Arch) gets the curated skill set in one command at a small fraction of the clone weight, reproducibly, and can prove it is unmodified.

## Non-goals

- No composed agents, `project:` entries, or `agent-factory` output in the lock. Those stay on `bootstrap.sh --with-agents`. Root-owned `skills/` ship with the clone and are not locked.
- No auto-update. Lock changes only via the maintainer command, reviewed in a PR.
- No tarball or alternate fetch backend, and no non-HTTPS install (except `file://` in tests behind an env flag).
- No transitive dependency resolution, no marketplace, no lock for library-tier repos, no per-skill version ranges.
- No vetting or pattern scanning (workstream 4 `vetting` hooks into `grid install` later).
- No multi-harness emission (workstream 11); `install` places harness-neutral files and wires to `SKILLS_DIR` (default the Claude skills dir).
- No gstack runtime setup (workstream 1); `install` only prints a notice for sources flagged `needs-setup`.
- No change to `compose.py` or `agent-factory/skills/`; populating it (#6) is not done.
- No Windows.
- No edit to `index.html`; its "four factories" copy belongs to workstream 12 `front-door`.
