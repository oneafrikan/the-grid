# Skill: gh-triage

Autonomous GitHub issue triage for the repo set your deployment scope defines.
Runs on cron. Classifies severity, applies labels, writes agent briefs or
triage notes. Does not implement fixes.

This skill describes **how** to triage. **What** to triage — the GitHub org, the
repos, the repo→live-system map, and whether Slack ingestion is on — is not baked
in here. It is injected per machine via a deployment scope file (Step 0).

---

## Step 0 — Load your deployment scope

You have NO built-in knowledge of which org or repos to triage. Your invocation
names a deployment scope file (an absolute path). Read it first — it is the single
source of truth for this machine and defines:

- **`org`** — the GitHub owner/org (e.g. the value used in `--repo <org>/<repo>`).
- **Repos in scope** — the exact repo list. Triage ONLY these. Never infer or
  reach for repos not listed.
- **Repo → live-system map** — for each repo: the live system it backs, a default
  severity ceiling, and notes. This is the context you inject into the
  classification prompt (Step 3). Always know which live system a repo backs
  before classifying it.
- **Slack ingestion** — whether it is enabled, and if so the channel name + id and
  the rule for which repo a new issue is filed in. If the scope does not enable
  Slack, skip Step 1 entirely.

Expected scope-file shape (the deployment fills in the values):

```markdown
org: <github-owner>

## Repos in scope
| Repo | Live system | Severity ceiling | Notes |
|---|---|---|---|
| <repo> | <what it backs> | critical/high/medium/low | <notes> |

## Slack ingestion
enabled: true | false
channel: <#name> (<CHANNEL_ID>)        # only if enabled
file-issues-in: <rule for target repo> # only if enabled
```

If no scope file is provided, or it is empty/unreadable: STOP. Report the missing
scope and do nothing else. Do not guess an org or repo list.

The cron schedule (how often you run) is a property of the cron registration on
the machine, not of this skill — you do not need to know it.

---

## Step 1 — Slack ingestion (only if your scope enables it)

Skip this step entirely unless Step 0's scope sets Slack ingestion `enabled: true`.

When enabled, before the GitHub triage pass, poll the channel named in your scope
for new messages since the last run timestamp.

For each new message:
1. Pass the message text to the LLM with prompt: "Is this a bug report, feature
   request, or operational problem that should be tracked as a GitHub issue? Answer
   yes/no with one-line reason."
2. If yes: create a GH issue in the repo named by your scope's `file-issues-in`
   rule. Body must include the original Slack message verbatim and a
   `> Source: Slack <channel>` footer.
3. If no: skip silently.
4. Update last-processed timestamp.

Do NOT write back to Slack under any circumstances.

---

## Step 2 — Find issues needing triage

```bash
# Unlabeled issues (never triaged)
gh issue list --repo <org>/<repo> --state open --no-labels --json number,title,body,createdAt

# Issues waiting to be re-evaluated after reporter replied
gh issue list --repo <org>/<repo> --state open --label needs-info --json number,title,body,comments
```

Skip any issue that already has a state label (`needs-triage`, `ready-for-agent`,
`ready-for-human`, `wontfix`) unless it is `needs-info` and has new reporter activity.

---

## Step 3 — Classify each issue

For each issue, call the LLM with this context:

```
Repo: <repo-name>
Live system: <description from repo→live-system map>
Issue title: <title>
Issue body: <body>
[Comments if re-evaluating needs-info]

Classify this issue:
1. Category: bug | enhancement
2. Severity: critical | high | medium | low
   - critical: live system down or data at risk
   - high: live system degraded, user-facing impact
   - medium: non-blocking but affects a live service
   - low: no live system impact (docs, tooling, nice-to-haves)
3. State:
   - ready-for-agent: bounded scope, sufficient context, low/medium severity only
   - ready-for-human: high/critical severity, requires judgment, ambiguous, or under-specified
   - needs-info: insufficient context to act, specific questions can be asked
   - wontfix: out of scope or will not be actioned
4. Rationale: one sentence explaining severity and state choice.
5. If ready-for-agent: write a complete agent brief (see template).
6. If needs-info: write specific triage questions (see template).
7. If ready-for-human: write agent brief noting why human judgment is required.

Safety gate: critical or high severity MUST be ready-for-human regardless of scope.
```

---

## Step 4 — Apply labels

```bash
gh issue edit <number> --repo <org>/<repo> \
  --add-label "bug,severity:medium,ready-for-agent"
```

Apply exactly one category label, one severity label, one state label.
Remove `needs-triage` if present (it is superseded by the assigned state).

---

## Step 5 — Post comment

```bash
gh issue comment <number> --repo <org>/<repo> --body "$(cat <<'EOF'
> *This was classified by the gh-triage agent.*

<structured comment from Step 3>
EOF
)"
```

### Agent brief template (ready-for-agent / ready-for-human)

```markdown
> *This was classified by the gh-triage agent.*

## Agent Brief

**Category:** bug / enhancement
**Severity:** critical / high / medium / low
**Summary:** one-line description of what needs to happen

**Current behavior:**
What happens now.

**Desired behavior:**
What should happen after the work is complete. Specific about edge cases.

**Key interfaces:**
- `TypeName` or `functionName()` — what needs to change and why
- Config shape — any new options needed

**Acceptance criteria:**
- [ ] Specific, testable criterion
- [ ] Specific, testable criterion

**Out of scope:**
- Things that should NOT be changed in this issue

**Why ready-for-human:** (include only if ready-for-human)
One sentence — architectural decision required / severity:high / ambiguous scope / etc.
```

### Triage notes template (needs-info)

```markdown
> *This was classified by the gh-triage agent.*

## Triage Notes

**Severity (provisional):** medium
**What we've established so far:**
- point 1
- point 2

**What we still need from you (@reporter):**
- Specific question 1
- Specific question 2
```

---

## Deduplication rules

- **Skip** any issue with an existing state label (unless `needs-info` + new reporter activity).
- **Skip** Slack messages already processed (track by timestamp, not message content).
- **Never** post a second triage comment if one already exists from this agent.
- On `issue_comment` trigger: check if commenter is the original reporter (not the
  triage agent) before re-evaluating.

---

## Error handling

- If the LLM response is malformed or missing required fields: apply `needs-triage`
  label only, post no comment, log the failure.
- If `gh` CLI returns an error: log it, skip the issue, continue the run.
- Never abort the full run because a single issue fails.
