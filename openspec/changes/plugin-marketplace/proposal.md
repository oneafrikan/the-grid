## Why

Claude Code users can install a git repo that ships `.claude-plugin/marketplace.json` with two commands, no clone, no submodules, no `wire.sh`. the-grid has no such channel, so a Claude-Code-only visitor must clone and wire to try anything. Two small bundles of the-grid's own content (`grid-core`, `grid-agents`) give a zero-friction trial path. It stays secondary to the harness-neutral `grid install` (change `manifest-lock-install`).

## Status (2026-11-05)

Shipped. Groups 1 to 4 are done (issues #159 to #162 closed): the builder, the manifest, the generated bundles and marketplace file, the gate checks, `docs/PLUGINS.md`, the provenance review (recorded in `THIRD-PARTY-NOTICES.md` on 2026-11-04) and the publish step. Both bundles are version 0.1.0 and the repo tag `v0.1.0` exists with a GitHub release. Marketplace add and install of both bundles were verified from a clean config.

Differences from the text below: `grid-core` now includes five cross-desk agents (`core-context-engineer` was added after the design was written) and `grid-agents` also ships the `gsd` skill beside the three orchestrators; pinning an install to a tag is unverified and not documented (`docs/PLUGINS.md`); there is no `next` branch.

Branch note (2026-11-05): `next` was merged into `main` (PR #286, 2026-10-18) and no longer exists; `main` is the only branch. Read every `next` below as `main`: branch from `main` and target `main`.

## What Changes

- Add `plugins/bundles.json`: hand-authored membership manifest (version, owned skills per bundle, which composed projects feed it).
- Add `scripts/build-plugins.py`: generates `plugins/grid-core/`, `plugins/grid-agents/` and `.claude-plugin/marketplace.json` from the manifest; `--check` reports drift and writes nothing. Generated files are committed and never hand-edited.
- Plugin builds compose with `GRID_USER_CONFIG=agent-factory/user.public.yaml` and no private roles (both from `workflow-upgrades`), so they embed no operator, channel or hostname.
- Gate: `scripts/gate.sh` runs `build-plugins.py --check` and `claude plugin validate --strict` over the marketplace, both plugins and their `skills/` and `agents/` dirs; `scripts/audit.sh --owned` (change `vetting`) covers `plugins/`.
- Add `docs/PLUGINS.md` (install, namespacing, "one channel per machine") and a `CLAUDE.md` pointer.
- HUMAN publish step after tag `v0.1.0`: verify install from a clean profile.

## Capabilities

### New

- `plugin-marketplace`: bundle manifest, generated plugins and marketplace file, validation, owned-content-only scope.

### Modified

None (no specs exist yet under `openspec/specs/`).

## Impact

- New: `plugins/` (about 60 small files), `.claude-plugin/marketplace.json`, `scripts/build-plugins.py`, `docs/PLUGINS.md`, `tests/test_plugins.bats`.
- Edited: `scripts/gate.sh`, `scripts/audit.sh` and `policy.yaml` (add `plugins/` to the owned set), `CLAUDE.md`. No `compose.py` change.
- Depends on `workflow-upgrades#2` (`GRID_USER_CONFIG`, `user.public.yaml`), `vetting#3`/`#5` (audit), `front-door#15` (tag).
- Third-party skills are not touched, so no licence or vetting duty is created for upstream content.
- Use case named: Claude Code users who want the-grid's skills and dev-team agents (web/app full-stack, marketing, data) without cloning.

## Non-goals

- Exposing wired third-party skills (`git-subdir` + `sha` entries from `grid.lock`). Deferred; see design.
- Plugin hooks, MCP servers, rules or commands. None ship; hook profiles stay in `hook-profiles`.
- Other composed projects (`finance-desk`, `learning-desk`, any private desk).
- Other harness marketplaces (Codex, OpenCode); that is `multi-harness`.
- Submitting to the Anthropic official directory.
- Auto-update or version-bump automation; the version is bumped by hand at release.
