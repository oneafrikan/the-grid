# Mapping guide: which block goes where

Classify by what the block IS, not by where it sits in the source. A block is a
paragraph, a list item (with its nested items), a heading, a code fence, a table.
The headings are blocks too: send a heading with the blocks it introduces, or keep
it. Use ranges (`B004-91c2..B009-00ab`) for runs that go together.

| The block says | Destination |
|---|---|
| A must-not ("never commit X", "do not touch Y") | `GUARDRAILS.md` |
| A standing order or "always/never" with a reason, from the operator | `RULES.md` |
| How we do things here: naming, style, git, docs habits | `CONVENTIONS.md` |
| Run, build, test, lint, deploy commands | `CONVENTIONS.md` (`#Testing`, `#Common tasks`) |
| Structure, how it works, data flow, key parts, dependencies | `DESIGN.md` |
| A dated choice and its reasons | `DECISIONS.md` |
| Pointers to docs, specs, vendor material | `DOCS.md` |
| Pointers to logs or handoffs | `LOGS.md` |
| People, roles, contacts | `HUMANS.md` |
| A lesson: "gotcha", "never again", "we got burned by ...", with a cause or rule | `LEARNINGS.md` |
| A pointer to what agents should remember across sessions ("remember to ...", "see X before Y") | `MEMORY.md` |
| A formula or a worked number | `CALCULATIONS.md` |
| "We assume ..." | `ASSUMPTIONS.md` |
| Current state, next steps, open work | `CONTEXT.md` |
| What changed, release notes | `CHANGELOG.md` |
| Why the project exists | `PURPOSE.md` |
| Roles and rules for agents | `AGENTS.md` |
| Anything else, or you hesitate | `unsorted` |

## Rules

- Ambiguous means `unsorted`. Never guess a destination, never drop a block.
- `keep` leaves the block in the entry doc. Use it only for text that belongs
  in a short CLAUDE.md (what this is, a read-when pointer). Kept blocks must be
  pasted verbatim into the slim replacement or `finalize` refuses.
- A destination that does not exist is a plan error: scaffold it in step 2
  (`--with design,humans,learnings,memory,...`), or send the block to `unsorted`.
- Use an anchor (`DESIGN.md#Structure`) only for a heading that exists in the
  destination; the block lands at the end of that section. No anchor means the
  end of the file under `## Moved from <source>`.
- Reasons stay with their rule: a rule and the "why" lines under it are one
  range, not two destinations.
- A secret (token, password) found in a block: stop and tell the operator before
  applying; the script moves text, it does not judge it.
- Do not mark a doubtful block `keep` to avoid the question; `unsorted` is the
  safe default and the operator can sort `UNSORTED.md` later.
