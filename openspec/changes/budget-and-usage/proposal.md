## Why

Claude Code lists every skill name but shares one description budget (1% of context) across all of them, and silently drops the least-invoked descriptions on overflow. On the reference machine 165 wired skills produce a ~30k-char listing with ~60 descriptions already dropped, and only 11 skills were invoked in 36 days. Nothing in the-grid measures this, stops it growing, or tells the operator what to prune, and transcripts that hold the evidence expire after ~30 days.

## What Changes

- Add `scripts/budget.py`: measures listing chars of the owned skills, public role descriptions and (where a baseline exists) the baseline wired set; `--check` runs in `gate.sh` and fails on regression against a committed target ratchet.
- Tighten owned skill and role descriptions to one line of at most 250 chars that KEEPS the key trigger phrases (Claude selects skills from the listing, so triggers stay in the description); roles get a `description:` field that compose.py emits verbatim.
- Split owned `SKILL.md` bodies over 4 KB into `sections/*.md`, read on demand (gstack pattern).
- Add a harness-aware usage extractor (Claude Code adapter now, adapter seam for other harnesses) that writes per-day skill/agent/slash counts to `~/.the-grid-private/usage/<host>.json`, plus a weekly job per OS (launchd, systemd user timer, printed cron line) that commits and pushes it.
- Add `prune-report`, which sums all hosts and proposes moving never/rarely used wired skills to library or `name-only`. It proposes only; applying is a HUMAN task.
- Recommend `cleanupPeriodDays: 60` so a missed weekly run loses no data.

## Capabilities

### New

- `listing-budget`: measurement and gate ratchet for skill/agent description size.
- `skill-descriptions`: one-line, trigger-bearing description rule and on-demand `sections/` for owned skills and roles.
- `usage-extract`: harness-aware, privacy-safe per-host usage counts.
- `usage-schedule`: weekly per-OS job that runs the extract and publishes it to the private repo.
- `prune-report`: cross-host aggregation and read-only proposals to demote unused wired skills.

### Modified

None. No specs exist yet in `openspec/specs/`.

## Impact

- New: `scripts/budget.py`, `scripts/lib/baseline_wired.py`, `docs/budget-target.json`, `scripts/usage/` (extract, aggregate, prune_report, adapters, weekly job, schedule templates, installer), `scripts/prune-report.sh`, `docs/usage.md`, `docs/prune-keep.txt`, bats tests and fixtures.
- Edited: `scripts/gate.sh` (new `budget` check, shellcheck glob), `agent-factory/compose.py` (accept and emit `description:`), 38 `agent-factory/roles/*/role.yaml`, 14 `skills/*/SKILL.md`, `agent-factory/docs/role-authoring.md`, `CLAUDE.md`.
- Composed output (git-ignored) changes description text; machines recompose after pulling.
- Depends on `foundations` (CI on `next`, `GRID_BASELINE`, skill-discovery exclusions). `scripts/prune-report.sh` ships standalone; it becomes `grid prune-report` once `manifest-lock-install` adds the dispatcher.
- Reads `~/.claude/projects/**/*.jsonl` (read-only); writes usage data only to the private repo and one log under `~/.grid/`.

## Non-goals

- Applying any prune: no edits to `baseline-submodules.txt`, machine overlays or `~/.claude/settings.json`. The report prints a `skillOverrides` snippet; the operator pastes it.
- Editing upstream (submodule) skill descriptions; only root `skills/*` and `agent-factory/roles/*` are tightened.
- Splitting composed role bodies (AGENTS/SKILL) or upstream skill bodies.
- Token or cost accounting from transcripts (not needed to decide pruning).
- Measuring the live per-machine listing in `budget.py`; the extractor already records the real listing size from transcripts.
- Codex, Gemini, OpenCode usage adapters: only the seam and registry exist.
- Storing prompt text, file paths, project names or session ids.
- Any model call, or any hook that runs inside a Claude session.
- A dashboard or web UI for usage.
- The skill-scout PR automation of issue #18; only its scheduling pattern is reused.
- Setting `cleanupPeriodDays` automatically.
