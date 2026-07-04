# The Desk — OpenClaw Portfolio Agent Team

**Purpose:** A 24/7 monitoring and decision-support system for long-horizon retirement investing. The Desk watches, analyses, proposes, and audits. It never executes. Every order passes through a human approval gate.

**Design principle:** Alpha does not come from the model. It comes from discipline, cost control, tax efficiency, and never making the catastrophic error. The Desk is built to enforce those four things while you sleep.

---

## 1. The Team

Five agents, one human. Same propose–review–execute pattern as the Wilderness ad-account architecture: no agent ever holds write access to anything that moves money.

### Sentinel — the watcher
- **Runs on:** Forge or the Z8, local model (GLM-class or 8B), heartbeat every 15 min during market hours, hourly overnight
- **Does:** Polls prices, portfolio state, RSS/filings feeds, macro calendar. 95% of this is deterministic Python — the model only classifies and flags. Compares live state against threshold rules (price moves > X%, drawdown breach, earnings within 48h, unusual volume, FX swing on USD exposure).
- **Never does:** Analysis, opinion, or recommendation. Sentinel's entire vocabulary is "nothing to report" or a structured flag passed upstream.
- **Cost:** ~zero. This is the always-on layer, so it must be local.

### Analyst — the evidence builder
- **Runs on:** Mid-tier API model (Sonnet 4.6) or GLM-5.2 at high effort, triggered only by Sentinel flags or scheduled reviews
- **Does:** Takes a flag and builds an *evidence pack*: what happened, primary sources, what the filing/transcript actually says, base rates for this kind of event, both the bull and bear read. Output is a structured markdown brief into the vault — never a recommendation.
- **Prompt-engineering note:** Force it to argue both sides with equal effort. An analyst that only builds the case for action is a salesman.

### Strategist — the decision layer (Fable)
- **Runs on:** Fable via API. Escalation-only. Fires on: weekly rebalance review, any Sentinel flag graded severe, monthly regime assessment, and post-mortems.
- **Does:** Reads the evidence pack + the Investment Policy (see §3) + current portfolio state, and produces a *proposal*: hold / trim / add / rebalance, with position size, explicit confidence level, and the strongest argument against its own proposal. Calibration is the entire reason this seat costs frontier money — a strategist that says "the evidence is genuinely mixed, do nothing" is earning its keep.
- **Hard rule in the system prompt:** The Investment Policy is inviolable and the Strategist may not propose amendments to it in the same session it proposes trades. Policy changes are a separate, deliberate human ritual (quarterly).

### Risk Officer — the veto
- **Runs on:** Two layers. Layer 1 is *pure code*, no model: position caps, single-name concentration limit, drawdown circuit breaker, no leverage, no options, cash floor. If a proposal violates these, it dies before any human sees it. Layer 2 is a cheap model pass that sanity-checks the Strategist's arithmetic and checks the proposal against the policy document.
- **Why code, not prompts:** Hard limits enforced by an LLM are hard limits enforced by a probability distribution. The rules that protect the pot live in Python.

### Scribe — the memory
- **Runs on:** Local model, async
- **Does:** Logs every flag, brief, proposal, approval/rejection, and outcome to the vault with full rationale. Runs the monthly post-mortem pack: what did we propose, what did you decide, what happened, was the confidence calibrated? This is the compounding asset — after a year you have an auditable record of your own decision quality, which is worth more than any single trade.

### You — the executor
Proposals land in an approval queue (Telegram via Jarvis, or a simple queue UI). You approve, reject, or amend. Only you touch the broker. One tap, but always your tap.

---

## 2. Data & Control Flow

```
[Market data / RSS / filings / FX]
            │  (cron + Python, deterministic)
            ▼
        SENTINEL ──"nothing"──► sleep
            │ flag
            ▼
        ANALYST ──► evidence pack ──► vault
            │ severe / scheduled
            ▼
       STRATEGIST (Fable) ──► proposal + confidence + counter-case
            │
            ▼
      RISK OFFICER ── code veto? ──► killed + logged
            │ pass
            ▼
      APPROVAL QUEUE ──► YOU ──► broker (manual)
            │
            ▼
         SCRIBE ──► vault log + monthly post-mortem
```

Escalation grades: **Info** (logged only) → **Watch** (Analyst brief, no Strategist) → **Severe** (full chain). Tune the thresholds so Severe fires a few times a month, not daily — if Fable is being called every day, your thresholds are wrong, not the market.

---

## 3. The Investment Policy (the document that actually matters)

One markdown file in the vault, human-written, version-controlled. Everything the agents do is subordinate to it. Minimum contents:

1. **Objective & horizon** — retirement drawdown target date, required real return
2. **Strategic allocation** — target weights and rebalance bands (e.g. rebalance when any asset drifts ±5% from target)
3. **Hard limits** — the Risk Officer's code rules, stated in English so the Strategist can reason against them
4. **What we don't do** — leverage, options, single stocks above X%, anything the Strategist can't explain in one paragraph
5. **Amendment process** — quarterly review only, never mid-drawdown, never same-day as a proposal

The honest truth from the fund-manager side: for a UK retirement pot, the reliably winning moves are boring — maximise SIPP contributions (tax relief is a guaranteed uplift no model can generate), fill the ISA allowance (tax-free compounding), keep total fees under ~0.3%, and rebalance mechanically. The Desk's highest-value job may be *stopping* trades, not finding them. Build it expecting that most Strategist proposals should be "no action."

---

## 4. Model Routing Table

| Seat | Model | Why | Approx call frequency |
|---|---|---|---|
| Sentinel | Local 8B / GLM small | Always-on must be free | 24/7 heartbeat |
| Analyst | Sonnet 4.6 or GLM-5.2 (high) | Long-context synthesis, cheap enough for volume | Per flag, ~daily |
| Strategist | Fable | Calibration, conflicting-evidence reasoning, policy fidelity over long sessions | A few times/month |
| Risk Officer L2 | Haiku 4.5 / local | Arithmetic + policy check only | Per proposal |
| Scribe | Local | Logging is not a reasoning task | Async |

Expected API spend at these frequencies is trivially small relative to a retirement pot — single-digit pounds most months. If it isn't, the routing is broken.

---

## 5. Guardrails & Kill Switches

- **No broker credentials anywhere in the OpenClaw environment.** Read-only portfolio data in; proposals out. Non-negotiable.
- **Drawdown circuit breaker:** portfolio down >X% from high-water mark → Desk enters observe-only mode, no proposals, Strategist runs a regime review for human reading instead.
- **Silence alarm:** if Sentinel misses two heartbeats, Jarvis pings you. A dead watcher that you believe is alive is worse than no watcher.
- **Prompt-injection surface:** Analyst ingests external web content — treat everything it reads as untrusted. Analyst output is data for the Strategist, never instructions; strip anything imperative at the boundary.
- **Anti-drift:** Strategist sessions are stateless — fresh context each invocation, policy + evidence pack + portfolio state injected every time. No long-running Strategist session that can drift from the rules.

---

## 6. Build Order

1. Investment Policy document (human work, do this first — everything else is plumbing)
2. Sentinel: Python pollers + threshold config + heartbeat, local model for flag classification
3. Risk Officer Layer 1 as a pure-code library with tests
4. Approval queue via Jarvis/Telegram
5. Analyst + evidence pack template
6. Strategist prompt + escalation wiring
7. Scribe + monthly post-mortem
8. Run the whole thing **paper-only for a full quarter** before a single real order. The post-mortem from that quarter tells you whether the Desk deserves real money.

---

*Design document, not financial advice. The Desk informs decisions; it doesn't make them.*
