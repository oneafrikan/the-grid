<!--
  SKILL.md — Tron operating manual.
  Content stays LCD — no assumptions about a specific tool stack.
-->

# Skill: Tron

## Invocation

Invoke `$tron` in Codex or `/tron` in Claude Code. The session becomes the grid's front door. It runs in the main
session on purpose: it asks a question and answers.

---

## Step 1 — Get the goal

Ask what the operator is trying to do, in one question. If they already said, do not ask again.

If the goal is ambiguous, ask **one** clarifying question. Then route.

## Step 2 — See what is wired

Read what is available to the current host in this session:

- Prefer the host's discovered skill and named-agent catalogues. Reading another
  host's files does not register those assets here.
- Before treating an agent as available, inspect the host's actual spawn tool
  schema for a named-agent selector (for example `agent_type`) that accepts its
  registered name. A `task_name` label is not a named-agent selector. Installed
  TOML or Markdown files alone do not prove the host can select that role.
- For local inventory, read the current host's row in
  `~/.the-grid/scripts/lib/harnesses.txt` (or this checkout's registry). Use its
  `skills_dir` and `agents_dir`; honour the host's configured home overrides.
- Skills use each directory's `SKILL.md` frontmatter `name` and `description`.
  Codex's named agents use `.toml` files with `name`, `description`, and
  `developer_instructions`; Claude Code's agents use Markdown frontmatter.
- In Codex, the user skill root is `~/.agents/skills/` and the named-agent root is
  `$CODEX_HOME/agents/` (default `~/.codex/agents/`). Include discovered project and
  plugin assets rather than assuming the local user roots are the whole catalogue.

Do not rely on a remembered list. Distinguish files installed on disk from assets
the current host has discovered. If discovery cannot be verified, say so.

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

- **Use:** the exact command or registered subagent name. Use `$name` for Codex
  skills and `/name` for Claude Code skills; interpret slash examples below using
  the current host's invocation syntax. Select named agents through the host's
  native agent mechanism rather than copying their prompt into a generic agent.
- If the host exposes no named-agent selector, say that native specialists cannot
  be selected in this session. Prefer a discovered skill that covers the goal;
  do not recommend an installed agent as runnable or relabel a generic task as
  that specialist.
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
