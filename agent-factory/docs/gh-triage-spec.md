# gh-triage — Design Spec

Scheduled GitHub issue triage agent. Classifies every open issue in the repo set
its **deployment scope** defines, applies the mattpocock label schema + severity
tiers, and writes agent briefs or triage notes as structured comments. No human
intervention required for classification; machine-doable items are marked
`ready-for-agent` so Phase 2 CC loops can act on them autonomously. An optional,
off-by-default knowledge sweep also commits to a configured sweep branch (see
"Knowledge sweep").

The composed agent is **deployment-agnostic** — it describes HOW to triage. WHAT
to triage (org, repos, repo→live-system map, Slack on/off) is injected per machine.
See "Deployment scope" below.

---

## What it does (Phase 1 — passive issue classifier)

This list is the issue pass: it only labels and comments. The knowledge sweep
(next section) is separate and, when enabled, also commits.

1. Reads its deployment scope file (Step 0) to learn org, repos, and Slack config.
2. Polls GitHub for unlabeled or `needs-triage` issues across the repos in scope.
3. If its scope enables Slack: reads new channel messages from the file named in the scope;
   creates GH issues from actionable ones (LLM-filtered); ignores chat.
4. For each issue: classifies severity + state role using LLM judgment with
   repo→live-system context (from the scope file) injected into the prompt.
5. Applies labels and posts a structured comment (agent brief or triage notes).
6. Does NOT initiate CC loops. That is Phase 2.

---

## Knowledge sweep

Optional second pass (SKILL.md Step 6), run after the issue pass. Not yet run live
on a real repo.

### What it does
- Reads pending signals in a repo's `signals/` directory and runs the repo's own
  `scripts/knowledge.py`, which holds every mechanical rule (grammar, stage ceiling,
  ledger, secret scan, safety guards).
- Makes the judgement calls the script asks for: does a claim conflict with a
  guardrail, does it contradict a canon claim.
- Routes each signal one of two ways:
  - Clean signal → written as a `knowledge/` entry below canon.
  - Escalated signal (claims canonical, supersedes or contradicts an entry, matches
    canon, collides on an id, or fails a guardrail or canon judgement) → an issue plus a
    PR proposing the change, for a human. A signal that trips the secret scan gets an
    issue only, naming the file and pattern, never the text.
- Commits and pushes the result to the configured sweep branch: `signals/done/`,
  `signals/done/ledger.jsonl` and `knowledge/` below canon, nothing else.

### Ledger
- `signals/done/ledger.jsonl` records every processed signal.
- The ledger is how the sweep avoids reprocessing a signal and how it reconciles
  earlier escalations (PR merged → `accepted`, closed unmerged or `wontfix` → `rejected`).

### Labels
Escalation issues carry `knowledge`, `ready-for-human` and a severity of
`severity:low`, or `severity:medium` for a contradiction, guardrail conflict or secret.
No category label. Each issue body holds a `knowledge-signal: <claim_hash>` marker so a
re-run finds the existing issue (closed ones included) instead of filing a duplicate.

### Caps
- 10 signals per run per repo, set by `Cap` in the scope file's `## Knowledge sweep` table
  (blank = 10). Signals over the cap stay pending, oldest first.
- 3 escalations per run per repo. The oldest 3 are escalated; the rest stay pending.

### Defaults and safety
- Default off: the scope file's `## Knowledge sweep` section ships with `enabled: false`,
  and only repos listed in its table are swept. With it off, the run behaves exactly as
  the issue pass alone.
- First run writes nothing: with no earlier `knowledge-sweep` run-record line for the
  repo, the sweep runs `plan` only and records `skipped`. A `skipped` line counts as the
  earlier line for the next run.
- The agent never merges (no `gh pr merge`, no auto-merge), never closes an issue or PR,
  and never writes canon (`knowledge/canon/`, `PURPOSE.md`, `GUARDRAILS.md`,
  `BEHAVIOUR.md`, `MAP.md`). A human merges canon proposals.
- One run-record line per repo per run, even when nothing changed.

---

## Runtime

| Concern | Decision |
|---|---|
| Agent | One generic composed agent, wired identically on every machine |
| Scope source | A per-machine deployment scope file the cron prompt points at |
| Cron schedule | A property of each machine's cron registration, not the agent |
| Slack → GH | Same cron, runs before GH triage pass — only if scope enables Slack |

---

## Deployment scope (generic / specific split)

The generic agent carries no org/repo/Slack/cron specifics. Each machine that runs
it provides one filled-in scope file in **its own infra repo** (never in the-grid,
which is shared across machines). The contract template is
`roles/gh-triage/deployment-scope.template.md`; the agent reads the scope in Step 0
of its SKILL.md.

Each install keeps its own deployment table (org, scope file path, Slack on/off)
in its own infra repo.

Each scope file lists its repos with a live-system description + default severity
ceiling (e.g. a repo that backs a production runtime gets ceiling critical). The
agent injects the matching row into the classification prompt.

---

## Label schema

Adopts the mattpocock triage schema verbatim, adding severity tiers on top.

### Category (one per issue)
- `bug` — something is broken
- `enhancement` — new feature or improvement

### State (one per issue)
- `needs-triage` — not yet evaluated
- `needs-info` — waiting on reporter
- `ready-for-agent` — fully specified, machine-doable
- `ready-for-human` — needs human judgment or architectural decision
- `wontfix` — will not be actioned

### Severity (one per issue)
- `severity:critical` — live system down or data at risk
- `severity:high` — live system degraded, user-facing impact
- `severity:medium` — non-blocking but affects a live service
- `severity:low` — no live system impact (docs, tooling, nice-to-haves)

### Safety gate
`severity:critical` and `severity:high` issues are always assigned `ready-for-human`,
regardless of how bounded the fix looks. Low/medium severity issues can be
`ready-for-agent` if they are sufficiently specified.

---

## Output format

Every triaged issue gets:
1. Labels applied via `gh issue edit --add-label`
2. A structured comment posted via `gh issue comment`

### For `ready-for-agent` issues
Agent brief following the mattpocock AGENT-BRIEF.md template:
- Category + one-line summary
- Current behavior
- Desired behavior
- Key interfaces (behavioral, not file paths)
- Acceptance criteria (testable checkboxes)
- Out of scope

### For `needs-info` issues
Triage notes following the mattpocock template:
- What we've established so far
- Specific questions for the reporter

### For `ready-for-human` issues
Same agent brief structure but with a note explaining why human judgment is needed
(architectural decision, ambiguity, high severity, external access required).

All comments open with:
```
> *This was classified by the gh-triage agent.*
```

---

## Slack ingestion

Conditional — only runs when the deployment scope sets Slack `enabled: true`
(e.g. a deployment with a backlog channel; others leave it off).

- Channel: named in the scope file (name + id)
- Messages: read from the `messages-file` named in the scope (the agent has no Slack tool); new = newer than the timestamp in `last-run-file`
- LLM filters each message: is this a bug report, feature request, or operational
  problem? If yes → create GH issue in the repo named by the scope's
  `file-issues-in` rule, with the original Slack message verbatim in the body +
  channel reference
- Non-actionable chat is ignored silently
- No Slack output — agent never writes back to Slack

---

## Deduplication

- Before triaging, check if issue already has a state label. If yes, skip.
- On `issue_comment` trigger: re-evaluate only if current state is `needs-info`
  and the comment is from the original reporter (not the triage agent itself).
- Slack: track last-processed message timestamp in the scope's `last-run-file` to avoid reprocessing.

---

## Phase 2 (not in scope here)

Active orchestrator that picks up `ready-for-agent` issues, opens a git worktree,
and fires a CC loop to implement the fix. The worktree isolation is the safety
mechanism that permits autonomous action on low/medium severity issues.

---

## Design decisions

| Decision | Rationale |
|---|---|
| Passive issue classifier (Phase 1); knowledge sweep opt-in | Build the labelling foundation before autonomous action. CC loops need a stable `ready-for-agent` queue to pick from. The sweep is the one exception that commits, off by default and never merging or touching canon. |
| Host's main agent, not dedicated | Each machine's main OpenClaw agent is the orchestrator. No new agent identity needed for a cron job. |
| Generic agent + per-machine scope | One composed artifact wired everywhere; scope injected by a per-machine file. Avoids a second hardcoded deployment and keeps machines' scope cleanly separated. |
| OpenClaw cron, not GitHub Actions | No new Docker containers. No YAML in every repo. OpenClaw is already running. |
| mattpocock label schema | Proven schema. `ready-for-agent` is exactly the CC loop pickup signal we need. |
| Agent brief format (mattpocock) | Behavioral spec over procedural steps. Durable against codebase churn. |
| No Slack output | Solo operator. Slack-as-notification is noise with no audience. |
| LLM judgment for severity | Keyword matching is too brittle across diverse repos. Context-aware LLM call with live-system prompt injection is more reliable. |
| critical/high always → ready-for-human | Worktree isolation is safe for low/med. High severity blast radius is not a machine call. |
