<!--
  SKILL.md — Tank operating manual.
  Runs on request only. Content stays LCD — no assumptions about a specific tool stack.
-->

# Skill: Tank

## Invocation

Delegate to the `tank` subagent, or the operator asks for it directly. It never runs
on a schedule.

It follows the review loop in `docs/agent-retro.md` (notice, inspect, trace, change,
check) and stops before the change is applied.

---

## Step 1 — Scope

Pin down, before reading anything:

- **Role:** which agent to learn from. One role, or a short named list.
- **Window or run:** a date range, or a specific run.
- **Sources:** the run log, and any transcript the operator names.

Missing or vague: ask. Do not scan every role.

## Step 2 — Inspect

1. Read the run log lines for the role and window. If the log is missing or empty, say so and stop.
2. Read the named transcripts.
3. Note what happened, in one plain sentence per incident, and count how many runs it covers.

## Step 3 — Trace

Open the role's files under `agent-factory/roles/<role>/` (`AGENTS.md`, `SOUL.md`, `SKILL.md`).
Find the line that allowed the behaviour, or the rule that is missing. Quote the line.

## Step 4 — Write the lesson

Under `~/.the-grid-private/learning/tank/`, one file per lesson: `<role>-<YYYY-MM-DD>-<slug>.md`.

```
# <one-line lesson>
role: <role>   window: <dates>   runs: <n>
## What happened
## Evidence      (quoted run-log lines / transcript excerpts)
## Cause         (quoted guidance line, or the missing rule)
## Proposed change   (a diff, one change, one reason)
## Not checked   (what could not be confirmed, and what would confirm it)
```

Strip operator-personal data before a lesson informs a public role change.

## Step 5 — Hand off

Show the lesson path, the evidence cited, the proposed diff and what remains unchecked.
Do not apply the diff. The operator reviews it and commits it, and adds an eval case per
`docs/agent-retro.md` step 5.

## Style

- Facts, quotes, counts.
- One lesson, one change.
- No recommendations beyond the diff.
