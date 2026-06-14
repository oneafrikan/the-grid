---
name: handoff
description: Compact the current conversation into a handoff document for another agent to pick up.
argument-hint: "What will the next session be used for?"
---

## Session Handoff file (Gareth's SOP)

Write a handoff document summarising the current conversation so a fresh agent can continue the work.

**Template:** load `handoff-template.md` from this skill's base directory and fill it in. Do not invent a different structure.

**Save location:** follow the Document locations reference below. Read the file before writing (create the directory if it doesn't exist).

**Rules:**
- Do not duplicate content already captured in commits, diffs, PRDs, plans, or ADRs — reference them by path or URL instead
- If the user passed arguments, treat them as a description of what the next session will focus on and tailor accordingly
- Suggest relevant skills for the next session in the Suggested Skills section

---

## Session context file (Gareth's SOP)

Also write a context file using today's actual date.

**Template:** load `context-template.md` from this skill's base directory and fill it in.

**Save location:** same directory as the handoff file, named `YYYY-MM-DD-context.md`.

**Must include:** what was investigated and why, every decision and reasoning, field conventions, known bugs, key findings, open questions, immediate next actions.

---

## Document locations reference

Determine save location by matching the current working directory path:

| Project | Location |
|---------|----------|
| `guide-build` | `Logs/` |
| `guide-core` | `Logs/` if it exists, otherwise project root |
| `guide-engine` | `context/` |
| Obsidian vault (`Gareth_SovereignOS`) | `LOGS/` |
| All others | `LOGS/` — ask before creating if it doesn't exist |

---

## After writing

Commit both files with the session's other changes if the project is a git repo.
