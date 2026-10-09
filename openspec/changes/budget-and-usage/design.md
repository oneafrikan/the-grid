# Design: budget-and-usage

## Context

- Claude Code puts every skill name in the session's skill listing. Descriptions share a budget of 1% of context (`skillListingBudgetFraction`); the least-invoked descriptions are dropped silently on overflow.
- Per the Claude Code skills docs: `description` plus the optional `when_to_use` frontmatter field are combined and cut at 1,536 chars in the listing; a skill with `disable-model-invocation: true` has its description removed from context entirely (only `skills/setup-repo-skills` sets it today).
- Per-skill control exists via `skillOverrides` in settings.json, shape `{"skillOverrides": {"<skill-name>": "name-only"}}`, values `on` / `name-only` / `user-invocable-only` / `off`; it does not apply to plugin skills.
- Reference machine: ~165 wired skills, ~30k-char listing, ~60 descriptions already dropped, 11 skills invoked in 36 days (private research `usage-report.md`; its `usage.py` is the logic reused here).
- Evidence source is `~/.claude/projects/**/*.jsonl`, kept ~30 days (`cleanupPeriodDays`), per machine. Cross-machine evidence needs git as the sync layer (the private repo).
- gstack's pattern: short listing descriptions, long procedures in `sections/*.md` loaded on demand.
- Issue #18 (scheduled skill-scout) is folded in only as a precedent: a scheduled job whose output a human reviews, never auto-applied.
- `foundations` adds `GRID_BASELINE` to `wire.sh` and the skill-discovery exclusions; this change reuses both and adds neither.

## Approach

Four layers, each usable alone:

1. **Measure and gate** (`scripts/budget.py`, `docs/budget-target.json`).
2. **Shrink what the-grid owns** (descriptions, `sections/`).
3. **Collect evidence** (`scripts/usage/extract.py`, weekly job, per-host JSON in the private repo).
4. **Propose pruning** (`scripts/usage/aggregate.py`, `scripts/usage/prune_report.py`, `scripts/prune-report.sh`).

### 1. Budget measurement

Entry cost model (stdlib only, no Claude Code needed):

```
listing_text = whitespace-collapsed description + (" " + when_to_use if present), cut to truncate_at (1536)
listing_text = "" when frontmatter has disable-model-invocation: true
entry_chars  = len(name) + len(listing_text) + 4      # "- name: desc\n" overhead, approximate
```

Two scopes, because the baseline is personal and gitignored (#24) while owned content is public and deterministic:

| scope | what is measured | where it runs | enforced |
|---|---|---|---|
| `owned` | `skills/*/SKILL.md`; `agent-factory/roles/*/role.yaml` (`_retired` skipped) | everywhere, incl. CI | always |
| `baseline` | skills wired by the baseline manifest only (no machine overlay), from `scripts/lib/baseline_wired.py`; composed-project symlinks ignored (roles are counted from source in `owned`) | machines with `baseline-submodules.txt` and initialised submodules | when measurable, else skipped loudly (catalog-check precedent) |

Role description = `description:` if present, else `"<title>. <summary>"` (whitespace-collapsed). Roles split by `role.yaml orchestrator: true`: orchestrators are skills (skills total), specialists are agents (separate agents total, a different listing). Private roles (`GRID_PRIVATE_ROLES_DIR`, `~/.the-grid-private/roles`) are never read, so the number is deterministic.

`baseline_wired.py` runs `wire.sh` with `GRID_DRY_HOME=<tmp>` (foundations: redirects every home-derived target, so a measurement never touches the real home) plus `SKILLS_DIR=<tmp>/skills`, `AGENTS_DIR=<tmp>/agents`, `GRID_SKIP_CATALOG=1` and `GRID_HOST=__baseline__` (a host with no overlay file), passing `GRID_BASELINE` through when set, and reads the resulting symlinks. This mirrors `foundations`' `tests/helpers/wired.bash`. The gstack runtime-root link (`skills/gstack -> repos/gstack`, foundations#5) is not a skill dir but Claude Code lists it from `repos/gstack/SKILL.md`, so it is counted as one entry named `gstack`.

`docs/budget-target.json` (committed; numbers filled by the implementer with `--update-target`):

```json
{
  "schema": 1,
  "truncate_at": 1536,
  "per_entry_max_chars": 250,
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
--check            exit 1 if any total > its target, any listed owned description > per_entry_max_chars
                   or spans more than one line after collapsing, any owned SKILL.md > skill_body_max_bytes,
                   or sections/ integrity fails; exit 3 if all else passes but the baseline scope was skipped;
                   0 otherwise
--update-target    rewrite totals in docs/budget-target.json to the current measurement;
                   refuses to RAISE a number unless --allow-raise is also given
--json             machine-readable output (sorted keys)
env: GRID_DIR, GRID_BASELINE (passed to wire.sh)
```

"Single line" is checked on the raw scalar: a description is single-line when it is a plain or quoted scalar on one line, or a folded `>`/`>-` scalar (folding yields one line). A `|` literal block with more than one non-empty line fails.

The ratchet is the regression guard: targets only go down in normal work; raising one is a visible, reviewed diff to `docs/budget-target.json`.

`gate.sh` gets a `budget` check; exit 3 is recorded as `SKIPPED+=(budget-baseline)` and counts as pass. Without `python3` or `scripts/budget.py` the check is skipped loudly (`SKIPPED+=(budget)`, pass), covered by a `tests/test_gate.bats` case.

### 2. Shrinking owned content

**Descriptions.** At most 250 chars, one line. Form: what it does, then the key trigger phrases (`Use when "x", "y"`). Keep the 2-4 trigger phrases most likely to be typed; drop `or invokes /<name>` (the name is already listed) and secondary prose. Triggers stay in the description because Claude selects skills from the listing; a trigger moved into the body is invisible until the skill is already chosen. No `## When to invoke` body section and no `when_to_use` field.

Worked example (`caveman`, 233 -> ~150 chars):

```yaml
description: Ultra-compressed replies, no filler or hedging, technical accuracy kept. Use when the user says "caveman mode", "terse", "be brief" or "less tokens".
```

**Roles.** `role.yaml` gains `description:` (one line, <= 250 chars, form `<Title>. <what it owns>. Use for <when to reach for it>.`). `compose.py` emits it verbatim as the subagent/skill `description` instead of the legacy formula (`... Use this subagent for X work.` / `... Invoke with /x ...`). Roles without `description:` keep the legacy formula byte-for-byte, so private roles keep working. `ROLE_YAML_KEYS` gains `description`.

**Sections.** Owned `SKILL.md` over 4,000 bytes (today: mine-learnings, openspec-help, setup-repo-skills, skill-scout, spec-scout, grid-help, un-claudish) is split:

```
skills/<name>/SKILL.md              frontmatter, purpose, step skeleton, ## Sections
skills/<name>/sections/<topic>.md   plain markdown, no frontmatter, <= 6000 bytes each
```

`## Sections` in `SKILL.md` lists one line per file:

```
## Sections
Read a section only when its condition applies; do not preload them.
- sections/output-format.md: read when writing the final report
- sections/dedupe-rules.md: read when comparing against already-wired skills
```

wire.sh already symlinks the whole skill directory, so `sections/` travels with no wiring change. No manifest file.

### 3. Usage extraction

Layout:

```
scripts/usage/extract.py             CLI: scan adapters, merge into <private>/usage/<host>.json
scripts/usage/adapters/__init__.py   REGISTRY = [claude_code.ClaudeCode]
scripts/usage/adapters/claude_code.py
scripts/usage/aggregate.py           importable aggregate(dir, window_days); no CLI
scripts/usage/prune_report.py        CLI behind scripts/prune-report.sh
scripts/usage/weekly.sh              the scheduled job
scripts/usage/install-schedule.sh    renders via scripts/lib/render-schedule.sh (loops#3); no local templates
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
        # {"day": "2026-10-08", "kind": "hook",    "name": "PreToolUse:Bash"}
        # {"day": "2026-10-08", "kind": "listing", "skills": 187, "chars": 30002}
        # {"day": "2026-10-08", "kind": "tokens",  "model": "claude-sonnet-5-5",
        #  "in": 2, "out": 680, "cache_read": 34972, "cache_write": 33172}   # one event per unique message
    def wired(self) -> dict: ...               # {"skills": [names], "agents": [names]} on this machine
    stats: dict                                # optional, filled while events() runs (see Drift canary)
```

Contract: `events()` yields each logical event exactly once (the adapter de-duplicates; the extractor only sums). Adding another harness = one new module plus one `REGISTRY` line. Only `claude_code.py` ships.

**Claude Code adapter** ports `usage.py` logic (the research script, not imported) with the corrections the real transcripts need. It streams every `*.jsonl` under `$CLAUDE_PROJECTS_DIR` (default `~/.claude/projects`) including `subagents/`, one line at a time (the largest real file is ~7 MB; the whole tree scans in a few seconds, so no incremental state or mtime filtering).

Event rules:

- `Skill` tool_use -> skill (`input.skill`); `Agent`/`Task` tool_use -> agent (`input.subagent_type`, default `(default)`). Missing `input.skill` -> dropped.
- User message whose text, after leading whitespace, starts with `<command-name>` (optionally preceded by one `<command-message>...</command-message>`) -> slash, leading `/` stripped from the name. There is no "leading `/token`" fallback: it matched nothing on a real 30-day tree and is the only path by which pasted text could be stored. A `<command-name>` appearing mid-prose is not a command. Slash events come only from top-level (non-`subagents/`) files.
- `attachment.type` starting `hook_` (`hook_success`, `hook_non_blocking_error`, ...) -> hook, keyed by `attachment.hookName` (already of the form `<hookEvent>` or `<hookEvent>:<matcher>`, e.g. `PreToolUse:Bash`, `SessionStart:startup`); one event per fire, any outcome. Only the name is read: `command`, `stdout`, `stderr` and `toolUseID` (the command holds absolute paths) are never read or stored.
- `attachment.type == skill_listing` with `isInitial` true -> listing (`skills` = `skillCount`, `chars` = `len(content)`).
- Assistant record with `message.usage` and a `message.id` -> tokens (`input_tokens`, `output_tokens`, `cache_read_input_tokens`, `cache_creation_input_tokens`; non-int, bool or negative values count as 0); `message.model` is the key after dropping a trailing `[...]` suffix. Subagent files count too.
- Day = first 10 chars of the record `timestamp` (UTC), required to match `^\d{4}-\d{2}-\d{2}`; otherwise the event is dropped and counted in `stats.no_day`.
- Names (skill, agent, slash, model) must match `^[A-Za-z0-9][A-Za-z0-9:_.-]{0,63}$`, else dropped (this also drops `<synthetic>`).

De-duplication (verified against a real tree: 15,540 assistant usage records carry only 7,707 distinct message ids, 117 ids appear in more than one file because resumed sessions copy history, and copies keep the original timestamp):

- Tool calls are keyed by the `tool_use` block `id`; each id counts once across all files in the scan.
- Slash commands and hook fires are keyed by the record `uuid`; each uuid counts once across all files. (`toolUseID` is not unique per fire: several hooks share one tool use.)
- Tokens are keyed by `message.id` across all files. Streamed chunks of one message repeat the same id with a growing `output_tokens` (a real pair: 8 then 680), so the message value is the field-wise MAX over its chunks, not the first or last chunk seen; this is order-independent. A message's day is the earliest day among its chunks. Records without a `message.id` are skipped (counted in `stats.no_id`); `uuid` is not a fallback because it is unique per chunk and would defeat the de-duplication.
- The adapter buffers the unique ids and message maxima in memory and yields after the scan completes (about 8k messages per 30 days).
- Bad JSON lines, non-object lines and unreadable files are skipped and counted in `stats`.

`wired()` lists `$SKILLS_DIR` (default `~/.claude/skills`) and `$AGENTS_DIR` (default `~/.claude/agents`, `.md` stripped), dotfiles skipped; a missing directory yields no key for that list (so the merge keeps the previous snapshot).

**Drift canary.** Claude Code changes its transcript format without notice, and a parser that silently recognises nothing looks like "nothing was used". The adapter fills `stats` = `{files, lines, bad_lines, assistant, no_day, no_id}`; `extract.py` prints it in its one-line summary and prints a `WARNING: transcript format may have changed` line when `lines > 0` and `assistant == 0`, or `bad_lines * 20 > lines`. Stats are never written to the output file (no churn). Because the merge is max-only, a drifted scan can not lower stored counts; it can only fail to raise them.

**Output** `<private>/usage/<host>.json` (host = `--host` else `GRID_HOST` else `hostname -s`; one writer per file, so git never conflicts):

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
          "hooks":  {"PreToolUse:Bash": 12, "Stop": 3},
          "tokens": {"claude-sonnet-5-5": {"msgs": 41, "in": 90, "out": 31200, "cache_read": 2100000, "cache_write": 410000}}
        }
      },
      "wired":   {"skills": ["handoff", "tdd"], "agents": ["grid-qa-engineer"]},
      "listing": {"2026-10-09": {"skills": 187, "chars": 30002}}
    }
  }
}
```

Counts only: no prompt text, paths, project names, session ids or message ids. Skill, agent and slash names are stored as seen, so a private skill named after a client would appear in the (private) repo; `docs/usage.md` says so. Token totals are stored per DAY (not per month) because the max-merge needs the same buckets as the transcripts' expiry; months are summed at read time. Every day with any assistant message gets a `days` entry via `tokens`, so an idle-of-skills day is distinguishable from an unscanned day.

`host` = `--host` else `GRID_HOST` else `hostname -s`, then every char outside `[A-Za-z0-9._-]` becomes `_`. `extract.py` exits 2 with a message when the result is empty or `localhost` (macOS default for unconfigured hosts): two machines sharing a name would share one file, which breaks the one-writer rule and silently max-merges two hosts together. `--out` resolving inside `$GRID_DIR` (the public repo) is refused with exit 2: personal data never lands there.

**Merge rule (idempotent, retention-safe).** The scan covers whatever transcripts survive. For each day and key, the stored value becomes `max(old, new)`; this applies per leaf: each skill/agent/slash count, and each of `msgs`/`in`/`out`/`cache_read`/`cache_write` per model. Days not in the scan are untouched; `wired` is replaced by the latest snapshot only for a list the scan produced; `listing` per day takes the max chars. `updated` changes only when some other field changed. Output is written with sorted keys, 2-space indent, trailing newline, atomically (temp file named `.<host>.json.tmp` in the same directory, so a leftover is never read as a host file, then rename), and not rewritten when unchanged.

Why max is correct: the scan is always a subset of history (expired files drop out, a half-finished day is only partly there), and every leaf is a de-duplicated sum over a subset, so the true value is `>=` any scan. Max therefore never loses data and never double counts across overlapping weekly scans. It can not repair an inflated stored value, so the de-duplication rules above must be right from the first run; changing what a count means needs a `schema` bump.

An existing `<host>.json` that does not parse (truncated, conflict markers) is never overwritten: `extract.py` exits 1 with the path, `weekly.sh` logs it, and the previous good version is in git. A parseable file with an unknown `schema` is treated the same way.

**Retention.** Default `cleanupPeriodDays` is 30; a weekly run loses nothing when every run succeeds, but a laptop asleep for a month loses a window. Recommended: `"cleanupPeriodDays": 60` in `~/.claude/settings.json` on every machine. `extract.py` prints a one-line warning when the setting is unset or < 45 (file read from `$CLAUDE_SETTINGS`, default `~/.claude/settings.json`); documented in `docs/usage.md`. Never applied automatically.

### 4. Scheduling

`weekly.sh` (idempotent, safe to run twice):

```
1. python3 "$GRID_DIR/scripts/usage/extract.py" --out "$PRIVATE/usage"    # no adapter available -> exit 0
2. if "$PRIVATE" is a git repo:
     git -C "$PRIVATE" pull --rebase --autostash        (failure -> git rebase --abort, ignore errors; log, continue)
     git -C "$PRIVATE" add usage/<host>.json
     git -C "$PRIVATE" diff --cached --quiet || git -C "$PRIVATE" commit -m "usage: <host> <YYYY-MM-DD>"
     git -C "$PRIVATE" push                             (failure -> log, leave committed; next run retries)
3. append one line to "$STATE/usage.log"
```

`PRIVATE=${GRID_PRIVATE_DIR:-$HOME/.the-grid-private}`; `STATE=${GRID_STATE_DIR:-$HOME/.grid}` (machine-local state per D8; created with `mkdir -p`). A thin client without the private repo still writes the file locally and skips git. Commits carry no AI attribution (automated job).

`install-schedule.sh [--uninstall]` picks a scheduler (`GRID_SCHEDULER=launchd|systemd|cron` overrides; default Darwin -> launchd, Linux with `systemctl` on `PATH` -> systemd, else cron) and renders every file through the shared `scripts/lib/render-schedule.sh` weekly mode (loops#3); there are no templates in this change and no absolute paths in tracked files.

| scheduler | file written | cadence | printed activation (never run) |
|---|---|---|---|
| launchd | `$LAUNCH_AGENTS_DIR/io.the-grid.usage.plist` (default `~/Library/LaunchAgents`) | Monday 09:00 (missed runs fire on wake) | `launchctl bootout` + `launchctl bootstrap gui/$(id -u) <plist>` |
| systemd | `$SYSTEMD_USER_DIR/grid-usage.{service,timer}` (default `~/.config/systemd/user`) | `Mon 09:00`, `Persistent=true`, `RandomizedDelaySec=1h` | `systemctl --user daemon-reload && systemctl --user enable --now grid-usage.timer`; `loginctl enable-linger` note when headless |
| cron | nothing | `0 9 * * 1` | the rendered crontab line |

The installer never runs `launchctl`, `systemctl`, `crontab` or `loginctl`. A `GRID_DIR` or state path the renderer cannot escape safely makes it exit 2 before writing anything. Installing and activating is per machine and is a HUMAN task.

### 5. Prune report

`scripts/prune-report.sh [--window-days 90] [--rare 2] [--min-days 28] [--usage-dir D] [--out FILE] [--json]` wraps `prune_report.py`; `--usage-dir` defaults to `${GRID_PRIVATE_DIR:-$HOME/.the-grid-private}/usage`. Read-only: it writes stdout (or `--out`) and nothing else.

`aggregate(dir, window_days)` reads every `*.json` in the usage dir, ignores non-JSON files, files that do not parse and unknown `schema` (the ignored file names are returned under `ignored` so the report can print them), and returns a dict keyed by harness name, each value holding: `skills`/`agents`/`slash` totals over the window (window ends at the latest `days` key), `hosts` count, `first_day`/`last_day`/`coverage_days` (inclusive span across all hosts), union of `wired`, and `tokens`: `{ "YYYY-MM": { model: {msgs, in, out, cache_read, cache_write} } }` summed over hosts and over ALL stored days (months are the unit, so the window does not cut them). `hooks` totals over the window are returned alongside `skills`/`agents`/`slash`. `prune_report.py` never reads `tokens` or `hooks`; the host-file recipe for reading it is in `docs/usage.md`.

Per baseline-wired skill (set from `baseline_wired()`, giving the source repo):

```
uses  = skill-tool calls + slash invocations of that name, all hosts, in window
state = never (0) | rare (1..--rare) | used
```

Skipped from proposals: names in `docs/prune-keep.txt` (one name per line, `#` comments); everything when `coverage_days < --min-days` (report says "insufficient history: N days of M required" and stops after the evidence section).

Proposals, ordered by chars saved, numbered so the operator can reply "apply 2, skip 3":

- **A. Demote a repo.** Baseline whole-repo entry where >= 90% of its wired skills are `never`/`rare`: propose moving to library (delete the line) or replacing with per-skill entries for the `used` ones (listed). Saving = sum of entry chars of the dropped skills.
- **B. `name-only` a skill.** Any other `never`/`rare` skill: saving = listing chars. All B items are also printed as one ready-to-paste block `{"skillOverrides": {"<name>": "name-only", ...}}`.
- **C. Unused agents.** Agents in any host's `wired.agents` with zero uses: listed with an overlay suggestion `-project:<name>` where the agent name starts with `<slug>-` for a config in `agent-factory/examples/*.yaml` (read its top-level `slug:` and `project:` lines; longest matching slug wins), else no suggestion. No saving figure (separate budget).

Evidence footer: hosts reporting, day coverage, and the standing caveats (only Skill-tool and slash invocations are visible; a model reading a SKILL.md directly is not; slash and Skill events can double-count, which only matters for `rare`).

## Decisions

- Decided: budget scopes are owned (always enforced) + baseline (only where `baseline-submodules.txt` and initialised submodules exist); reason: the baseline file is personal and gitignored, so CI cannot measure it.
- Decided: no `live` scope in `budget.py`; reason: the extractor already records the real listing size from transcripts.
- Decided: baseline is measured by running `wire.sh` into a temp dir with `GRID_HOST=__baseline__`; reason: reuses the real wiring logic (incl. `foundations`' exclusions) and ignores overlays, no second parser to drift.
- Decided: private and composed-on-disk roles are never measured; roles are measured from `role.yaml` source; reason: composed output is git-ignored and differs per machine.
- Decided: entry cost = `len(name) + len(description [+ when_to_use] cut to 1536) + 4`, and 0 listing chars for `disable-model-invocation: true`; reason: matches the documented listing rules; the exact line format is undocumented, a stable proxy suffices for a ratchet.
- Decided: legacy role description for measurement is `"<title>. <summary>"`; reason: the compose suffix depends on slug and team config, and group 2 gives every public role an explicit `description:`.
- Decided: targets are a ratchet in `docs/budget-target.json`; `--update-target` refuses to raise without `--allow-raise`; reason: regressions must be a visible diff.
- Decided: per-entry limit 250 chars, single line, applies to owned skills and role descriptions only, and not to skills with `disable-model-invocation: true` (not listed); reason: D7 target; upstream text is not ours to edit.
- Decided: key trigger phrases stay in the description; no `## When to invoke` section, no `when_to_use` field; reason: Claude selects skills from the listing only (D7).
- Decided: the checker is Python 3 stdlib with its own scalar reader (plain, quoted, `>`, `>-`, `|`); reason: `vetting`'s `miniyaml` rejects block scalars, and owned descriptions use `>`.
- Decided: gate exit code 3 from `budget.py` means "baseline scope skipped" and counts as pass with a notice; reason: matches the catalog-check precedent.
- Decided: orchestrator roles count toward an orchestrator total, specialist roles toward an agents total; reason: they feed different Claude Code listings.
- Decided: `role.yaml` `description:` is emitted verbatim and replaces the legacy formula only when present; reason: private roles keep working untouched.
- Decided: split threshold is `SKILL.md` > 4,000 bytes, sections <= 6,000 bytes each, no `manifest.json`; reason: smallest rule that catches the 7 largest owned skills.
- Decided: splitting must not change behaviour; acceptance is that every non-blank line of the old file appears in `SKILL.md` or a section (apart from the added index and the description line); reason: a mechanical, checkable bar for an unattended agent.
- Decided: usage also stores per-day token totals per model (`msgs`, `in`, `out`, `cache_read`, `cache_write`), kept out of the prune logic (operator decision); reason: measuring the cost of hooks and instincts needs it and it is a few numbers per day.
- Decided: per-day hook-fire counts are stored keyed by `hookName` only (operator decision), kept out of the prune logic like tokens; reason: with tokens they let hook and instinct overhead be attributed per hook. `hookName` already embeds the event, so `hookEvent` is not stored separately; the hook command, which holds paths, is never read.
- Decided: tokens are de-duplicated by `message.id` across all files with a field-wise max over streamed chunks, never first-seen; reason: on a real tree 15,540 records are 7,707 messages, and the first chunk of a pair had `output_tokens` 8 against a final 680, so first-seen (the research script) undercounts output and summing records double counts.
- Decided: tool calls are de-duplicated by `tool_use` id and slash commands by user `uuid`, both across files; reason: resumed sessions copy history into a new file with the original timestamps (8 of 224 tool ids and 157 of 9,649 user uuids seen in more than one file on a real tree), which would inflate counts that max-merge can never correct.
- Decided: the leading-`/token` slash fallback is dropped; slash needs a message that starts with `<command-name>`; reason: 0 fallback matches against 58 tag matches on a real tree, and it is the only way pasted text could reach the output.
- Decided: token buckets are per day and merged by leaf max, summed to months only at read time; reason: a month bucket cannot be max-merged once its early days expire.
- Decided: the adapter records `stats` and the extractor warns on a parse that recognised no assistant records or mostly bad lines; stats are not stored; reason: a silent format change must not look like zero usage, and storing stats would churn the file.
- Decided: `extract.py` refuses an empty or `localhost` host name, an `--out` inside `$GRID_DIR`, and overwriting an existing host file that does not parse; reason: shared names break the one-writer rule, personal data stays out of the public repo, and a bad file must not destroy history.
- Decided: usage is stored as per-day buckets with max-merge, not a rolling snapshot; reason: weekly runs overlap the 30-day window and must not double count or lose data (max is valid because every scan is a de-duplicated subset of history).
- Decided: day boundary is UTC taken from the record timestamp; reason: transcripts carry UTC and hosts span timezones.
- Decided: names failing `^[A-Za-z0-9][A-Za-z0-9:_.-]{0,63}$` are dropped; reason: slash capture must never store pasted text or paths.
- Decided: no per-project breakdown is stored; reason: project directory names embed the user name and add no pruning value.
- Decided: one file per host, written only by that host; reason: git merges never conflict.
- Decided: the job commits only `usage/<host>.json`, rebases on pull, and treats push failure as non-fatal; reason: a flaky network must not break the timer or lose the data.
- Decided: the job log is `${GRID_STATE_DIR:-~/.grid}/usage.log`; reason: machine-local state lives under `~/.grid/` (D8).
- Decided: schedule is weekly Monday 09:00 local with `Persistent=true` and `RandomizedDelaySec=1h` on systemd; reason: weekly is well inside 30-day retention and the jitter avoids all hosts pushing together.
- Decided (G2): scheduler text is rendered only by loops' `scripts/lib/render-schedule.sh` weekly mode (Depends on loops#3); this change ships no templates; the installer writes files and only PRINTS activation commands; unsafe install paths exit 2; reason: one renderer for every scheduler in the-grid, and system-level side effects stay with the human.
- Decided: recommend `cleanupPeriodDays: 60`; extract warns below 45 but never edits settings; reason: margin for missed runs at the cost of disk only.
- Decided: `prune-report` is `scripts/prune-report.sh`; `manifest-lock-install` may later route `grid prune-report` to it; reason: this change must not depend on that change.
- Decided: aggregation is an importable function used by the report, not its own CLI; reason: one entry point is enough.
- Decided: usage for a skill = Skill-tool calls + slash invocations of the same name; reason: user-typed slash skills may not emit a Skill call, and over-counting only makes the report more conservative.
- Decided: defaults `--window-days 90 --rare 2 --min-days 28`; reason: one month of data across hosts is the minimum to call anything unused.
- Decided: repo demotion threshold 90% unused; reason: avoids proposing to drop a repo for one dead skill (that case is a `name-only` line).
- Decided: `docs/prune-keep.txt` is tracked and starts with `handoff` and `grid-help`; reason: front-door skills must never be proposed even if unused for a month.
- Decided: the report prints the `skillOverrides` snippet in the documented shape and never writes settings; reason: settings.json is not grid-owned and the override is per machine.
- Decided: the installer prints but never runs `launchctl`, `systemctl`, `crontab` or `loginctl`; reason: system-level side effects stay with the human (superseded detail: covered by the G2 line above).
- Decided (G1): `baseline_wired.py` runs `wire.sh` with `GRID_DRY_HOME=<tmp>` as well as temp `SKILLS_DIR`/`AGENTS_DIR`; a bats case proves a sentinel in a fake real home is untouched; Depends on foundations#8 (its `GRID_DRY_HOME` task); reason: a measurement must never write to any home-derived target.
- Decided (G3): the gate's `budget` check skips loudly (`SKIPPED+=(budget)`, pass) when `python3` or `scripts/budget.py` is absent, with a `tests/test_gate.bats` case; reason: a missing interpreter must be visible, not a silent pass or a hard fail.
- Decided (G5): the baseline sentinel host is `GRID_HOST=__baseline__`; reason: one shared sentinel across changes.
- Decided (G6): the gstack runtime-root link (`skills/gstack -> repos/gstack`, foundations#5) counts as one baseline entry named `gstack` with its description from `repos/gstack/SKILL.md`; Depends on foundations#5; reason: Claude Code lists it like any skill dir.
- Decided (QA13): owned-skill saving target is >= 30%; if missed, the PR reports the actual figure; trigger phrases are never cut to reach it; reason: D7 keeps triggers, the number is a goal not a gate.
- Decided (QA14): task 2.6 recomposes `learning-desk` too when its composed output exists; reason: it is a public config the gate's compose check covers.
- Decided: tests use fixture transcripts and per-host JSON under `tests/fixtures/usage/` (synthetic names only) and temp dirs; reason: tests never touch the real `~/.claude` or private repo.

## Risks and open points

- `skillListingBudgetFraction` and the drop-least-invoked rule are Claude Code behaviour; the gate only measures description size and does not simulate truncation.
- Shorter descriptions may reduce model-initiated invocation of owned skills; mitigated by keeping the key trigger phrases and by the report showing what is actually used.
- A skill or agent whose name fails the name regex is dropped from counts.
- Transcript fields are an undocumented format. The drift canary catches a parser that sees nothing, not one that sees a renamed tool; the `Skill`/`Agent`/`Task` tool names are the first thing to check when counts stop rising.
- Counts only ever go up per day. A de-duplication bug fixed later leaves inflated history in place until the affected host file is deleted and re-extracted (possible only for days whose transcripts still exist).
