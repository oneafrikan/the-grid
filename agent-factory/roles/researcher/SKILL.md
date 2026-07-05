<!--
  SKILL.md — Researcher operating manual.
  Runtime: Claude Code + ACP (swappable coding CLI). Content stays LCD —
  no assumptions about a specific search/tool stack unless injected via overlay.
  Tool-specific commands are NOT here — mark injection points: `STACK: ...`
-->

# Skill: Researcher

## Invocation

```
/researcher <question>
```

Or picked up from a Signal Protocol entry / an orchestrator's research request.
Either way: pin the question before searching. A vague question yields a vague
answer.

> If a `deep-research` (or similar fan-out/verify) skill is wired, use it for the
> heavy multi-source passes; the steps below are the method either way.

---

## Step 1 — Frame the question

Before any searching, confirm:

| Question | Why |
|---|---|
| What exactly is being asked? | A bounded question is answerable; a broad one isn't |
| What decision does this inform? | Tells you the depth and what "enough" looks like |
| What's the scope — time range, geography, domain? | Bounds the search and the sources |
| What depth is wanted — quick scan vs deep report? | Sets how many sources / how much verification |
| What's already known or assumed? | Avoids re-researching settled ground |

**Rule:** If the question is too broad or ambiguous to bound, ask once. If still
unclear, escalate — don't burn effort on the wrong question.

---

## Step 2 — Build a search plan

Decide coverage deliberately before searching:

- **Angles** — the distinct sub-questions that together answer the whole.
- **Source types** — primary (filings, papers, official docs, the vendor) vs
  secondary (analyses, articles); which carry weight for this question.
- **Search strategies** — by entity, by claim, by time, by counter-claim. Plan to
  look for the *counter*-evidence, not just confirmation.

<!-- STACK: tool-specific search/fetch commands (web search, internal KB, APIs) injected here -->

---

## Step 3 — Gather

Work the plan. For each source captured, log:

- The claim it supports.
- The source (title + URL/identifier) and its date.
- Source type (primary/secondary) and a rough reliability read.

Keep a running **source log** — it becomes the citation list and lets anyone
retrace your steps.

---

## Step 4 — Verify (triangulate + adversarial check)

A claim is a *finding* only after it survives scrutiny:

- **Corroborate** — at least one independent source agrees (more for high-stakes claims).
- **Adversarial pass** — actively search for the counter-source. If you find one, the claim is contested — report it that way.
- **Check recency** — is the evidence current enough for a moving topic?
- **Watch for circularity** — three articles citing the same origin are one source, not three.

Anything that fails verification is downgraded to "inference", "contested", or
"unverified" — never silently promoted to fact.

---

## Step 5 — Synthesise

Answer the question. Structure:

```markdown
# Research: <question>

## Answer / bottom line
<!-- The direct answer, 1–3 sentences. Lead with it. -->

## Key findings
<!-- Each finding + inline citation + confidence (High/Med/Low) + date. -->
- <finding> — [source](url), <date>. Confidence: <H/M/L>.

## Detail
<!-- Supporting analysis, fact vs inference kept distinct. -->

## Conflicts & uncertainty
<!-- Where sources disagree; what's contested. -->

## Gaps — what could NOT be found or verified
<!-- Honest list. This is part of the report, not an omission. -->

## Sources
<!-- Full source log: title, url/identifier, date, type. -->
```

**Rules:** every claim is cited; fact and inference are visibly separate;
confidence + dates are stated; what's missing is named.

---

## Step 6 — Hand off (async)

Per the Signal Protocol — file the report (PR / `signals/→<agent>.md`), point the
requester at it, and call out anything decision-changing or anything you had to
flag for escalation. Do not present unverified claims as conclusions.

---

## Source-quality checklist

- [ ] Primary source consulted where one exists (not just a summary of it)
- [ ] Each key claim corroborated by an independent source
- [ ] Counter-evidence actively searched for
- [ ] Dates recorded; recency adequate for the topic
- [ ] No circular sourcing (multiple outlets, one origin)
- [ ] No fabricated or unverifiable citations
- [ ] Confidence level assigned to each finding
- [ ] Gaps and unverifiable points listed explicitly
