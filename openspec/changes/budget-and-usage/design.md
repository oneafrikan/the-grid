# Design: budget-and-usage

## Context

- Claude Code puts every skill name in the session's skill listing. Descriptions share a budget of 1% of context (`skillListingBudgetFraction`), each entry truncated at 1,536 chars, and the least-invoked descriptions are dropped silently on overflow.
- Per-skill control exists via `skillOverrides` (`on` / `name-only` / `user-invocable-only` / `off`); it does not apply to plugin skills.
- Reference machine: ~165 wired skills, ~30k-char listing, ~60 descriptions already dropped, 11 skills invoked in 36 days (research `usage-report.md`; its `usage.py` is the logic reused here).
- Evidence source is `~/.claude/projects/**/*.jsonl`, kept ~30 days (`cleanupPeriodDays`), per machine. Cross-machine evidence needs git as the sync layer (the private repo), per the project non-negotiables.
- gstack's pattern: one-sentence listing descriptions, trigger prose in the body, long procedures in `sections/*.md` loaded on demand.
- Issue #18 (scheduled skill-scout) is folded in only as a precedent: a scheduled job whose output is reviewed by a human, never auto-applied.

## Approach

Four layers, each usable alone:

1. **Measure and gate** (`scripts/budget.py`, `docs/budget-target.json`).
2. **Shrink what the-grid owns** (descriptions, `sections/`).
3. **Collect evidence** (`scripts/usage/extract.py`, weekly job, per-host JSON in the private repo).
4. **Propose pruning** (`scripts/usage/aggregate.py`, `scripts/usage/prune_report.py`, `scripts/prune-report.sh`).

### 1. Budget measurement

Entry cost model (stdlib only, no Claude Code needed):

```
effective_desc = whitespace-collapsed description, cut to truncate_at (1536)
entry_chars    = len(name) + len(effective_desc) + 4      # "- name: desc\n" overhead, approximate
```

Three scopes, because the baseline is personal and gitignored (#24) while owned content is public and deterministic:

| scope | what is measured | where it runs | enforced |
|---|---|---|---|
| `owned` | `skills/*/SKILL.md` descriptions; `agent-factory/roles/*/role.yaml` `description` (fallback legacy formula) | everywhere, incl. CI | always |
| `baseline` | skills wired by `baseline-submodules.txt` only (no machine overlay), measured by running `wire.sh` into a temp dir with `GRID_HOST=__baseline__`, `GRID_SKIP_CATALOG=1`; composed-project symlinks are ignored (roles are counted from source in `owned`) | machines with the baseline file and initialised submodules | when measurable, else skipped loudly (same precedent as the catalog check) |
| `live` | the real `SKILLS_DIR` / `AGENTS_DIR` of this machine (overlays included) | `--report` only | never |

Roles split by `role.yaml orchestrator: true`: orchestrators are skills (listing budget), specialists are agents (agent listing, tracked separately because it is a different budget). Private roles (`GRID_PRIVATE_ROLES_DIR`) are never counted, so the number is deterministic.

`docs/budget-target.json` (committed; numbers are filled by the implementer with `--update-target`):

```json
{
  "schema": 1,
  "truncate_at": 1536,
  "per_entry_max_chars": 180,
  "owned": {
    "skills_max_chars": 0,
    "orchestrator_roles_max_chars": 0,
    "agent_roles_max_chars": 0,
    "skill_body_max_bytes": 4000
  },
  "baseline": {
    "skills_max_chars": 0
  }
}
```

CLI (`python3 scripts/budget.py`):

```
--report           default: totals per scope, 15 longest entries, count over per_entry_max_chars
--check            exit 1 if any total > its target, any owned entry > per_entry_max_chars,
                   any owned SKILL.md > skill_body_max_bytes, or sections/ integrity fails;
                   exit 3 if only the baseline scope was skipped; 0 otherwise
--update-target    rewrite totals in docs/budget-target.json to the current measurement;
                   refuses to RAISE a number unless --allow-raise is also given
--json             machine-readable output
env: GRID_DIR, GRID_HOST (never read machines/<host>.txt in the baseline scope)
```

The ratchet is the regression guard: targets only go down in normal work; raising one is a visible, reviewed diff to `docs/budget-target.json`.

`gate.sh` gets a `budget` check; exit 3 is recorded as `SKIPPED+=(budget-baseline)` and counts as pass.

### 2. Shrinking owned content

**Descriptions.** One line, <= 180 chars, no "Use when" trigger list. The trigger phrases move into a `## When to invoke` section at the top of the body. Caveat: models pick skills from the listing only, so a trigger moved to the body no longer helps discovery. This is accepted because the owned skills are mostly user-invoked slash commands, and the stronger lever for rarely used skills is `name-only` (layer 4).

**Roles.** `role.yaml` gains `description:` (one line, <= 180 chars). `compose.py` emits it verbatim as the subagent/skill `description` and drops the `Use this subagent for X work.` / `Invoke with /x ...` suffixes (the skill name is already the slash command). Roles without `description:` keep the legacy formula, so private roles keep working. `ROLE_YAML_KEYS` gains `description`.

**Sections.** Owned `SKILL.md` over 4,000 bytes (today: mine-learnings, openspec-help, setup-repo-skills, skill-scout, spec-scout, grid-help, un-claudish) is split:

```
skills/<name>/SKILL.md              frontmatter, purpose, ## When to invoke, step skeleton, ## Sections
skills/<name>/sections/<topic>.md   plain markdown, no frontmatter, <= 6000 bytes each
```

`## Sections` in `SKILL.md` lists one line per file:

```
## Sections
Read a section only when its condition applies; do not preload them.
- sections/output-format.md: read when writing the final report
- sections/dedupe-rules.md: read when comparing against already-wired skills
```

wire.sh already symlinks the whole skill directory, so `sections/` travels with no wiring change. No manifest file (gstack's `manifest.json` is not needed at this scale).

### 3. Usage extraction

Layout:

```
scripts/usage/extract.py          CLI: scan adapters, merge into <private>/usage/<host>.json
scripts/usage/aggregate.py        CLI + importable: sum all hosts
scripts/usage/prune_report.py     CLI + importable: proposals
scripts/usage/adapters/__init__.py   REGISTRY = [claude_code.ClaudeCode]
scripts/usage/adapters/claude_code.py
scripts/usage/weekly.sh           the scheduled job
scripts/usage/install-schedule.sh
scripts/usage/schedule/           launchd plist template, systemd .service/.timer, cron line
```

**Adapter seam.** An adapter is a class with four members; the extractor knows nothing about transcript formats.

```python
class Adapter:
    name = "claude-code"                       # key under "harnesses" in the output
    def available(self) -> bool: ...           # logs dir exists
    def events(self, since_day: str | None):   # yields normalised events, no prompt text
        # {"day": "2026-10-08", "kind": "skill",   "name": "handoff"}
        # {"day": "2026-10-08", "kind": "agent",   "name": "grid-qa-engineer"}
        # {"day": "2026-10-08", "kind": "slash",   "name": "handoff"}
        # {"day": "2026-10-08", "kind": "tokens",  "name": "<model>", "in": 1, "out": 2, "cache_read": 3, "cache_write": 4}
        # {"day": "2026-10-08", "kind": "listing", "skills": 187, "chars": 30002}
    def wired(self) -> dict: ...               # {"skills": [names], "agents": [names]} on this machine
```

Adding Codex or Gemini = one new module plus one `REGISTRY` line. Only `claude_code.py` ships.

**Claude Code adapter** reuses `usage.py` logic: stream every `*.jsonl` including `subagents/`; `Skill` tool_use -> skill; `Agent`/`Task` tool_use -> agent (`subagent_type`, default `(default)`); user-message `<command-name>` or leading `/token` (no `/` inside the token, not `//`) -> slash; assistant `message.usage` deduped by message id -> tokens keyed by `message.model`; `attachment.type == skill_listing` with `isInitial` -> listing. Day = first 10 chars of the record timestamp (UTC). Slash events only from top-level (non-subagent) files. Names must match `^[A-Za-z0-9][A-Za-z0-9:_.-]{0,63}$`, else dropped (stops pasted paths or text leaking in as a "command"). `wired()` lists `SKILLS_DIR` (default `~/.claude/skills`) and `AGENTS_DIR` (`~/.claude/agents`, `.md` stripped), dotfiles skipped.

**Output** `<private>/usage/<host>.json` (host = `GRID_HOST` else `hostname -s`; one writer per file, so git never conflicts):

```json
{
  "schema": 1,
  "host": "hostA",
  "updated": "2026-10-09",
  "harnesses": {
    "claude-code": {
      "days": {
        "2026-10-08": {
          "skills": {"handoff": 3, "grid-tech-lead": 2},
          "agents": {"grid-qa-engineer": 4},
          "slash":  {"handoff": 1, "model": 2},
          "tokens": {"claude-sonnet-5": {"in": 120, "out": 9000, "cache_read": 4000000, "cache_write": 90000}}
        }
      },
      "wired":   {"skills": ["handoff", "tdd"], "agents": ["grid-qa-engineer"]},
      "listing": {"2026-10-09": {"skills": 187, "chars": 30002}}
    }
  }
}
```

Counts only: no prompt text, paths, project names, session ids.

**Merge rule (idempotent, retention-safe).** The scan covers whatever transcripts survive. For each day and key, the stored value becomes `max(old, new)`; days not in the scan are untouched; `wired` is replaced by the latest snapshot; `listing` per day takes the max chars. Re-running the same day changes nothing; a day whose early transcripts were already deleted never shrinks. Output is written with sorted keys, 2-space indent, trailing newline, atomically (temp file + rename), and not rewritten when unchanged.

**Aggregator** `aggregate.py [--dir DIR] [--window-days N] [--json]` reads every `*.json` in the usage dir, ignores unknown `schema`, and returns per harness: `skills`/`agents`/`slash` totals over the window, per-host breakdown, `hosts` count, `first_day`/`last_day`/`coverage_days`, tokens by month and model, union of `wired`. Derived, never committed.

**Retention recommendation.** Default `cleanupPeriodDays` is 30; the job runs weekly, so default retention already loses nothing when every run succeeds. A laptop asleep for a month loses a window. Recommended: `"cleanupPeriodDays": 60` in `~/.claude/settings.json` on every machine (transcripts are local disk; cost is space only). `extract.py` prints a one-line warning when the setting is unset or < 45; documented in `docs/usage.md`. Not applied automatically (settings.json is not grid-owned).

### 4. Scheduling

`weekly.sh` (idempotent, safe to run twice):

```
1. python3 scripts/usage/extract.py --out "$PRIVATE/usage"           # never fails the job on a missing adapter
2. if "$PRIVATE" is a git repo:
     git -C "$PRIVATE" pull --rebase --autostash        (failure -> log, continue)
     git -C "$PRIVATE" add usage/<host>.json
     git diff --cached --quiet || git commit -m "usage: <host> <YYYY-MM-DD>"
     git push                                           (failure -> log, leave committed; next run retries)
3. append one line to ${XDG_STATE_HOME:-~/.local/state}/the-grid/usage.log
```

`PRIVATE=${GRID_PRIVATE_DIR:-$HOME/.the-grid-private}`. A thin client without the private repo still writes the file locally and skips git. Commits carry no AI attribution (automated job).

`install-schedule.sh [--dry-run|--uninstall]` picks by OS and substitutes `@GRID_DIR@` at install time (no absolute paths in tracked files):

| OS | mechanism | cadence |
|---|---|---|
| macOS | `~/Library/LaunchAgents/com.the-grid.usage.plist`, `launchctl bootstrap gui/$UID` | `StartCalendarInterval` Monday 09:00 (missed runs fire on wake) |
| Linux with `systemctl --user` (Ubuntu, Arch) | `~/.config/systemd/user/grid-usage.{service,timer}` | `OnCalendar=Mon 09:00`, `Persistent=true`, `RandomizedDelaySec=1h` |
| other | prints a crontab line, installs nothing | `0 9 * * 1` |

Headless Linux needs `loginctl enable-linger`; the installer prints a note, does not run it. Installing is per machine and is a HUMAN task.

### 5. Prune report

`scripts/prune-report.sh [--window-days 90] [--rare 2] [--min-days 28] [--usage-dir D] [--out FILE] [--json]` wraps `prune_report.py`; it becomes `grid prune-report` when workstream 3's dispatcher exists. Read-only: it writes stdout (or `--out`) and nothing else.

Per baseline-wired skill (set from the same temp-dir `wire.sh` run as the budget baseline scope, giving the source repo):

```
uses  = skill-tool calls + slash invocations of that name, all hosts, in window
state = never (0) | rare (1..--rare) | used
```

Skipped from proposals: names in `docs/prune-keep.txt` (one name per line, `#` comments); anything when `coverage_days < --min-days` (report says "insufficient history: N days of M required" and stops after the evidence section).

Proposals, ordered by chars saved, numbered so Gareth can reply "apply 2, skip 3":

- **A. Demote a repo.** Baseline whole-repo entry where >= 90% of its wired skills are `never`/`rare`: propose moving to library (delete the line) or replacing with per-skill entries for the `used` ones (listed). Saving = sum of entry chars of the dropped skills.
- **B. `name-only` a skill.** Any other `never`/`rare` skill: saving = description chars. Printed as a ready-to-paste `skillOverrides` JSON block.
- **C. Unused agents.** Agents in any host's `wired.agents` with zero uses: listed with their project gate (`-project:<name>` overlay suggestion). No saving figure (agent listing is a separate budget).

Evidence footer: hosts reporting, day coverage, and the standing caveats (only Skill-tool and slash invocations are visible; a model reading a SKILL.md directly is not; slash and Skill events can double-count, which only matters for `rare`).

## Decisions

- Decided: budget scope is owned (always enforced) + baseline (only where `baseline-submodules.txt` and submodules exist); reason: the baseline file is personal and gitignored, so CI cannot measure it.
- Decided: baseline is measured by running `wire.sh` into a temp dir with a non-existent `GRID_HOST`; reason: reuses the real wiring logic and ignores machine overlays, no second parser to drift.
- Decided: private and composed-on-disk roles are never measured; roles are measured from `role.yaml` source; reason: composed output is git-ignored and differs per machine.
- Decided: entry cost = `len(name) + len(desc cut to 1536) + 4`; reason: Claude Code's exact listing format is not documented, a stable proxy is enough for a ratchet.
- Decided: targets are a ratchet in `docs/budget-target.json`; `--update-target` refuses to raise without `--allow-raise`; reason: regressions must be a visible diff.
- Decided: per-entry limit 180 chars applies to owned skills and role descriptions only; reason: upstream text is not ours to edit.
- Decided: the checker is Python 3 stdlib (`scripts/budget.py`), not bash; reason: YAML-scalar parsing and JSON targets are fragile in awk, and python3 is already required by `run-record.sh`.
- Decided: gate exit code 3 from `budget.py` means "baseline scope skipped" and counts as pass with a notice; reason: matches the catalog-check precedent.
- Decided: orchestrator roles count toward the skills total, specialist roles toward a separate agents total; reason: they feed different Claude Code budgets.
- Decided: `role.yaml` `description:` is emitted verbatim and replaces the legacy suffix formula only when present; reason: private roles keep working untouched.
- Decided: trigger phrases move to `## When to invoke` in the body even though discovery relies on the listing; reason: the brief requires one-line descriptions and `name-only` covers the rarely used long tail.
- Decided: split threshold is `SKILL.md` > 4,000 bytes, sections <= 6,000 bytes each, no `manifest.json`; reason: smallest rule that catches the 7 largest owned skills.
- Decided: splitting must not change behaviour; acceptance is that every non-blank line of the old file appears in `SKILL.md` or a section (apart from the added index, `## When to invoke` and description lines); reason: a mechanical, checkable bar for an unattended agent.
- Decided: usage is stored as per-day buckets with max-merge, not a rolling snapshot; reason: weekly runs overlap the 30-day window and must not double count or lose data.
- Decided: day boundary is UTC taken from the record timestamp; reason: transcripts carry UTC and hosts span timezones.
- Decided: names failing `^[A-Za-z0-9][A-Za-z0-9:_.-]{0,63}$` are dropped; reason: slash capture must never store pasted text or paths.
- Decided: no per-project breakdown is stored; reason: project directory names embed the user name and add no pruning value.
- Decided: one file per host, written only by that host; reason: git merges never conflict.
- Decided: the job commits only `usage/<host>.json`, rebases on pull, and treats push failure as non-fatal; reason: a flaky network must not break the machine's cron/timer or lose the data.
- Decided: schedule is weekly Monday 09:00 local with `Persistent=true` and `RandomizedDelaySec=1h` on systemd; reason: weekly is well inside 30-day retention and the jitter avoids all hosts pushing together.
- Decided: recommend `cleanupPeriodDays: 60`; reason: margin for missed runs at the cost of disk only. Extract warns but never edits settings.
- Decided: `prune-report` is `scripts/prune-report.sh` now and becomes `grid prune-report` when the dispatcher lands; reason: this change must not depend on workstream 3.
- Decided: usage for a skill = Skill-tool calls + slash invocations of the same name; reason: user-typed slash skills may not emit a Skill call, and over-counting only makes the report more conservative.
- Decided: defaults `--window-days 90 --rare 2 --min-days 28`; reason: one month of data across hosts is the minimum to call anything unused, and retention caps what exists anyway.
- Decided: repo demotion threshold 90% unused; reason: avoids proposing to drop a repo for one dead skill (that case is a `name-only` line).
- Decided: `docs/prune-keep.txt` is tracked and starts with `handoff` and `grid-help`; reason: front-door skills must never be proposed even if unused for a month.
- Decided: the report prints a `skillOverrides` snippet and never writes settings; reason: settings.json is not grid-owned and the override is per machine. The implementer must confirm the key and value names against the Claude Code docs before shipping the snippet.
- Decided: the installer prints but does not run `loginctl enable-linger` and never edits crontab; reason: system-level side effects stay with the human.
- Decided: tests use fixture transcripts under `tests/fixtures/usage/` and temp dirs; reason: tests never touch the real `~/.claude` or private repo.

## Risks and open points

- `skillListingBudgetFraction` and the drop-least-invoked rule are Claude Code behaviour taken from the brief; the gate only measures description size and does not simulate truncation.
- Shortened descriptions may reduce model-initiated invocation of owned skills; mitigated by their being mostly slash-invoked and by the report telling us what is actually used.
- A skill or agent whose name fails the name regex is dropped from counts.
