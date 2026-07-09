# Using the-grid

Setup is covered in [README.md](README.md) and [BOOTSTRAP.md](BOOTSTRAP.md). This
file is the other half: once it's wired, here's how you actually drive it in a
Claude Code session.

## Skills — slash commands

Every wired skill is a slash command in any Claude Code session, anywhere on the
machine — no per-project setup. Some examples:

```
/standup          — standup summary from recent git activity
/rubber-duck       — structured rubber duck debugging
/skill-scout       — find new skills to add to the-grid
/ponytail          — force the laziest solution that actually works
/handoff           — compact this conversation into a handoff doc
```

Full list: [SKILLS.md](SKILLS.md) (wired skills in detail, library repos as counts).
Don't remember the exact name? Ask Claude directly — "is there a skill for X?" — it
can see the wired set and will invoke the right one.

## Agents — orchestrators vs subagents

`agent-factory/` composes a 27-role dev team. Two different invocation shapes:

| Form | Roles | How to invoke |
|------|-------|----------------|
| **Skill** (orchestrator) | `ceo-orchestrator`, `tech-lead`, `growth-hacker`, `finance-manager` | Slash command — `/tech-lead`. Transforms the session into that role for the rest of the conversation. |
| **Subagent** (specialist) | the other 23 roles | Not a slash command. Either delegate explicitly — *"use the backend-dev subagent to implement this"* — or let an orchestrator hand off automatically once you've invoked it. |

Typical flow: `/ceo-orchestrator` to scope a business goal → it delegates to
`tech-lead` / `product-manager` / `growth-hacker` → those delegate further down to
specialists. You can also skip straight to a specialist subagent for a narrow task
without going through an orchestrator at all.

The finance desk (`finance-manager` → sentinel/analyst/strategist/risk-officer/scribe)
and `gh-triage` are standalone — not part of the CEO's chain, invoke them directly.

## automation-factory — recurring unattended work

For work that should run on a schedule or loop over a backlog without a human
driving each turn (e.g. clearing a repo's GitHub issues), cut a pattern into the
target repo instead of running it ad hoc in a session — copy the pattern into a
tracked `loop/` folder, fill its placeholders, then `bash loop/setup.sh` to wire
the machine-specific bits (absolute paths, the `.claude/settings.json` hook).
Full steps: [automation-factory/patterns/issue-loop/README.md](automation-factory/patterns/issue-loop/README.md).
(`instantiate.sh`, tracked as issue #15, will collapse this to one command.)

## project-factory — starting a brand-new project

```bash
bash ~/.the-grid/project-factory/scripts/cut-project.sh <template> <target-dir>
```

Seeds an empty `target-dir` or retrofits a non-empty one — same script either way,
never overwrites a file that already differs from the template. Available
templates and what each assumes: [project-factory/README.md](project-factory/README.md).
Composing an agent-factory persona, wiring skills, or adding an automation-factory
pattern into the new project all happen *after* the cut, as normal steps in that
repo.

## Growing what's wired

- **Found a useful skill in the library (or on the internet)?** Run `/skill-scout`
  to search and propose additions, or add the repo/skill name to
  `baseline-submodules.txt` (every machine) or `machines/<host>.txt` (this machine
  only) and re-run `bash scripts/wire.sh`.
- **Adding a whole new sibling repo?** `git submodule add <url> repos/<name>` — it
  lands as library-only until you promote it into one of the manifests above.
- **Writing an original skill?** Create `skills/<name>/SKILL.md` at the repo root
  (frontmatter needs `name:` + `description:`), then `bash scripts/wire.sh`.

## Keeping it healthy

```bash
bash scripts/check-grid.sh      # fast health check — bats suite + broken-symlink scan
tests/lib/bats-core/bin/bats tests/   # full test suite directly
```

A `pre-commit` hook runs the same tests automatically before every commit in this
repo (bypass with `git commit --no-verify` or `GRID_SKIP_HOOK=1`).

## Where to look next

- [SKILLS.md](SKILLS.md) — generated index of every wired + library skill.
- [TODO.md](TODO.md) — open issues (GitHub Issues is the source of truth) + done history.
- [LEARNINGS.md](LEARNINGS.md) — durable lessons mined from project history.
- [CLAUDE.md](CLAUDE.md) — full technical context, for Claude sessions and for you.
