# Specs — how this project plans work

This project uses **OpenSpec**. Specs are the durable artefact; chat sessions
are not. Anything an agent plans in a session that isn't written to `openspec/`
is lost the moment the context window rolls.

**Read this before proposing, planning, or implementing a change.**

- Home: <https://openspec.dev>
- Source: <https://github.com/Fission-AI/openspec> (MIT)
- CLI: `npm install -g @fission-ai/openspec@latest` (needs Node >= 20.19.0)

## Why this file exists

`project-factory` lays this file down on **every** project it cuts, seed or
retrofit, via `templates/_common/`. That's deliberate: the convention is the
default, not a per-project decision someone has to remember to make. If you're
reading this in a repo, the repo has opted in.

What it does *not* do is run `openspec init` for you. `_common` only ever copies
files; the CLI owns the directory it creates. See "Adopting" below.

## Layout

```
openspec/
  specs/<capability>/spec.md     current truth — what the system does today
  changes/<change-id>/
    proposal.md                  what & why
    design.md                    how
    tasks.md                     implementation checklist
    specs/<capability>/spec.md   the DELTA — how the spec changes
  archive/                       completed changes
```

The distinction that matters: `openspec/specs/` is the present tense.
`openspec/changes/*/specs/` is a diff against it. Never edit the former directly
as part of a change — write the delta and let `archive` fold it in.

## Workflow

| Step | Command | What it does |
|---|---|---|
| 1 | `/openspec-explore` | Think through options before committing to one |
| 2 | `/openspec-propose <idea>` | Create the change folder + all artefacts |
| 3 | *review* | **Human reads the proposal before any code is written** |
| 4 | `/openspec-apply-change` | Implement the tasks |
| 5 | `/openspec-verify-change` | Check the implementation against the spec |
| 6 | `/openspec-archive-change` | Fold the delta into `specs/`, move to `archive/` |

Also available: `/openspec-new-change`, `/openspec-continue-change`,
`/openspec-update-change`, `/openspec-ff-change`, `/openspec-sync-specs`,
`/openspec-bulk-archive-change`, `/openspec-onboard`.

Step 3 is the point of the whole thing. Proposals exist to be rejected cheaply,
before implementation cost is sunk.

## Spec format

Plain markdown, no custom syntax:

```markdown
## ADDED Requirements

### Requirement: Theme selection
The app SHALL let users switch between light and dark themes, defaulting to
the system preference.

#### Scenario: User toggles dark mode
- **WHEN** the user clicks the theme toggle
- **THEN** the app switches to dark mode and persists the choice
```

Section headers are `ADDED`, `MODIFIED`, or `REMOVED`. Requirements use SHALL.
Every requirement carries at least one WHEN/THEN scenario — a requirement with
no scenario is untestable and shouldn't be merged.

## Adopting

**Greenfield** (project just cut from `project-factory`):

```bash
openspec init          # creates openspec/ and registers slash commands
/openspec-onboard      # optional guided first cycle
```

**Brownfield** (existing codebase, no specs): the code is already the truth, so
don't try to back-fill a spec for all of it. Run `openspec init`, then write
specs *only* for the capability you're about to change, as part of the first
change that touches it. `openspec/specs/` grows to cover the codebase
incrementally, driven by real work. A big-bang spec-writing exercise produces
documentation nobody trusts and nothing verifies.

## For agents working in this repo

1. Before implementing anything non-trivial, check `openspec/changes/` for an
   existing change covering it. Continue it rather than starting a parallel one.
2. Check `openspec/specs/<capability>/spec.md` for what the system already
   promises. That's the contract — contradicting it is a spec change, not an
   implementation detail.
3. If asked to build something with no change folder, propose first
   (`/openspec-propose`) and stop for review. Do not skip to code.
4. When implementation reveals the spec was wrong, update the delta in the
   change folder. Silent divergence between spec and code is the failure mode
   this whole convention exists to prevent.
5. If the `openspec` CLI isn't installed, say so and stop — don't hand-roll the
   directory structure. The CLI owns that layout.

## Scope

This convention covers *what gets built and why*. It does not replace
`CONTEXT.md` (domain glossary, architecture decisions) or `LEARNINGS.md`
(gotchas found along the way). Specs say what the system must do; those two say
what you need to know to work on it.
