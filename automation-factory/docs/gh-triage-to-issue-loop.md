# gh-triage → issue-loop: the full pipeline

How the Slack-to-merged-PR autonomous development loop works on guide-server.
This document is the starting point for wiring Phase 2 (the execution half).

---

## What exists today (Phase 1)

### Intake: real-time Slack → GitHub

A Slack message in `#guide-backlog` (C0B588EN59U) triggers the OpenClaw main agent
in real-time via the channel binding in `openclaw.json`. The agent:

1. Filters — is this actionable? If not, stops silently.
2. Routes to the correct `gkwilderness` repo.
3. Creates a GitHub issue with label `needs-triage`.
4. Confirms in-channel: `✅ Filed as gkwilderness/<repo>#<N> — triage agent will classify shortly.`

Instruction lives in: `/srv/openclaw/workspaces/main/AGENTS.md` — `## Channel: #guide-backlog` section.

### Classification: OpenClaw cron → Agent Briefs

An OpenClaw cron job (`gh-triage-guide`, runs every 30 minutes) sweeps six repos:

```
guide-compose | guide-core | guide-workspace | guide-paperclip | guide-skill-factory | guide-prompt-factory
```

For each repo it runs three queries:
- **A** — unlabeled issues (`--search "no:label"`)
- **B** — `needs-triage` issues (filed by the real-time agent)
- **C** — `needs-info` issues (re-evaluated if author replied)

**Hard skip rule:** any issue already carrying `ready-for-agent`, `ready-for-human`,
or `wontfix` is skipped entirely — not touched, not commented on.

For each issue that passes the skip rule:
1. Classifies: category (`bug`|`enhancement`), severity, state
2. **Safety gate:** `severity:critical` or `severity:high` → always `ready-for-human`
3. Applies labels (removes `needs-triage` if present)
4. Posts a structured comment — Agent Brief (for `ready-for-agent`/`ready-for-human`)
   or Triage Notes (for `needs-info`)

Cron job ID: `251b4ca3-561e-4eb8-853a-2cab5e0cae3b`
Prompt stored in: scratchpad (source of truth is the job payload in `jobs.json`)

### Label schema (mattpocock)

| Dimension | Values |
|-----------|--------|
| Category | `bug` · `enhancement` |
| Severity | `severity:critical` · `severity:high` · `severity:medium` · `severity:low` |
| State | `needs-triage` · `needs-info` · `ready-for-agent` · `ready-for-human` · `wontfix` |

### What Phase 1 produces

Every actionable `ready-for-agent` issue has:
- Three labels applied (category + severity + state)
- An **Agent Brief** comment with: Summary, Current behaviour, Desired behaviour,
  Key interfaces, Acceptance criteria, Out of scope

That Agent Brief is the contract for Phase 2 to consume.

---

## What doesn't exist yet (Phase 2)

Phase 2 is the execution half: pick up `ready-for-agent` issues, implement the fix,
open a PR, link it back to the issue.

### The execution pattern: `issue-loop`

`automation-factory/patterns/issue-loop/` already has the generic pattern:
- `loop-prompt.md` — the `/loop` prompt (Module 2)
- `hooks/post-commit-review.sh` — auto-review on every commit (Module 1)
- `settings.snippet.json` — how to wire the hook

The loop prompt picks the lowest-numbered `{{ISSUE_LABEL}}` issue, reads its body
(the Agent Brief), implements, verifies, commits `#N`, pushes, closes, repeats.
The post-commit hook fires `claude -p` to review the diff and posts the review to
the issue.

### Connecting Phase 1 to Phase 2

The join is a label. Phase 1 ends with `ready-for-agent`. Phase 2 starts by
querying for `ready-for-agent`. No other glue needed — the Agent Brief in the issue
body is the handoff.

The label to use in `{{ISSUE_LABEL}}`: **`ready-for-agent`**

### Per-repo instantiation

Each `gkwilderness` repo needs its own instantiated loop. The six repos have
different stacks, different verify commands, and different blast radii — they
should not share a single loop instance.

Suggested starting repo: **`guide-core`** — lowest blast radius, clearest
acceptance criteria, already has issue #3 (`ready-for-agent`).

To instantiate (manual until `instantiate.sh` exists):
1. Copy `patterns/issue-loop/hooks/post-commit-review.sh` into `<repo>/.claude/hooks/`
2. Fill `{{GH_REPO}}`, `{{PROJECT_CONTEXT}}`, `{{REVIEW_FOCUS}}`
3. Merge `settings.snippet.json` into `<repo>/.claude/settings.json` (fill `{{WORKING_DIR}}`)
4. In Claude Code at `<repo>`, run `/loop` with `loop-prompt.md` filled:
   - `{{GH_REPO}}` → `gkwilderness/<repo>`
   - `{{WORKING_DIR}}` → `/srv/<working-dir>`
   - `{{PROJECT_CONTEXT}}` → one line about the repo
   - `{{VERIFY_CMD}}` → test/lint command, or blank
   - `{{ISSUE_LABEL}}` → `ready-for-agent`

### What changes when refactoring existing loops

If there are already Claude Code loops running against these repos, the refactor is:
- Replace the issue-selection logic with `gh issue list --label ready-for-agent`
- Replace inline classification with "read the Agent Brief already in the issue body"
- Add the `post-commit-review` hook if not already present
- Add label transitions: remove `ready-for-agent`, add `ready-for-human` after PR is open

The loop should **not** classify — that's Phase 1's job. It reads the Agent Brief
and implements against the acceptance criteria. Keep the roles separate.

---

## Infrastructure notes for Phase 2

### `gh` authentication (guide-server)

Agent tool subprocesses in OpenClaw do NOT inherit container env vars (including
`GITHUB_TOKEN`). Credentials are stored on disk at:

```
/srv/openclaw/home/.config/gh/hosts.yml
```

Claude Code sessions running on guide-server (not inside OpenClaw) use the normal
system `gh` — check `gh auth status` before assuming.

### Worktree / branch strategy

For autonomous commits to `main`, use the existing issue-loop pattern as-is.
For a safer PR-based flow (recommended for `guide-core` and above):
- Create a branch per issue: `fix/issue-<N>`
- Open a PR with `gh pr create`
- Let the post-commit-review hook fire on the PR diff
- Label the issue `ready-for-human` and link the PR

The issue-loop README flags this as the "PR mode" roadmap item — it's not in the
pattern yet but is the right target for production guide repos.

### Repo severity ceilings

From the triage cron context — these bound Phase 2's autonomy:

| Repo | Ceiling | Implication |
|------|---------|-------------|
| `guide-compose` | critical | All issues `ready-for-human` — loop never runs here |
| `guide-core` | high | High = human; medium/low = agent-doable |
| `guide-workspace` | high | Same |
| `guide-paperclip` | high | Same |
| `guide-skill-factory` | medium | Medium/low = agent-doable |
| `guide-prompt-factory` | medium | Same |

---

## The full roundtrip (when Phase 2 is wired)

```
Slack #guide-backlog
  ↓  real-time binding (AGENTS.md)
GitHub issue created (needs-triage)
  ↓  cron every 30 min
Classified + Agent Brief posted (ready-for-agent)
  ↓  issue-loop /loop
Implemented, verified, PR opened
  ↓  post-commit-review hook
Review posted to PR
  ↓  (human or auto-merge)
Merged → issue closed
```

Human only touches it at the PR review step — and only if they want to.

---

## Key files

| File | What it is |
|------|-----------|
| `/srv/openclaw/workspaces/main/AGENTS.md` | Real-time Slack→GH handler (guide-backlog section) |
| `/srv/openclaw/cron/jobs.json` | Cron job registry (gh-triage-guide entry) |
| `automation-factory/patterns/issue-loop/` | The execution pattern to instantiate |
| `agent-factory/examples/gh-triage.yaml` | gh-triage compose source |
| `agent-factory/projects/gh-triage/_claude-code/agents/full-team-gh-triage.md` | CC subagent |
| `LOGS/2026-06-29-guide-server-gh-triage-wiring-context.md` | Full session context with all decisions |
