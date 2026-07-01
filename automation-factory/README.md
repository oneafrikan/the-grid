# automation-factory

The-grid's tier for **reusable automation patterns** — the orchestration layer of
the agent ecosystem, a sibling to [`agent-factory/`](../agent-factory/) (composes
agents) and `skills-factory/` (builds skills).

## The pattern → instance model

A tailor doesn't sew each suit from scratch — they cut from a **pattern**. This
folder holds the patterns. Each is a generic, version-controlled template you
*instantiate* into a target repo to make a working automation. The template is
what the-grid owns; the instance lives in the project it serves.

This is the distinction from `skills/`: a skill is **wired** (symlinked) live into
`~/.claude/skills/`. An automation pattern is **instantiated** (cut + filled) into
a target repo's top-level, tracked `loop/` folder — not `.claude/`, which is
commonly gitignored by Claude Code convention and wouldn't survive a clone or
repo move. Only the genuinely machine-specific wiring (an absolute hook path
baked into `.claude/settings.json`) lives under `.claude/`, and it's regenerated
on demand rather than committed. Different deployment, same idea — the-grid is
the hub where the reusable asset is managed.

## Patterns

| Pattern | What it does |
|---------|--------------|
| [`issue-loop`](patterns/issue-loop/) | Autonomous agent that works a repo's GitHub issue backlog unattended, with an auto code-review posted to each issue. Composes a `/loop` prompt (Module 2) with a post-commit review hook (Module 1). |

## Anatomy of a pattern

```
patterns/<name>/
  README.md                  # what it is, how it composes, how to instantiate, why-each-decision
  loop-prompt.template.md    # the agent-facing prompt(s), with {{PLACEHOLDERS}}
  hooks/*.sh                 # any Claude Code hooks the pattern needs
  setup.sh                   # regenerates machine-specific wiring in a target repo (idempotent)
  .gitignore                 # excludes the generated, path-baked prompt instance
```

Patterns use `{{PLACEHOLDERS}}` for everything project-specific (repo, working dir,
project context, verify command, labels) so one cut serves many suits. Before
adding a new pattern module, check whether its destination directory is
gitignored in target repos (`git check-ignore -v <path>`) — see
`patterns/issue-loop/README.md` for the reasoning and the tracked-`loop/`-folder
convention this led to.

## Roadmap

- **`instantiate.sh`** ([issue #15](https://github.com/oneafrikan/the-grid/issues/15),
  `scripts/instantiate.sh`) — machine-profiled (personal / work / mac-mini) cut of
  a pattern into a target repo: copy into `loop/` + placeholder-fill + settings
  wiring, plus a guard hook + worktree/PR sandboxing (work), and launchd vs cloud
  scheduling. Ships today for `issue-loop`.
- **`AUTOMATIONS.md`** — a generated index of patterns, parallel to `SKILLS.md`.
- **More patterns** — issue-loop is the first. Scheduled jobs, watch-and-react
  hooks, release automations, and agent-team orchestrations follow.

See each pattern's own `README.md` for instantiation steps and design rationale.
