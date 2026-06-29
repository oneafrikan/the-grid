# gh-triage — Design Spec

Autonomous GitHub issue triage agent. Classifies every open issue across the
Jarvis and Guide repo sets, applies the mattpocock label schema + severity tiers,
and writes agent briefs or triage notes as structured comments. No human
intervention required for classification; machine-doable items are marked
`ready-for-agent` so Phase 2 CC loops can act on them autonomously.

---

## What it does (Phase 1 — passive classifier)

1. Polls GitHub for unlabeled or `needs-triage` issues across all repos in scope.
2. Polls the `guide-backlog` Slack channel (`C0B588EN59U`) for new messages;
   creates GH issues from actionable ones (LLM-filtered); ignores chat.
3. For each issue: classifies severity + state role using LLM judgment with
   repo→live-system context injected into the prompt.
4. Applies labels and posts a structured comment (agent brief or triage notes).
5. Does NOT initiate CC loops. That is Phase 2.

---

## Runtime

| Concern | Decision |
|---|---|
| Agent | Main Jarvis agent (OpenClaw, Scout) |
| Jarvis repos | Cron every 60 minutes |
| Guide repos | Cron every 30 minutes |
| Slack → GH | Same cron, runs before GH triage pass |

---

## Repos in scope

### oneafrikan (Scout / Jarvis stack)

| Repo | Live system | Default severity ceiling |
|---|---|---|
| `jarvis-core` | Scout OpenClaw runtime + all Jarvis containers | critical |
| `jarvis-workspace` | Main Jarvis agent identity/memory | high |
| `paperclip` | Governance/scheduler on Scout | high |
| `jarvis-skill-factory` | Overnight skill loop | medium |
| `jarvis-agent-factory` | Overnight agent loop | medium |
| `the-grid` | Claude Code skill wiring | medium |

### gkwilderness (Guide server stack)

| Repo | Live system | Default severity ceiling |
|---|---|---|
| `guide-compose` | Guide server Docker stack | critical |
| `guide-core` | Guide server ops config (sessions, signals, prompts) | high |
| `guide-workspace` | Guide main agent identity/memory | high |
| `guide-paperclip` | Guide Paperclip scheduler | high |
| `guide-skill-factory` | Guide skill loop | medium |
| `guide-prompt-factory` | Guide prompt versioning | medium |

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

- Channel: `guide-backlog` (`C0B588EN59U`)
- Agent polls for new messages since last run
- LLM filters each message: is this a bug report, feature request, or operational
  problem? If yes → create GH issue in the appropriate `gkwilderness` repo with
  the original Slack message verbatim in the body + channel reference
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
| Main Jarvis agent, not dedicated | The main agent is the orchestrator. No new agent identity needed for a cron job. |
| OpenClaw cron, not GitHub Actions | No new Docker containers. No YAML in every repo. OpenClaw is already running. |
| mattpocock label schema | Proven schema. `ready-for-agent` is exactly the CC loop pickup signal we need. |
| Agent brief format (mattpocock) | Behavioral spec over procedural steps. Durable against codebase churn. |
| No Slack output | Solo operator. Slack-as-notification is noise with no audience. |
| LLM judgment for severity | Keyword matching is too brittle across diverse repos. Context-aware LLM call with live-system prompt injection is more reliable. |
| critical/high always → ready-for-human | Worktree isolation is safe for low/med. High severity blast radius is not a machine call. |
