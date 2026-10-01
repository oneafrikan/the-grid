# Role authoring guide — facts, not persona

How to write (or rewrite) a specialist role so every role in the grid behaves to the
same standard. A role is a *job description with checkable rules*, not a character.
Derived from running a real project with a small set of tightly-briefed agents, then
generalised so nothing project-specific lives in a role.

Applies to **specialist** roles. Orchestrators, cron-driven roles and the finance desk
have their own shapes; this guide does not change them.

## What changes, what doesn't

- **Edit:** `AGENTS.md` (add two sections, tighten Scope) and `SOUL.md` (only to meet
  the heading contract and remove contradictions).
- **Don't touch:** `role.yaml`, `SKILL.md` (the procedure), `IDENTITY/USER/MEMORY.md`,
  `_core/*`, routing tables (keep every route; only fix a route that is plainly wrong),
  anything project-specific. Do not invent capabilities the role does not have.
- Lean deploys keep every `AGENTS.md` section and `SOUL.md`'s Role identity,
  Decision-making, Escalation rules and "What the X is NOT". Those must stand alone.

## The contract (`compose.py --lint-roles` enforces this for roles in `authored-roles.txt`)

`AGENTS.md` must contain these sections after the title (lint checks presence, not order;
use this order by convention):

1. `## Scope` — what the role owns, in 3–6 lines, plus the routing table
   (`Need | Route to`). Draw lanes by **which artifact the role owns**, not by title.
2. `## What to get right hardest` (or `What to <verb> hardest`, e.g. `What to test hardest`) — a **ranked numbered list, 4–6 items** (lint enforces ≥ 4). Rank 1 is
   the failure that costs most when wrong *for this role*. Each item is concrete
   ("contract shape agreed before the client builds against it"), never a virtue
   ("quality", "attention to detail").
3. `## Hard rules` — **imperatives**, one per line, each checkable by someone reading
   the output. Every role gets the shared four below, plus 3–6 role-specific ones
   (lint enforces ≥ 4 rules; the shared-four wording and the upper bounds are convention).
4. `## Receiving work` — keep what exists; add what the role must have before starting
   and what the hand-off must contain.

`SOUL.md` headings are exactly: `Role identity`, `Core character (role layer)`,
`Decision-making (role layer)`, `Escalation rules (role layer)`,
`Working style (role layer)`, `What the <Title> is NOT` (or `What <Title> is NOT`).

### The shared four (every specialist's Hard rules include these, in the role's own words)

1. **Verify before claiming.** Never state that something works, exists, passes or is
   deployed without having run or read it in this session. Quote the command and its
   output as evidence; "should work" is not evidence.
2. **Exists vs planned, both directions.** Say plainly what is not built / not
   measured / not tested. Never upgrade a plan to a fact; delete a "not yet" the moment
   it ships.
3. **Report failures verbatim.** Failing output is pasted, not summarised. A failure
   is a finding, not an obstacle to route around.
4. **Do not grade your own homework.** Work you built is verified by a different role
   or an independent check; say who. If you must self-check, label it self-check.

## Writing rules

- Facts over adjectives. If a sentence would be true of any role, cut it.
- One rule per line. No paragraph hides a rule.
- Rules name the artifact or command they apply to, generically ("the shared API
  shapes", "the migration", "the prompt version") — never a specific repo's file.
- Keep what the role already says well. This is a tightening and a structure pass,
  not a rewrite of voice. Remove only contradictions and filler.
- No new dependencies on other roles' existence: route to a role by name, and say what
  to do if it isn't available ("tell the user which role should take it").
- Cost-visible: if the role's work spends money or touches production, one Hard rule
  says so.

## Size

Enforced: `AGENTS.md` ≤ 4096 bytes. Convention: `SOUL.md` does not grow.

Roles enrolled in `authored-roles.txt` that were written to this contract from the start
(sdet, fullstack-engineer, prompt-engineer, ai-engineer, technical-writer) needed no pass.

`AGENTS.md` ≤ 4 KB after the pass. `SOUL.md` does not grow. If a role cannot meet
the contract without exceeding that, the role is two roles — flag it, don't cram.

## Checking your work

```bash
agent-factory/.venv/bin/python agent-factory/compose.py --lint-roles
agent-factory/.venv/bin/python agent-factory/deploy.py --list
```

Both must stay clean. The reviewer reads the diff of each role: every change must be
traceable to this guide, and every pre-existing route and rule must survive.
