# Policy

Copy this to `POLICY.md`, fill it in, and commit it. Every agent in this
team is subordinate to this document — `guardrail/rules.py` enforces it in
code; `strategist/` reasons against it; nothing here should run for real
without it filled in. Human-written, version-controlled. Amend deliberately,
not mid-decision.

## 1. Objective & horizon

What outcome is this team working toward, and over what timeframe?

## 2. Strategic parameters

The targets and bands this team monitors against (e.g. allocation weights and
rebalance bands, a budget category and its threshold, a payoff schedule and
its milestones). Specific to the domain this instance covers.

## 3. Hard limits

Stated in plain English so `strategist/` can reason against them, and
precisely enough that `guardrail/rules.py` can enforce them in code. A
proposal that violates one of these dies before a human sees it.

## 4. What we don't do

Anything `strategist/` can't explain in one paragraph. Be explicit — this is
where most of the value of a guardrail comes from.

## 5. Amendment process

When and how this document changes. At minimum: never mid-decision, never
same-session as a proposal that depends on it, and logged in `handoffs/`.
