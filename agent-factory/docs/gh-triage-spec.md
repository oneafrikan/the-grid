# gh-triage — Design Spec

Autonomous GitHub issue triage agent. Classifies every open issue in the repo set
its **deployment scope** defines, applies the mattpocock label schema + severity
tiers, and writes agent briefs or triage notes as structured comments. No human
intervention required for classification; machine-doable items are marked
`ready-for-agent` so Phase 2 CC loops can act on them autonomously.

The composed agent is **deployment-agnostic** — it describes HOW to triage. WHAT
to triage (org, repos, repo→live-system map, Slack on/off) is injected per machine.
See "Deployment scope" below.

---

## What it does (Phase 1 — passive classifier)

1. Reads its deployment scope file (Step 0) to learn org, repos, and Slack config.
2. Polls GitHub for unlabeled or `needs-triage` issues across the repos in scope.
3. If its scope enables Slack: polls the configured channel for new messages;
   creates GH issues from actionable ones (LLM-filtered); ignores chat.
4. For each issue: classifies severity + state role using LLM judgment with
   repo→live-system context (from the scope file) injected into the prompt.
5. Applies labels and posts a structured comment (agent brief or triage notes).
6. Does NOT initiate CC loops. That is Phase 2.

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

| Deployment | Org | Scope file | Slack |
|---|---|---|---|
| Scout (Jarvis) | `oneafrikan` | `jarvis-core/config/gh-triage-scope.md` | off |
| guide-server | `gkwilderness` | owned by guide-core | `#guide-backlog` |

Each scope file lists its repos with a live-system description + default severity
ceiling (e.g. for Scout: `jarvis-core` → Scout OpenClaw runtime, ceiling critical;
for guide-server: `guide-compose` → Guide Docker stack, ceiling critical). The
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
(e.g. guide-server's `#guide-backlog`; Scout has it off).

- Channel: named in the scope file (name + id)
- Agent polls for new messages since last run
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
- Slack: track last-processed message timestamp per channel to avoid reprocessing.

---

## Phase 2 (not in scope here)

Active orchestrator that picks up `ready-for-agent` issues, opens a git worktree,
and fires a CC loop to implement the fix. The worktree isolation is the safety
mechanism that permits autonomous action on low/medium severity issues.

---

## Design decisions

| Decision | Rationale |
|---|---|
| Passive classifier only (Phase 1) | Build the labelling foundation before autonomous action. CC loops need a stable `ready-for-agent` queue to pick from. |
| Host's main agent, not dedicated | Each machine's main OpenClaw agent is the orchestrator. No new agent identity needed for a cron job. |
| Generic agent + per-machine scope | One composed artifact wired everywhere; scope injected by a per-machine file. Avoids a second hardcoded deployment and keeps machines' scope cleanly separated. |
| OpenClaw cron, not GitHub Actions | No new Docker containers. No YAML in every repo. OpenClaw is already running. |
| mattpocock label schema | Proven schema. `ready-for-agent` is exactly the CC loop pickup signal we need. |
| Agent brief format (mattpocock) | Behavioral spec over procedural steps. Durable against codebase churn. |
| No Slack output | Solo operator. Slack-as-notification is noise with no audience. |
| LLM judgment for severity | Keyword matching is too brittle across diverse repos. Context-aware LLM call with live-system prompt injection is more reliable. |
| critical/high always → ready-for-human | Worktree isolation is safe for low/med. High severity blast radius is not a machine call. |
