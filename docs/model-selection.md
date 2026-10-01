# Model selection — which model for which job

**Prices verified: 2026-10-02** (a `core-researcher` pass against provider primary pages; figures were not re-fetched by a second source). Refresh with the `core-researcher` subagent — see
[Refreshing this document](#refreshing-this-document) at the bottom for the
exact brief to hand it.

This is a decision document, not a price list. The price list is input; the
question it answers is *which model do I reach for in situation X*. The maths is
worked below so any session can recompute it — no calculator script, because a
script would go stale between refreshes and the arithmetic is trivial.

---

## Read this before the tables

Three findings from the October 2026 refresh change how you should read
every benchmark number below.

1. **SWE-bench Verified is compromised.** OpenAI publicly retired it as a
   frontier-capability signal in Feb 2026 — models reproduce gold patches from
   the task ID alone. Every current leaderboard is 100% vendor self-reported.
   Use **Terminal-Bench** (tbench.ai; now **v4.0**, which publishes tokens and
   cost per run) and **SWE-bench Pro** (Scale AI) instead — both independently
   run, harness disclosed. Scale's SWE-bench Pro board has no current-generation
   models, so treat it as a historical reference.

2. **A partial turns/tokens-to-completion study now exists; nothing controlled
   across current models does.** arXiv 2604.22750 (Bai et al., Apr 2026) measures
   tokens per task for 8 older models (Sonnet 3.7–4.5, GPT-5/5.2, Qwen3-Coder,
   Kimi-K2, Gemini-3-Pro-Preview) in one harness on SWE-bench Verified: Kimi-K2
   and Sonnet 4.5 used over 1.5M more tokens per task than GPT-5, and accuracy
   often peaks at intermediate cost. Terminal-Bench 4.0 adds tokens and cost per
   row, but each model ran in its own harness. The earlier "none exists" statement
   was too strict; "cheap models burn more turns" is still not settled for
   current models.

3. **Cost per passed task varies far more than token price.** Terminal-Bench 4.0
   (derived here as cost / (score x 330 trials), not published on the site):
   GPT-6 Luna (max) about $6, GPT-6 Astra (high) about $12, GLM-5.3 (max) about $20,
   Fable 5.1 (high) about $22, Opus 5 (xhigh) about $34, Sonnet 5 (max) about $234
   (a 2026-06-30 run of an older model; Sonnet 5.5 is not on the board).
   Harness is confounded with model, so read these as a signal, not a ranking.
   The previous "GLM-5.1 last of 17" result is superseded: GLM-5.3 (max) is
   mid-table on 4.0 and ahead of Grok 4.7, GPT-5.6 Sol and Sonnet 5, under a
   Claude Code harness.

---

## The decision table

| Situation | Reach for | Why |
|---|---|---|
| **Multi-file refactor, agentic coding loop, anything with self-correction** | Claude Opus 5.5 ($4/$20) | Opus 5 (xhigh) is rank 8 on Terminal-Bench 4.0 (53.9%); Opus 5.5 is not on the board yet. Cheaper than Opus 5 ($5/$25) with a 5% cache-read rate. |
| **Long-horizon autonomous run, hardest reasoning** | Claude Fable 5.1 | Tied for rank 2 on Terminal-Bench 4.0 (57.9%, within the ±2.8 CI of rank 1). 2.5x Opus 5.5 price — justified only when the run is long enough that a restart costs more than the premium. |
| **Everyday interactive coding, PRs, reviews** | Claude Sonnet 5.5 ($2/$10) | The Sonnet 5 price rise to $3/$15 was cancelled; $2/$10 is the standard price. **No Terminal-Bench 4.0 result for 5.5**, and Sonnet 5 (max) scored 12.4% at 21.6B tokens — an older model, but a flag to measure before relying on it for agentic loops. |
| **Cron / heartbeat / scheduled runs** | Claude Haiku 4.5 | $1/$5. The `cron_model` default (`DEFAULT_CRON_MODEL` in `agent-factory/compose.py`); only ceo-orchestrator, tech-lead, finance-manager and gh-triage set it in role.yaml. Classification and triage, not reasoning. **Commitment floor 2026-10-15** (not sooner than; no deprecation notice as of 2026-10-02) — see the watchlist. |
| **High-volume mechanical generation** (scaffolding, boilerplate, bulk content) | GPT-6 Luna ($0.10/$0.50) or GLM-4.5-Air ($0.20/$1.10) | Where the price gap is real and the failure mode is cheap. Output is inspected in bulk, not trusted individually. |
| **Bulk classification / extraction / summarisation** | DeepSeek V4.1-Flash (`deepseek-flash`, $0.15/$0.60 off-peak, 2x at peak) | Cheapest credible option. Single-shot, no agentic loop, so the turns question doesn't apply. Peak hours are 01:00–04:00 and 06:00–10:00 UTC, Mon–Fri. |
| **Anything touching data that can't leave your infrastructure** | Self-hosted open-weight — Mistral Large 3 (Apache 2.0) or DeepSeek V4-Pro (MIT, original release) | Licence matters more than price here. DeepSeek's V4-Pro-0813 licence was not confirmed. Watch Mistral Medium 3.5's "Modified MIT" — void above $20M/mo revenue (not re-checked). |
| **Deciding between two models for a real workload** | Neither — run the bake-off | See [The measurement you actually need](#the-measurement-you-actually-need). |

### Rules of thumb

- **Agentic loop → optimise on cost per passed task, not token price.** The loop
  multiplies both quality and cost; a model that needs a second attempt has
  already lost the saving, and Terminal-Bench 4.0 shows cost per pass varying
  roughly 40x across models that look similar on a price list (finding #3).
- **Single-shot → optimise on token price aggressively.** No loop, no
  compounding, and the failure is visible immediately. This is where 10x price
  gaps are real money.
- **Prompt caching beats model choice for agentic work.** Claude cache reads are
  5% of input price on Opus 5.5 ($0.20/1M vs $4.00) and 2.5% on Fable 5.1
  ($0.25 vs $10). A well-cached Opus loop can cost less than an uncached
  cheap-model loop. Check `usage.cache_read_input_tokens` — if it's zero across
  repeated calls, you have a silent invalidator and you're overpaying by 10–20x
  on input.
- **Batch API is 50% off** for anything not latency-sensitive.
- **Tokenizer:** Anthropic's pricing page says Claude 4.7+ models produce about
  30% more tokens for the same text, so per-token price is not like-for-like
  against Sonnet 4.6 and earlier.

---

## Pricing

USD per 1M tokens, standard tier, verified 2026-10-02 against provider primary
sources (see the status note at the top).

### Anthropic

| Model | API ID | Input | Output | Cached read | Context / Max out |
|---|---|---|---|---|---|
| Fable 5.1 | `claude-fable-5-1` | $10 | $50 | $0.25 | 1M / 128K |
| Opus 5.5 | `claude-opus-5-5` | $4 | $20 | $0.20 | 1M / 128K |
| Sonnet 5.5 | `claude-sonnet-5-5` | $2 | $10 | $0.20 | 1M / 128K |
| Haiku 4.5 | `claude-haiku-4-5-20251001` (alias `claude-haiku-4-5`) | $1 | $5 | $0.10 | 200K / 64K |

Still active, older: Fable 5 (`claude-fable-5`, floor 2027-06-09), Opus 5
(`claude-opus-5`, $5/$25, floor 2027-07-24), Sonnet 5 (`claude-sonnet-5`, $2/$10,
floor 2027-06-30). The Sonnet 5 intro-price expiry (2026-08-31 → $3/$15) was
**cancelled**: the pricing page footnote says $2/$10 is now the standard price.
Knowledge cutoff for the 5.x models: Jun 2026.

### Everyone else

| Provider | Model | Input | Output | Cached | Weights |
|---|---|---|---|---|---|
| OpenAI | GPT-6 Astra (`gpt-6-astra`) | $10 | $50 | $1 | API-only |
| OpenAI | GPT-6.1 Sol (`gpt-6.1-sol`) | $2 | $10 | $0.10 | API-only |
| OpenAI | GPT-6 Luna (`gpt-6-luna`) | $0.10 | $0.50 | $0.01 | API-only |
| OpenAI | GPT-5.6 Sol (promo) | $4 | $20 | $0.40 | API-only |
| OpenAI | GPT-5.6 Terra | $2 | $12 | $0.20 | API-only |
| OpenAI | GPT-5.6 Luna | $0.20 | $1.20 | $0.02 | API-only |
| Google | Gemini 3.8 / 3.7 / 3.6 Flash (promo to 2026-12-31) | $0.75 | $3.75 | $0.075 | API-only |
| Google | Gemini 3.1 Pro (preview, ≤200K) | $2 | $12 | $0.20 | API-only |
| Google | Gemma 4 (not re-verified) | free (self-host) | — | — | Apache 2.0 |
| xAI | Grok 4.7 | $2 | $6 | $0.50 | API-only |
| xAI | Grok 4.5 | $2 | $6 | $0.30 | API-only |
| xAI | Grok Build 0.1 (coding) | $1 | $2 | $0.20 | API-only |
| Z.ai | GLM-5.3 | $1.40 | $4.40 | $0.26 | 753B; licence not confirmed as MIT (card names "glm-5.3") |
| Z.ai | GLM-5.2 | $1.40 | $4.40 | $0.26 | **MIT**, 753B (not re-checked) |
| Z.ai | GLM-4.7 | $0.60 | $2.20 | $0.11 | **MIT**, 358B |
| Z.ai | GLM-4.5-Air | $0.20 | $1.10 | $0.03 | **MIT**, 106B |
| DeepSeek | V4-Pro (`deepseek-v4-pro`, 0813), off-peak | $0.66 | $1.98 | $0.022 | MIT (original V4-Pro; -0813 not confirmed) |
| DeepSeek | V4.1-Flash (`deepseek-flash`), off-peak | $0.15 | $0.60 | $0.003 | Open |
| Qwen | Qwen3.8-Max | $2 | $6 | — | API-only |
| Qwen | Qwen3.7-Max (20% discount, no expiry given) | $2.50 | $7.50 | — | API-only |
| Meta | Llama 4 Maverick (not re-verified 2026-10-02) | $0.27 | $0.85 | — | Llama 4 Community |
| Mistral | Medium 3.5 | $1.50 | $7.50 | -90% | Modified MIT ⚠ |
| Mistral | Large 3 | $0.50 | $1.50 | -90% | **Apache 2.0** |
| Mistral | Small 4 | $0.15 | $0.60 | -90% | **Apache 2.0** |

Notes:
- Gemini 3.6/3.7/3.8 Flash prices **double on 2027-01-01** ($1.50/$7.50/$0.15).
- OpenAI inputs over 272K are priced higher (the pricing page says doubled for the
  GPT-6 models); Batch and Flex are 50% of Standard; Fast mode is 2x.
- Grok requests of 200K or more are $4/$12 (cache $0.60) on all tokens.
- DeepSeek peak pricing is 2x the figures shown (peak hours listed in the decision
  table). Legacy IDs `deepseek-v4-flash` and `-vision-exp` are "retired" but still
  accepted, redirected to Flash pricing; no date given.
- ⚠ Mistral's "Modified MIT" is void above $20M/mo company revenue (not re-checked).
  Large 3 is plain Apache 2.0 with no revenue cap — the safer open-weight pick.

### Independent benchmarks (Terminal-Bench 4.0, tbench.ai)

The only column here worth trusting. Independently run, harness disclosed, board
updated 2026-09-21, 330 trials per row. Different agents ran different models, so
harness is confounded with model. The top rows are within the ±2.8 CI of each other.
Terminal-Bench 2.1 scores (Fable 5 83.8%, Sonnet 5 74.6%) are a different benchmark
version and are **not comparable** to these.

| Rank | Agent + model (effort) | Score | Tokens | Cost | Run date |
|---|---|---|---|---|---|
| 1 | Codex, GPT-6 Astra (max) | 58.18% | 1.53B | $3,267 | 09-03 |
| 2 | Claude Code, Fable 5.1 (max) | 57.88% | 2.75B | $6,244 | 09-01 |
| 2 | Codex, GPT-6 Astra (xhigh / high) | 57.88% | 1.20B | $2,351 / $2,269 | 09-03 |
| 2 | Claude Code, Fable 5.1 (xhigh) | 57.88% | 2.34B | $4,872 | 09-01 |
| 8 | Claude Code, Opus 5 (xhigh) | 53.94% | 6.90B | $6,086 | 07-24 |
| 16 | Claude Code, GLM-5.3 (max) | 41.82% | 8.68B | $2,728 | 08-14 |
| 17 | Grok Build, Grok 4.7 (xhigh) | 37.58% | 5.49B | $3,683 | 09-21 |
| 18 | Codex, GPT-5.6 Sol (max) | 37.27% | 4.41B | $2,542 | 06-26 |
| 23 | mini-SWE-agent, Gemini 3.8 Flash (high) | 19.09% | 17.19B | $1,829 | 09-02 |
| 24 | Codex, GPT-5.6 Luna (max) | 17.27% | 11.56B | $347 | 06-26 |
| 25 | Claude Code, Sonnet 5 (max) | 12.42% | 21.56B | $9,604 | 06-30 |

Not on the board: Opus 5.5, Sonnet 5.5, Gemini 3.1 Pro, Opus 4.6.

---

## The maths

Any session can run these. Don't build a script for it.

**Cost of one call:**

```
cost = (input_tokens / 1e6 × input_price)
     + (output_tokens / 1e6 × output_price)
```

**With caching** (the version that matters for agentic work):

```
cost = (fresh_input / 1e6 × input_price)
     + (cached_input / 1e6 × cached_price)
     + (output_tokens / 1e6 × output_price)
```

**Worked: a 50K-input / 3K-output repo review, uncached**

| Model | Input | Output | Total |
|---|---|---|---|
| Opus 5.5 | $0.200 | $0.060 | **$0.260** |
| Sonnet 5.5 | $0.100 | $0.030 | **$0.130** |
| GLM-5.2 | $0.070 | $0.013 | **$0.083** |
| DeepSeek V4.1-Flash (off-peak) | $0.008 | $0.002 | **$0.009** |

Opus 5.5 is 3.1x GLM-5.2. Now apply caching — 45K of that 50K input is a stable repo
prefix, so it's a cache read on every call after the first:

| Model | Fresh 5K | Cached 45K | Output 3K | Total |
|---|---|---|---|---|
| Opus 5.5 | $0.020 | $0.0090 | $0.0600 | **$0.0890** |
| GLM-5.2 | $0.007 | $0.0117 | $0.0132 | **$0.0319** |

Caching cuts the Opus bill by about 65% and GLM's by about 60%, and the ratio moves only from 3.1x to 2.8x —
proportional savings don't change a model decision. What *would* change it is
retries:

| GLM attempts needed | GLM total | vs Opus @ $0.0890 |
|---|---|---|
| 1 | $0.0319 | GLM 2.8x cheaper |
| 2 | $0.0638 | GLM 1.4x cheaper |
| **3** | **$0.0957** | **Opus now cheaper** |

So the break-even is roughly **three attempts**, not two — the cheap model has some
room to be wrong before price stops favouring it. The commonly-cited "2x
the turns" figure, even if it were sourced, would *not* by itself justify paying
for Opus on cost grounds alone.

The real argument for Opus is therefore **not** token economics. It's that a
failed agentic run costs reviewer attention and wall-clock time, and that the
Terminal-Bench 4.0 cost-per-pass spread (finding #3) shows token price
alone does not predict the cheaper run. Whether that holds for *your* workload is exactly what finding #2
says has only been measured in part.

**Daily agent volume, 10K turns/day at 20K in / 2K out, uncached:**

| Model | Per turn | Per day | Per month |
|---|---|---|---|
| Opus 5.5 | $0.120 | $1,200 | $36,000 |
| Sonnet 5.5 | $0.060 | $600 | $18,000 |
| Haiku 4.5 | $0.030 | $300 | $9,000 |
| GLM-5.2 | $0.037 | $368 | $11,040 |

The Sonnet 5 price rise that would have added $9,000/month at this volume was
cancelled. The dated item that matters most to the grid itself is now the
Haiku 4.5 commitment floor (2026-10-15): it is the `cron_model` default.

---

## The measurement you actually need

Because finding #2 is an evidence gap (partial evidence only) and not a settled fact, the honest recommendation
for any real model-swap decision is to measure it rather than read a table:

1. Pick 20–30 representative tasks from your actual backlog. Not benchmarks —
   your issues.
2. Run each through both models in the **same harness**, same prompts, same
   tools. Harness matters enormously (harness is confounded with model on Terminal-Bench 4.0).
3. Record, per task: total input tokens, total output tokens, number of turns,
   and pass/fail against your own acceptance criteria.
4. Compute `total_cost_per_passed_task`, not cost per token. That's the only
   number that answers the question.

Anything short of this is inference from vendor marketing.

---

## Which role uses which model

Verified 2026-10-02 against `origin/main` (`default_model` in each public `agent-factory/roles/*/role.yaml`).
Tier words, not pinned model IDs: Claude Code resolves a tier to its current release, so a
retirement or alias move changes every role on that tier at once. Regenerate with:

```bash
for r in agent-factory/roles/*/; do printf '%s %s\n' "$(awk '/^default_model/{print $2}' "$r/role.yaml")" "$(basename "$r")"; done | sort
```

| Tier | Roles |
|---|---|
| opus (2) | ceo-orchestrator, tech-lead |
| fable (1) | finance-strategist |
| haiku (3) | finance-risk-officer, finance-scribe, finance-sentinel |
| sonnet (28) | every other public role |

No `role.yaml` pins a model ID: every role uses a tier word (checked above), so a retirement is a tier-level event, not a per-role edit.

`cron_model`: `haiku` unless a role sets its own (gh-triage sets `sonnet`; ceo-orchestrator,
tech-lead and finance-manager set `haiku` explicitly).

---

## Dated watchlist

Things in this document that expire. Check these first on any refresh.

| Date | What |
|---|---|
| **2026-10-15** | Claude Haiku 4.5 commitment floor ("not sooner than"). No deprecation notice exists as of 2026-10-02. It is the `cron_model` default for every role. |
| 2026-11-21 | GPT-5.6 Sol promo ($4/$20) "available at least through" this date; the post-promo price is not stated. |
| 2026-11-24 | Claude Opus 4.5 retirement floor. |
| **2026-11-30** | **Claude Sonnet 4.5 retires** (deprecated 2026-09-30); replacement `claude-sonnet-5-5`. No grid role pins it. |
| **2026-12-31** | Gemini 3.6/3.7/3.8 Flash promo ends; prices double on 2027-01-01. |
| 2027-02-05 / 02-17 | Opus 4.6 and Sonnet 4.6 floors. |
| 2027-04-16 / 05-28 | Opus 4.7 and Opus 4.8 floors. |
| 2027-06-09 / 06-30 / 07-24 | Fable 5, Sonnet 5 and Opus 5 floors. |
| 2027-09-01 / 09-22 / 09-28 | Fable 5.1, Opus 5.5 and Sonnet 5.5 floors. |
| undated | Qwen3.7-Max/Plus 20% discount; Z.ai "limited-time free" cached storage — no expiry published. |

Resolved since 2026-08-03: Opus 4.1 retired 2026-08-05; the Sonnet 5 price rise (2026-08-31)
was cancelled; xAI `grok-code-fast-1` (2026-08-15) was not confirmed either way.

---

## Known gaps

Stated explicitly so nobody fills them with a plausible guess.

- **No controlled cross-model turns/tokens-to-completion study exists for current
  models.** A partial one covers older models (arXiv 2604.22750, finding #2), and
  Terminal-Bench 4.0 publishes tokens and cost per row, but each model ran in its
  own harness. This is still the big one.
- **Knowledge cutoffs are undisclosed** by Google, xAI, Z.ai, DeepSeek, Qwen,
  Meta, and Mistral on every current-generation model page. Only Anthropic and
  OpenAI publish them. Don't imply parity.
- **Max output tokens unpublished** for all Grok models, all hosted Qwen models,
  and Llama 4 (only host-side caps exist, varying 4K–16K by provider).
- **No transparent self-host break-even analysis exists** for any open-weight
  family. Every circulating figure traces to SEO content-mill sites; two
  families had internally contradictory numbers across sources. Build your own
  from GPU sizing + your actual rental rate.
- **GPT has no published BFCL score, JSON-reliability data, or self-correction
  data** anywhere — a real gap given OpenAI's position.
- **Grok is conspicuously absent** from every long-context and tool-calling
  leaderboard covering the other eight families.
- **Unverified at the 2026-10-02 refresh:** Meta pricing, licence, cutoff and max
  output (only aggregator figures found); GLM-5.3 and DeepSeek V4-Pro-0813
  licences; Gemma 4 and gpt-oss status; the GPT-5.6 Sol post-promo price; Qwen
  context, licence and promo expiry; the Terminal-Bench 2.1 leaderboard contents;
  and a cross-check against the `claude-api` skill's cached table.
- **A cluster of SEO sites** (digitalapplied.com, mindstudio.ai, verdent.ai,
  codingfleet.com, lushbinary.com, aipricing.guru) recurs across nearly every
  model search and was confirmed to reuse templated phrasing with swapped
  numbers, sometimes self-contradicting within one article. Multiple hits across
  those domains is **not** corroboration.

---

## Refreshing this document

Delegate to the `core-researcher` subagent with the brief below. Then update: the pricing tables,
the benchmark table, the watchlist, and the verification date at the top. Rework
the decision table only if a benchmark or price change actually moves a
recommendation — the decision table is the point of the document, not a
changelog.

**Brief to hand the researcher:**

> Re-verify the LLM pricing and capability landscape for a model-selection
> document. Every number must come from a provider primary source with the date
> verified — no aggregators, no SEO blogs.
>
> 1. For Anthropic, OpenAI, Google, xAI, Z.ai, DeepSeek, Qwen, Meta, Mistral:
>    current model IDs, input/output/cached-input price per 1M, context window,
>    max output, weights licence, knowledge cutoff.
> 2. Flag every introductory or promotional rate and its expiry date.
> 3. Flag every deprecation and retirement date.
> 4. Pull **Terminal-Bench** (tbench.ai, now v4.0) and **SWE-bench Pro** (Scale AI) current
>    standings. Do NOT use SWE-bench Verified as a capability signal — it is
>    contaminated and vendor-self-reported.
> 5. Search again for any rigorous cross-model turns-to-completion or
>    tokens-to-completion study in agentic loops. As of Oct 2026 only a partial
>    one existed (arXiv 2604.22750, older models, one harness). If a controlled
>    one over current models now exists, it is the most important finding.
> 6. Report what you could NOT verify rather than filling gaps with plausible
>    numbers.
>
> Known-bad sources to exclude: digitalapplied.com, mindstudio.ai, verdent.ai,
> codingfleet.com, lushbinary.com, aipricing.guru.
>
> Note: `anthropic.com/pricing` and `openai.com/api/pricing` now redirect or 403.
> The working hosts are `platform.claude.com/docs/.../pricing` and
> `developers.openai.com/api/docs/pricing`.

**Then cross-check Anthropic numbers against the `claude-api` skill** rather
than trusting the research alone — but note that skill ships a *cached* table
with its own date, so whichever is fresher wins. At the time of writing the
skill's table was cached 2026-06-04 and predated Opus 5 and Sonnet 5.

**Where this connects:** `agent-factory/roles/*/role.yaml` sets `default_model`
and `cron_model` per role. If a recommendation here changes, that's where it
gets applied — then recompose and re-wire (see `BOOTSTRAP.md`).
