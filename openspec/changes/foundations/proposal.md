## Why

The commit gate is the unattended loop's only truth signal, and today it is not trustworthy: CI never builds the agent-factory venv (about 81 tests skip), three tests always fail on a runner, the Pages site returns 404, the ECC submodule is counted as 1027 skills when only 293 are real, and gstack's skills are wired without the runtime they call. Nothing downstream (loop, install, budget, hooks) can be verified until these are fixed.

## What Changes

- CI: runs on pushes to `main` and `next` and on every pull request; builds the agent-factory venv, runs `scripts/gate.sh`, fails loudly if the venv is missing; the live-skills-dir test skips on runners.
- `wire.sh` gains `GRID_BASELINE` (override path to the baseline manifest). Tests that scan "wired" skills run the real `wire.sh` into a temp dir with it instead of re-implementing discovery. Later changes depend on this variable.
- Pages: add `.nojekyll`; convert the 22 SSH submodule URLs in `.gitmodules` to HTTPS (issue #37) and regenerate `docs/SOURCES.md`.
- Skill discovery: `find_skill_mds` (shared by `wire.sh` and `catalog.sh`) drops locale translations, root-level harness-copy dot-dirs, and per-repo listed paths (ECC 1027 to 293).
- Runtime check: a declarative `scripts/lib/runtimes.txt` plus a `wire.sh` check and runtime-root link; a `scripts/runtime-setup.sh` wrapper that runs gstack `./setup` without registering global hooks.
- Bump the gstack pin to the latest upstream release (no tags exist upstream; use the head commit, VERSION 1.91.x or newer).
- `baseline-submodules.example.txt`: fix the stale gstack count (29 to 42), rename or drop the 8 mattpocock entries that no longer resolve upstream (count 21 to 17), drop the `-openspec/release-openspec` subtraction the exclusion rule makes dead; a test asserts every positive per-skill entry in every repo resolves and every per-skill section header count is true.

## Capabilities

### New Capabilities
- `ci-gate`: CI runs the real gate with the venv on `main`, `next` and PRs; wired-skill tests use `wire.sh` via `GRID_BASELINE`.
- `pages-site`: the static site publishes without Jekyll.
- `submodule-sources`: HTTPS-only public submodule URLs, a gstack version floor, and an example baseline whose entries all resolve.
- `skill-discovery`: one shared exclusion rule for translations and harness copies.
- `runtime-check`: per-submodule runtime markers, a runtime-root link, and a hook-free runtime setup wrapper.

### Modified Capabilities
- None (no specs exist yet under `openspec/specs/`).

## Impact

- Files: `.github/workflows/tests.yml`, `tests/test_repo_health.bats`, `tests/test_skill_format.bats`, `tests/test_wiring.bats`, new `tests/helpers/wired.bash`, new `tests/test_skill_discovery.bats`, `tests/test_submodule_sources.bats`, `tests/test_runtime.bats`, `scripts/lib/find-skill-mds.sh`, new `scripts/lib/skill-excludes.txt`, `scripts/wire.sh`, new `scripts/lib/runtimes.txt`, new `scripts/runtime-setup.sh`, `.gitmodules`, `docs/SOURCES.md`, `repos/gstack` pointer, `baseline-submodules.example.txt`, `.nojekyll`, `CLAUDE.md`, `BOOTSTRAP.md`.
- Behaviour change: `SKILLS.md` counts drop (ECC 1027 to 293, alirezarezvani 763 to 345, openclaw 113 to 73, paperclip 37 to 22); `repos/clawhub` (all 12 skills under `.agents/`) becomes a reference repo; openspec's maintainer skills under `.agents/skills/` stop being wired. All of these except openspec are library-only, so no wired skill changes outside openspec and mattpocock.
- Every existing machine must run `git submodule sync --recursive` after pulling the URL change.

## Non-goals

- No manifest, lock file, or `grid install` (workstream 3).
- No vetting policy or `grid audit` (workstream 4).
- No listing-budget check (workstream 5).
- No new curation in the example baseline: renamed entries follow upstream, removed ones are dropped, nothing new is added (for example mattpocock `domain-modeling`).
- No change to the personal (gitignored) `baseline-submodules.txt` or machine overlays; the operator applies the same renames by hand (HUMAN group 7).
- No move of Pages to an Actions-based deploy unless `.nojekyll` proves insufficient (follow-up change).
- No change to which skills are wired or unwired beyond what the exclusion rule implies.
- No auto-install of bun, Playwright system fonts, or Homebrew packages from the-grid scripts.
