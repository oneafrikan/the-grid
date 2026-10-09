## Why

Claude Code lists every skill name but shares one description budget (1% of context) across all of them, and silently drops the least-invoked descriptions on overflow. On the reference machine 165 wired skills produce a ~30k-char listing with ~60 descriptions already dropped, and only 11 skills were invoked in 36 days. Nothing in the-grid measures this, stops it growing, or tells Gareth what to prune, and transcripts that hold the evidence expire after ~30 days.

## What Changes

- Add `scripts/budget.py`: measures description chars of the owned skills, composed role descriptions and (where a baseline exists) the baseline wired set; `--check` runs in `gate.sh` and fails on regression against a committed target ratchet.
- Tighten owned skill and role descriptions to one line (trigger phrases move into the body); roles get a `description:` field that compose.py emits verbatim.
- Split owned `SKILL.md` bodies over 4 KB into `sections/*.md`, read on demand (gstack pattern).
- Add a harness-aware usage extractor (Claude Code adapter now, adapter seam for Codex/Gemini) that writes aggregated counts per day to `~/.the-grid-private/usage/<host>.json`, plus a weekly job per OS (launchd, systemd user timer, cron fallback) that commits and pushes it.
- Add an aggregator that sums all hosts, and `prune-report`, which proposes moving never/rarely used wired skills to library or `name-only`. It proposes only; applying is a HUMAN task.
- Recommend `cleanupPeriodDays: 60` so a missed weekly run loses no data.

## Capabilities

### New

- `listing-budget`: measurement and gate ratchet for skill/agent description size.
- `skill-descriptions`: one-line description rule and on-demand `sections/` for owned skills and roles.
- `usage-extract`: harness-aware, privacy-safe per-host usage counts and the cross-host aggregator.
- `usage-schedule`: weekly per-OS job that runs the extract and publishes it to the private repo.
- `prune-report`: read-only proposals to demote unused wired skills.

### Modified

None. No specs exist yet in `openspec/specs/`.

## Impact

- New: `scripts/budget.py`, `docs/budget-target.json`, `scripts/usage/` (extract, aggregate, prune_report, adapters, schedule templates, installer), `docs/usage.md`, `docs/prune-keep.txt`, `scripts/prune-report.sh`, bats tests and fixtures.
- Edited: `scripts/gate.sh` (new `budget` check), `agent-factory/compose.py` (accept and emit `description:`), 38 `agent-factory/roles/*/role.yaml`, 14 `skills/*/SKILL.md`, `agent-factory/docs/role-authoring.md`, `CLAUDE.md`.
- Composed output (git-ignored) changes description text; machines recompose after pulling.
- Depends on workstream 3 only for the `grid` dispatcher name; this change ships `scripts/prune-report.sh` and works without it.
- Reads `~/.claude/projects/**/*.jsonl` (read-only) and writes only to the private repo.

## Non-goals

- Applying any prune: no edits to `baseline-submodules.txt`, machine overlays or `~/.claude/settings.json`. The report prints a `skillOverrides` snippet; Gareth pastes it.
- Editing upstream (submodule) skill descriptions; only root `skills/*` and `agent-factory/roles/*` are tightened.
- Splitting composed role bodies (AGENTS/SKILL) or upstream skill bodies.
- Codex, Gemini, OpenCode usage adapters: only the seam and registry exist.
- Storing prompt text, file paths, project names or session ids.
- Any model call, or any hook that runs inside a Claude session.
- A dashboard or web UI for usage.
- The skill-scout PR automation of issue #18; only its scheduling pattern is reused.
- Setting `cleanupPeriodDays` automatically.
