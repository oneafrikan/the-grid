# Agents in this project

Optional. Skip it if you don't use the-grid's agents here.

The-grid keeps full agents that any session can use. A project can instead carry
a **lean** cut of just the roles it needs, deployed into its own `.claude/`:

```bash
# from the-grid checkout; pick the project and the roles
agent-factory/.venv/bin/python agent-factory/deploy.py /path/to/this/repo \
  --roles fullstack-engineer,sdet,technical-writer
agent-factory/.venv/bin/python agent-factory/deploy.py /path/to/this/repo --check   # drift report
agent-factory/.venv/bin/python agent-factory/deploy.py --list                       # what exists
```

- Files land as `.claude/agents/grid-<role>.md` (orchestrators as
  `.claude/skills/grid-<role>/SKILL.md`) plus `.claude/grid-agents.lock`.
- They are **generated** (marker comment at the top): never edit them. Change
  the role in the-grid, or put project facts in `.grid/project.yaml`, then re-run.
- Hand-written agents in `.claude/agents/` are never overwritten.
- Commit the generated files and the lock; `--check` tells you when the-grid has moved.

## CLAUDE.md block to adopt

Paste into this repo's `CLAUDE.md` and fill it in. Keep it terse and factual.

```markdown
## Checks
<the one command that runs every check; what it covers; what it deliberately does not>

## Working through Claude Code
| Skill | Use for |
|---|---|
| `<skill>` | <when> |

| Agent | Use for |
|---|---|
| `grid-<role>` | <the artifacts this role owns in THIS repo> |

## Conventions and constraints
- <hard invariants, one per line, as imperatives>
- Hand-synced mirrors (change both together): `<a>` <-> `<b>`
- Exists vs planned: <say plainly what is NOT built yet; delete the note the day it ships>
```

Draw agent lanes by who owns which artifact, not by job title. Treat agent
briefs and this block as documentation: when code changes, they go stale like
any other doc.
