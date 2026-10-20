# automation-factory

The-grid's tier for **reusable automation patterns** — the orchestration layer of
the agent ecosystem, a sibling to [`agent-factory/`](../agent-factory/) (composes
agents).

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
| [`issue-loop`](patterns/issue-loop/) | Agent that works a repo's labelled GitHub issues and hands a verified PR to a human (it never merges). A headless runner (`run-issue.sh`: one issue per run, capped worker, the runner runs the verify command itself, then pushes and opens the PR to a configurable base branch, run record), an interactive `/loop` prompt and a post-commit review hook. Started by hand; the operator decides when to schedule it. |

## Anatomy of a pattern

```
patterns/<name>/
  README.md                  # what it is, how it composes, how to instantiate, why-each-decision
  loop-prompt.template.md    # the agent-facing prompt(s), with {{PLACEHOLDERS}}
  hooks/*.sh                 # any Claude Code hooks the pattern needs
  run-*.sh, *.conf.template   # a headless runner and its tracked config template, when the pattern has one
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

- **`instantiate.sh`** (`scripts/instantiate.sh`, shipped for `issue-loop`; [issue #15](https://github.com/oneafrikan/the-grid/issues/15)) — profiled (personal / work / mac-mini) cut of
  a pattern into a target repo: verbatim copy into a tracked `loop/`, a `loop.conf` rendered
  once, the headless runner, guard hook and worktree helper for the PR-only profiles, and the
  opt-in labels. It writes no scheduler file and no hook entry in `.claude/settings.json`.
  Planned: a waker (a cron line the operator installs) and backoff / stale-lock handling.
- **`AUTOMATIONS.md`** — a generated index of patterns, parallel to `SKILLS.md`.
- **More patterns** — issue-loop is the first. Scheduled jobs, watch-and-react
  hooks, release automations, and agent-team orchestrations follow.

See each pattern's own `README.md` for instantiation steps and design rationale.

How the issue-loop connects to triage: [gh-triage to issue-loop](docs/gh-triage-to-issue-loop.md).
