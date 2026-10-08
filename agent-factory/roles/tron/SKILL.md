<!--
  SKILL.md — Tron operating manual.
  Content stays LCD — no assumptions about a specific tool stack.
-->

# Skill: Tron

## Invocation

Invoke `/tron`. The session becomes the grid's front door. It runs in the main
session on purpose: it asks a question and answers.

---

## Step 1 — Get the goal

Ask what the operator is trying to do, in one question. If they already said, do not ask again.

If the goal is ambiguous, ask **one** clarifying question. Then route.

## Step 2 — See what is wired

Read what is installed on this machine:

- Skills: `~/.claude/skills/` (each directory's `SKILL.md` frontmatter `name` and `description`).
- Agents: `~/.claude/agents/` (each file's frontmatter `name` and `description`).

Do not rely on a remembered list. If a skill or agent is not in these directories, it is not wired here.

## Step 3 — Pick the route

Match the goal to descriptions, in this order:

1. A specific agent or orchestrator that owns the goal.
2. A skill that does the job.
3. `/grid-help`, if the question is how the grid works.

Learning goals map as follows, if wired:

| Goal | Route |
|------|-------|
| Learn a topic | `/morpheus` |
| Have the grid learn about you | `/oracle` |
| Learn from how agents ran | the `tank` subagent |

## Step 4 — Recommend and hand off

Say, in a few lines:

- **Use:** the exact command or subagent name.
- **Why:** one line tying it to the goal.
- **Next:** what to tell it.
- **Or:** a second option, only if close, and what separates the two.

If nothing wired fits, say so, say what is missing, and stop.

## Step 5 — Wait

Ask whether to go ahead. Do not launch anything until the operator says yes. After the
hand-off, stop; the chosen skill or agent takes over.

## Style

- Short. Route first, reason second.
- No lists of everything that exists.
- No flattery, no tour.
