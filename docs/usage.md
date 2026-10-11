# Usage tracking

Counts how often each skill, agent, slash command and hook is actually used, per
machine, so the prune report (a later step) can show what is safe to drop from the
always-loaded listing. A weekly job runs the extractor and commits one small JSON
file per host to your **private** repo. Nothing here is installed for you:
activating the schedule is a manual step per machine (see [Install](#install)).

## What is collected

Counts per UTC day, read from the Claude Code transcripts under
`~/.claude/projects` (override: `CLAUDE_PROJECTS_DIR`):

- Skill-tool calls, by skill name.
- Agent/Task-tool calls, by subagent type.
- Slash commands (`<command-name>` records only), by command name.
- Hook fires, by hook name (`PreToolUse:Bash`, `Stop`, ...).
- Token totals per model: messages, input, output, cache read, cache write.
- The size of the skill listing the session started with (skill count, characters).
- Which skills and agents are wired on the machine right now.

Not collected: prompt or response text, file paths, project names, session ids,
message ids, tool ids, hook commands or hook output. Skill, agent and slash names
are stored **as seen**, so a private skill named after a client lands in the
private repo. Keep the usage repo private.

## File schema

One file per host: `<private>/usage/<host>.json` (default private dir
`~/.the-grid-private`, override: `GRID_PRIVATE_DIR`). Only that host writes it, so
git never conflicts. Keys are sorted, output is 2-space indented.

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
          "tokens": {"claude-sonnet-5-5": {"msgs": 41, "in": 90, "out": 31200,
                                           "cache_read": 2100000, "cache_write": 410000}}
        }
      },
      "wired":   {"skills": ["handoff", "tdd"], "agents": ["grid-qa-engineer"]},
      "listing": {"2026-10-09": {"skills": 187, "chars": 30002}}
    }
  }
}
```

- `days.<day>.tokens` is keyed by model; `msgs` counts unique assistant messages
  (a message streamed in several chunks counts once, with the largest value).
- Tokens are stored per day, not per month, so a re-scan can be merged safely;
  months are summed when reading.
- Each scan is merged with the stored file leaf by leaf using `max(old, new)`. A
  scan only ever sees a subset of history (old transcripts expire), so max never
  loses data and never double counts when scans overlap.
- `wired` is replaced only for a list the scan could produce; `updated` changes
  only when something else did.

## Retention

Claude Code deletes transcripts after `cleanupPeriodDays` (default 30). The weekly
job loses nothing while every run succeeds, but a laptop that sleeps for a month
can lose a window. Keep a margin: add this to `~/.claude/settings.json` on every
machine:

```json
"cleanupPeriodDays": 60
```

The extractor prints a warning when the setting is unset or below 45. It never
edits your settings.

## Install

The installer writes the schedule files (or, for cron, prints the line) and
**prints** the activation commands. It never runs `launchctl`, `systemctl`,
`crontab` or `loginctl`. Run the printed commands yourself.

```bash
bash scripts/usage/install-schedule.sh              # install
bash scripts/usage/install-schedule.sh --uninstall  # remove exactly what it wrote
```

The job runs Mondays at 09:00 local time. Re-running the installer rewrites
identical files and prints `unchanged`.

| OS | Scheduler (auto-picked) | Files written | Then run |
|---|---|---|---|
| macOS | launchd | `~/Library/LaunchAgents/io.the-grid.usage.plist` | `launchctl bootout gui/$(id -u)/io.the-grid.usage 2>/dev/null; launchctl bootstrap gui/$(id -u) <plist>` |
| Linux with a systemd user manager | systemd | `~/.config/systemd/user/grid-usage.{service,timer}` | `systemctl --user daemon-reload && systemctl --user enable --now grid-usage.timer` |
| Linux without one | cron | none | add the printed crontab line |

- Force a scheduler with `GRID_SCHEDULER=launchd|systemd|cron`; override target
  directories with `LAUNCH_AGENTS_DIR` / `SYSTEMD_USER_DIR`.
- systemd: the timer is `Persistent=true` (a run missed while off fires at next
  start) with up to one hour of random delay. On a headless machine the installer
  also prints `loginctl enable-linger "$USER"`; run it so the timer fires while
  you are logged out.
- launchd runs a missed job when the Mac wakes.
- The installer exits 2 and writes nothing if the repo path or state dir contains
  a character outside `A-Z a-z 0-9 _ . / @ + -` (the shared renderer cannot escape
  it). Move the checkout to a plain path.
- Per-run log: `~/.grid/usage.log` (override: `GRID_STATE_DIR`). Under launchd the
  scheduler's own stdout and stderr go to `~/.grid/io.the-grid.usage.log`.
- Test it once by hand before trusting the schedule: `bash scripts/usage/weekly.sh`.

What `weekly.sh` does each run: extract into `<private>/usage/`; if the private
dir is a git repo, `pull --rebase --autostash`, commit only `usage/<host>.json`
with the message `usage: <host> <date>`, and push. Pull and push failures are
logged and never fatal (a failed pull also aborts any half-finished rebase); the
commit stays local and the next run retries. A private dir that is not a git repo
just gets the file.

## Reading `usage/<host>.json`

```bash
# Skills by total uses, most used first
python3 -c 'import json,sys,collections; d=json.load(open(sys.argv[1]))["harnesses"]["claude-code"]["days"]
c=collections.Counter()
for day in d.values():
    c.update(day.get("skills", {}))
for k,v in c.most_common(): print(v,k)' "$HOME/.the-grid-private/usage/<host>.json"
```

- A day with a `tokens` entry but no `skills` is a day with activity and no skill
  calls, as opposed to a day nobody scanned (no entry at all).
- `listing.<day>.chars` is the size of the skill listing that session began with;
  watch it fall after pruning.

## Adding an adapter

The extractor knows nothing about transcript formats. A harness is one module in
`scripts/usage/adapters/` plus one line in `REGISTRY` in
`scripts/usage/adapters/__init__.py`. The module defines a class with:

- `name`: the key under `harnesses` in the output file.
- `available()`: true when this harness's logs exist on the machine.
- `events(since_day)`: yields normalised events (shapes in the `__init__.py`
  docstring), each logical event **exactly once**. De-duplication is the adapter's
  job; the extractor only sums. Never yield prompt text, paths or ids.
- `wired()`: `{"skills": [...], "agents": [...]}` as wired on this machine; leave a
  list out when it cannot be produced.
- `stats` (optional): a dict filled while scanning, used for the format-drift
  warning.

`--registry module:ATTR` swaps in a different registry for testing; see
`tests/fixtures/usage/fake_adapter.py`.
