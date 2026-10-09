## Why

The commit gate is the unattended loop's only truth signal, and today it is not trustworthy: CI never builds the agent-factory venv (about 81 tests skip), three tests always fail on a runner, the Pages site returns 404, the ECC submodule is counted as 1027 skills when only 293 are real, and gstack's skills are wired without the runtime they call. Nothing downstream (loop, install, budget, hooks) can be verified until these are fixed.

## What Changes

- CI: build the agent-factory venv, run `scripts/gate.sh`, fail loudly if the venv is missing; tests that scan "wired" skills use the real wiring rules; the live-skills-dir test skips on runners.
- Pages: add `.nojekyll`; convert the 22 SSH submodule URLs in `.gitmodules` to HTTPS (issue #37) and regenerate `docs/SOURCES.md`.
- Skill discovery: `find_skill_mds` (shared by `wire.sh` and `catalog.sh`) drops locale translations, root-level harness-copy dot-dirs, and per-repo listed paths (ECC 1027 to 293).
- Runtime check: a declarative `scripts/lib/runtimes.txt` plus a `wire.sh` check and runtime-root link; a `scripts/runtime-setup.sh` wrapper that runs gstack `./setup` without registering global hooks.
- Bump the gstack pin to the latest upstream release (no tags exist upstream; use the head commit, VERSION 1.91.x or newer).
- Fix the stale gstack skill count in `baseline-submodules.example.txt` and guard it with a test.

## Capabilities

### New Capabilities
- `ci-gate`: CI runs the real gate with the venv; wired-skill tests use real wiring rules.
- `pages-site`: the static site publishes without Jekyll.
- `submodule-sources`: HTTPS-only public submodule URLs, a gstack version floor, and a true gstack count in the example baseline.
- `skill-discovery`: one shared exclusion rule for translations and harness copies.
- `runtime-check`: per-submodule runtime markers, a runtime-root link, and a hook-free runtime setup wrapper.

### Modified Capabilities
- None (no specs exist yet under `openspec/specs/`).

## Impact

- Files: `.github/workflows/tests.yml`, `tests/test_repo_health.bats`, `tests/test_skill_format.bats`, `tests/helpers/`, new `tests/test_skill_discovery.bats`, `tests/test_submodule_sources.bats`, `tests/test_runtime.bats`, `scripts/lib/find-skill-mds.sh`, new `scripts/lib/skill-excludes.txt`, `scripts/wire.sh`, new `scripts/lib/runtimes.txt`, new `scripts/runtime-setup.sh`, `.gitmodules`, `docs/SOURCES.md`, `repos/gstack` pointer, `baseline-submodules.example.txt`, `.nojekyll`, `CLAUDE.md`, `BOOTSTRAP.md`.
- Behaviour change: `SKILLS.md` counts drop (ECC library count, alirezarezvani library count); openspec's three maintainer skills under `.agents/skills/` stop being wired.
- Every existing machine must run `git submodule sync --recursive` after pulling the URL change.

## Non-goals

- No manifest, lock file, or `grid install` (workstream 3).
- No vetting policy or `grid audit` (workstream 4).
- No listing-budget check (workstream 5).
- No fix for stale per-skill baseline entries (for example renamed mattpocock skills); reported as an open question only.
- No move of Pages to an Actions-based deploy unless `.nojekyll` proves insufficient (follow-up change).
- No change to which skills are wired or unwired beyond what the exclusion rule implies.
- No auto-install of bun, Playwright system fonts, or Homebrew packages from the-grid scripts.
