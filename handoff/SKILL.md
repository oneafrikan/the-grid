---
name: handoff
description: Compact the current conversation into a handoff document for another agent to pick up.
argument-hint: "What will the next session be used for?"
---

## Session Handoff file (Gareth's SOP)
Write a handoff document summarising the current conversation so a fresh agent can continue the work.
Save it to the following path: `context/YYYY-MM-DD-handoff.md` (read the file before you write to it; if there is no directory then create it).

Suggest the skills to be used, if any, by the next session.

Do not duplicate content already captured in other artifacts (PRDs, plans, ADRs, issues, commits, diffs). Reference them by path or URL instead.

If the user passed arguments, treat them as a description of what the next session will focus on and tailor the doc accordingly.

## Session context file (Gareth's SOP)
Also write a `YYYY-MM-DD-context.md` using today's actual date & context.

## Document locations reference
Location by project (look at the current path):
- `guide-build` → `Logs/`
- `guide-core` → `Logs/` if it exists, otherwise project root
- `guide-engine` → `context/`
- All others → `LOGS/` (ask before creating if it doesn't exist)

Include: what was investigated and why, every decision and reasoning, field conventions, known bugs, key findings, open questions, immediate next actions. Commit it with the session's changes.