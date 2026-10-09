## Why

The public repo still carries personal residue: machine names, account and org handles, a real email in `user.yaml.example`, deployment plans for private hosts, a personal desk blueprint, 1.1 MB of third-party PDFs/zips of unclear licence under `__assets/`, and a skill whose document-locations table encodes one person's folders. A stranger cloning it sees someone else's infrastructure, and nothing stops the residue returning. The earlier `LOGS/` audit removed the dev journal only; this change finishes the job and adds a gate so it stays done.

## What Changes

- Inventory every tracked non-submodule file and sort each hit into four buckets: move to the private repo, delete (duplicate), genericise in place, keep (credit and author voice).
- Move to `~/.the-grid-private/archive/`: the third-party `__assets/ClawGuides*` bundle, three personal design/ops docs, one dated personal prompt, and the "Done" history plus per-machine rollout notes from `TODO.md`. Delete the byte-identical `docs/playbook-ai-dev-team.md` copy of the third-party playbook.
- Genericise in place: `agent-factory/user.yaml.example`, the OpenClaw target templates/roster/deploy-script comments, `gh-triage` spec and scope template, the issue-loop pattern README, handoff skill and templates, `baseline-submodules.example.txt` comments, `LEARNINGS.md` source lines, stale status sentences in README and `index.html`.
- Add `scripts/check-personal.sh`: generic patterns kept in public, a private denylist kept in `~/.the-grid-private/denylist.txt`, a path allowlist, a file-type and size block. Wire it into `scripts/gate.sh` and a repo-wide bats test so CI enforces the generic half.
- Rule: author voice ("Gareth") is allowed in prose docs; personal data is not. Rendered templates and role files address "the operator".

## Capabilities

### New

- `public-repo-hygiene`: what may and may not appear in the public tree, and where personal material lives instead.
- `personal-data-gate`: the scan that enforces it (generic patterns, private denylist, allowlist, size/type block, gate wiring).
- `handoff-locations`: the handoff skill defaults to `LOGS/` and reads an optional private table for per-project overrides.

### Modified

None. No specs exist yet in `openspec/specs/`.

## Impact

- New: `scripts/check-personal.sh`, `scripts/personal-patterns.txt`, `scripts/personal-allow-paths.txt`, `scripts/personal-denylist.example.txt`, `tests/test_check_personal.bats`, `tests/test_depersonalise.bats`.
- Removed from public: `__assets/` (22 files), `docs/playbook-ai-dev-team.md`, `agent-factory/docs/openclaw-paperclip-targets-plan.md`, `docs/openclaw-portfolio-desk-blueprint.md`, `automation-factory/docs/gh-triage-to-issue-loop.md`, `prompts/2026-06-13-openclaw-lamp-team-prompt.md`; `TODO.md` shrinks to focus plus issue map.
- Edited: about 25 files (list in `design.md`), `scripts/gate.sh`, `CLAUDE.md`, `README.md`, `index.html` (one sentence; README's equivalent bullet is already accurate), `skills/handoff/*`.
- Private repo gains `archive/` and `denylist.txt`; the move is a HUMAN step because it commits to a second repo.
- Cross-change (D9 order): merges after `foundations`, before `vetting` and everything else. `front-door` rewrites README/`index.html` later; `hook-profiles` also edits the handoff skill and builds on this smaller edit. Later changes whose tests need secret- or path-shaped fixtures must use the placeholders the generic patterns allow (`/Users/you|alice|bob/`, `...EXAMPLE` keys, URL userinfo) or build the string at runtime.
- Composed-agent nameplates: `compose.py` writes `user.yaml` values (operator, channels, machine) only into gitignored `agent-factory/projects/`; no tracked file in this repo receives them (verified). `deploy.py --profile full` does copy the nameplate into another project's `.claude/agents/`; that is owned by D1 (`workflow-upgrades`, `GRID_USER_CONFIG` + `user.public.yaml`), not this change.
- GitHub issue #42 (default OpenClaw personas) and #54 (operator persona fields, voice layer) stay open: only their "no personal data ships" constraint is applied here.

## Non-goals

- Rewriting git history. Moved files stay recoverable from old commits; anything that was ever a live credential must be rotated by its owner (none was found in the current tree).
- Scrubbing GitHub issue titles, bodies or comments, which also name hosts.
- Building #42 (generic default OpenClaw personas, parameterised `deploy_openclaw.sh`) or #54 (persona fields, voice overlay). No new `user.yaml` fields.
- Re-encoding or replacing `the-grid.png` (5.6 MB). It is not personal data and is the live hero image of `index.html`; `front-door` replaces it with a small WebP. It is allowlisted until then.
- Removing the `oneafrikan/the-grid` owner handle from clone URLs and issue links, or `LICENSE` copyright.
- Scanning submodule contents (`repos/*`) or vendored `tests/lib/*`.
- Changing any composed-agent behaviour: edits to roles and templates are wording only.
- Neutral nameplates for `deploy.py --profile full` output in other repos (D1, `workflow-upgrades`).
