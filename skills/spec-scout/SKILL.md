---
name: spec-scout
description: >
  Audit a repo's OpenSpec adoption and report drift between openspec/specs/ and
  what the code actually does — missing specs, stale in-flight changes, specs
  that no longer match shipped behaviour. Use when the user says "spec-scout",
  "audit specs", "are our specs current", "check spec drift", "which repos have
  specs", or invokes /spec-scout.
---

# spec-scout

The `skill-scout` shape, pointed at specs instead of skills: **survey and
propose, never act.** Reports adoption status and drift; does not run
`openspec init`, does not write specs, does not edit `openspec/`. The user
decides what to fix — and fixes go through the normal
`/openspec-propose` → review → `/openspec-apply-change` flow, not through this
skill.

Convention reference: `project-factory/templates/_common/SPECS.md`.
Requires the `openspec` CLI only for the optional validation step (step 4);
everything else is filesystem reads and git.

## Scope

Default target is the current repo. If the user names a directory of repos
(e.g. `~/code`), scan each immediate subdirectory that is a git repo and report
a summary table first, then detail only the ones with findings.

## How to run

### 1. Classify adoption

For each target repo, check for `openspec/`:

| State | Signal |
|---|---|
| **none** | No `openspec/` directory |
| **initialised** | `openspec/` exists, `specs/` empty or absent |
| **active** | `openspec/specs/*/spec.md` exists |

For **none**, say so in one line and stop there for that repo — a repo with no
specs has no drift to report, only a decision to make. Don't lecture.

### 2. Inventory

For an **active** repo, list:

- Capabilities: each `openspec/specs/<capability>/spec.md`.
- In-flight changes: each `openspec/changes/<id>/` (excluding `archive/`).
- Archived changes: count from `openspec/archive/`.

### 3. Drift signals

Check each, cheapest first. Report only what you actually find — an empty
finding list is a good result, and saying "no drift found" is a complete answer.

- **Stale in-flight change** — `openspec/changes/<id>/tasks.md` has all boxes
  ticked but the change was never archived. Use `git log -1 --format=%ar` on the
  change directory for age. Anything ticked-and-unarchived for weeks is either
  finished-and-forgotten or abandoned; both need a human call.
- **Abandoned change** — a change folder with no commits for a long stretch and
  unticked tasks. Report the age and the last commit subject; don't guess which
  it is.
- **Requirement with no scenario** — a `### Requirement:` heading with no
  `#### Scenario:` under it. Untestable by construction — flag every instance.
- **Spec with no code** — the capability name (and the nouns in its
  requirements) appear nowhere in the source tree. Weak signal on its own:
  naming rarely matches one-to-one, so report it as a question, not a verdict.
- **Code with no spec** — a top-level source module or route group with no
  capability covering it. Expect a lot of these in a brownfield repo; that is
  the normal, intended state (`SPECS.md` says specs grow per-change). Only flag
  it for areas that changed recently — `git log --since` on the paths — because
  a *changing* area with no spec is the case actually worth raising.
- **Spec contradicted by code** — the most valuable finding and the most
  expensive. Only attempt it for capabilities the user names, or for specs whose
  files changed less recently than the code they describe. Read the requirement,
  read the implementation, and report the contradiction with both locations.
  If you can't verify it, say so rather than asserting drift.

### 4. Validate (optional)

If the `openspec` CLI is installed, run its own validation and fold the output
in:

```bash
openspec validate 2>&1 || true
```

If the CLI is missing, note it and skip — do not install it, and do not
hand-roll the check.

### 5. Report

```
## <repo> — <state>

Capabilities: N   In-flight: N   Archived: N

| Finding | Where | Evidence | Suggested next step |
|---|---|---|---|
```

Rules for the report:

- Every finding cites a file path, and a line number where one applies.
- "Evidence" is what you observed, not what you infer from it.
- Rank by cost of being wrong: contradicted specs first, then stale changes,
  then coverage gaps.
- Separate **confirmed** (you read both sides) from **suspected** (heuristic
  match only). Never present a heuristic hit as a confirmed contradiction.
- End with the exact commands the user would run, but **do not run them**:

```bash
openspec init                    # adopt (state: none)
/openspec-propose <change>       # fix drift the normal way
/openspec-archive-change         # close out a finished change
```

## Notes

- Absence of a spec is not automatically a defect. `SPECS.md` prescribes
  incremental adoption, so a brownfield repo with three specs and forty modules
  is following the convention correctly, not failing it. Report coverage as a
  fact; only call it a gap where the code is actively changing.
- Never edit `openspec/specs/` to "fix" drift. Deltas go in a change folder —
  editing current-truth specs directly is exactly the failure mode the
  convention prevents.
- Keep the report short enough to read in one screen per repo. Detail belongs
  behind the file paths.
