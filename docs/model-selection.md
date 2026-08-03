# Model selection — which model for which job

**Prices verified: 2026-08-03.** Refresh with `/grid-researcher` — see
[Refreshing this document](#refreshing-this-document) at the bottom for the
exact brief to hand it.

This is a decision document, not a price list. The price list is input; the
question it answers is *which model do I reach for in situation X*. The maths is
worked below so any session can recompute it — no calculator script, because a
script would go stale between refreshes and the arithmetic is trivial.

---

## Read this before the tables

Three findings from the August 2026 research pass change how you should read
every benchmark number below.

1. **SWE-bench Verified is compromised.** OpenAI publicly retired it as a
   frontier-capability signal in Feb 2026 — models reproduce gold patches from
   the task ID alone. Every current leaderboard is 100% vendor self-reported
   (llm-stats.com: "0 verified / 104 self-reported"). Treat any Verified score
   above ~80% as marketing. Use **Terminal-Bench 2.1** (tbench.ai) and
   **SWE-bench Pro** (Scale AI) instead — both independently run, harness
   disclosed.

2. **"Cheap models burn more turns" is an assumption, not a finding.** The
   research pass specifically hunted for a rigorous cross-model
   turns-to-completion or tokens-to-completion study and **found none**. A
   widely-circulated claim that GLM needs ~2x the turns but still wins on price
   by 46.78% traces to a single LinkedIn post. A supposed arXiv paper with
   tool-call-count tables was fetched directly — the table does not exist in the
   paper. Do not treat the efficiency-erosion thesis as settled; it is the
   single biggest open question in this document.

3. **One data point cuts against the cheap-model case anyway.** On
   Terminal-Bench 2.1, GLM-5.1 running in a Claude Code harness scored 58.7% —
   **last place, #17 of 17**. Same harness, same tasks. That is the most
   directly relevant independent measurement available for "swap a cheaper model
   into an agentic coding loop", and it is not encouraging.

---

## The decision table

| Situation | Reach for | Why |
|---|---|---|
| **Multi-file refactor, agentic coding loop, anything with self-correction** | Claude Opus 5 | Terminal-Bench 2.1 top tier. This is where cheap models measurably fail, and where a wrong answer costs more than the tokens saved. |
| **Long-horizon autonomous run, hardest reasoning** | Claude Fable 5 | #1 on Terminal-Bench 2.1 (83.8%). 2x Opus price — justified only when the run is long enough that a restart costs more than the premium. |
| **Everyday interactive coding, PRs, reviews** | Claude Sonnet 5 | 74.6% Terminal-Bench. **$2/$10 until 2026-08-31**, then $3/$15 — cheapest credible agentic tier right now. |
| **Cron / heartbeat / scheduled runs** | Claude Haiku 4.5 | $1/$5. Already the `cron_model` default in every `agent-factory` role.yaml. Classification and triage, not reasoning. |
| **High-volume mechanical generation** (scaffolding, boilerplate, bulk content) | GPT-5.6 Luna ($0.20/$1.20) or GLM-4.5-Air ($0.20/$1.10) | Where the price gap is real and the failure mode is cheap. Output is inspected in bulk, not trusted individually. |
| **Bulk classification / extraction / summarisation** | DeepSeek V4-Flash ($0.14/$0.28) | Cheapest credible option. Single-shot, no agentic loop, so the turns question doesn't apply. |
| **Anything touching data that can't leave your infrastructure** | Self-hosted open-weight — Mistral Large 3 (Apache 2.0) or DeepSeek V4-Pro (MIT) | Licence matters more than price here. Watch Mistral Medium 3.5's "Modified MIT" — void above $20M/mo revenue. |
| **Deciding between two models for a real workload** | Neither — run the bake-off | See [The measurement you actually need](#the-measurement-you-actually-need). |

### Rules of thumb

- **Agentic loop → don't optimise on token price.** The loop multiplies both
  quality and cost; a model that needs a second attempt has already lost the
  saving. The evidence gap in finding #2 cuts both ways, but finding #3 is the
  only harness-controlled measurement we have and it favours the expensive model.
- **Single-shot → optimise on token price aggressively.** No loop, no
  compounding, and the failure is visible immediately. This is where 10x price
  gaps are real money.
- **Prompt caching beats model choice for agentic work.** Claude cache reads are
  10% of input price ($0.50/1M on Opus 5 vs $5.00). A well-cached Opus loop can
  cost less than an uncached cheap-model loop. Check
  `usage.cache_read_input_tokens` — if it's zero across repeated calls, you have
  a silent invalidator and you're overpaying by ~10x on input.
- **Batch API is 50% off** for anything not latency-sensitive.

---

## Pricing

USD per 1M tokens, standard tier, verified 2026-08-03 against provider primary
sources.

### Anthropic

| Model | API ID | Input | Output | Cached read | Context / Max out |
|---|---|---|---|---|---|
| Fable 5 | `claude-fable-5` | $10 | $50 | $1.00 | 1M / 128K |
| Opus 5 | `claude-opus-5` | $5 | $25 | $0.50 | 1M / 128K |
| Sonnet 5 | `claude-sonnet-5` | **$2** ⚠ | **$10** ⚠ | $0.20 | 1M / 128K |
| Haiku 4.5 | `claude-haiku-4-5-20251001` | $1 | $5 | $0.10 | 200K / 64K |

⚠ **Sonnet 5 intro pricing expires 2026-08-31** → $3/$15. That's a 50% rise on
both sides. See the [watchlist](#dated-watchlist).

### Everyone else

| Provider | Model | Input | Output | Cached | Weights |
|---|---|---|---|---|---|
| OpenAI | GPT-5.6 Sol | $5 | $30 | $0.50 | API-only |
| OpenAI | GPT-5.6 Terra | $2 | $12 | $0.20 | API-only |
| OpenAI | GPT-5.6 Luna | $0.20 | $1.20 | $0.02 | API-only |
| Google | Gemini 3.6 Flash | $1.50 | $7.50 | $0.15 | API-only |
| Google | Gemini 3.1 Pro (preview) | $2 | $12 | $0.20 | API-only |
| Google | Gemma 4 | free (self-host) | — | — | Apache 2.0 |
| xAI | Grok 4.5 | $2 | $6 | $0.30 | API-only |
| xAI | Grok Build 0.1 (coding) | $1 | $2 | $0.20 | API-only |
| Z.ai | GLM-5.2 | $1.40 | $4.40 | $0.26 | **MIT**, 753B |
| Z.ai | GLM-4.7 | $0.60 | $2.20 | $0.11 | **MIT**, 358B |
| Z.ai | GLM-4.5-Air | $0.20 | $1.10 | $0.03 | **MIT**, 106B |
| DeepSeek | V4-Pro | $0.435 | $0.87 | $0.0036 | **MIT**, 1.6T/49B |
| DeepSeek | V4-Flash | $0.14 | $0.28 | $0.0028 | Open |
| Qwen | Qwen3.7-Max | $2.50 | $7.50 | — | API-only |
| Meta | Llama 4 Maverick | $0.27 | $0.85 | — | Llama 4 Community |
| Mistral | Medium 3.5 | $1.50 | $7.50 | -90% | Modified MIT ⚠ |
| Mistral | Large 3 | $0.50 | $1.50 | -90% | **Apache 2.0** |

⚠ Mistral's "Modified MIT" is void above $20M/mo company revenue. Large 3 is
plain Apache 2.0 with no revenue cap — the safer open-weight pick.

### Independent benchmarks (Terminal-Bench 2.1, tbench.ai)

The only column here worth trusting. Independently run, harness disclosed,
last updated 2026-07-11.

| Rank | Model | Score |
|---|---|---|
| 1 | Claude Fable 5 | 83.8% |
| 2 | GPT-5.5 (Codex) | 83.1% |
| 4 | Grok 4.5 (Cursor CLI) | 79.3% |
| 6 | GPT-5.6 Terra | 78.4% |
| 10 | Claude Sonnet 5 | 74.6% |
| 11 | Gemini 3.1 Pro | 73.9% |
| **17** | **GLM-5.1 (Claude Code harness)** | **58.7%** ← last |

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
| Opus 5 | $0.250 | $0.075 | **$0.325** |
| Sonnet 5 (intro) | $0.100 | $0.030 | **$0.130** |
| GLM-5.2 | $0.070 | $0.013 | **$0.083** |
| DeepSeek V4-Flash | $0.007 | $0.001 | **$0.008** |

Opus is 3.9x GLM. Now apply caching — 45K of that 50K input is a stable repo
prefix, so it's a cache read on every call after the first:

| Model | Fresh 5K | Cached 45K | Output 3K | Total |
|---|---|---|---|---|
| Opus 5 | $0.025 | $0.0225 | $0.0750 | **$0.1225** |
| GLM-5.2 | $0.007 | $0.0117 | $0.0132 | **$0.0319** |

Caching cuts both bills by ~60% and barely moves the ratio (3.9x → 3.8x) —
proportional savings don't change a model decision. What *would* change it is
retries:

| GLM attempts needed | GLM total | vs Opus @ $0.1225 |
|---|---|---|
| 1 | $0.0319 | GLM 3.8x cheaper |
| 2 | $0.0638 | GLM 1.9x cheaper |
| 3 | $0.0957 | GLM 1.3x cheaper |
| **4** | **$0.1276** | **Opus now cheaper** |

So the break-even is roughly **four attempts**, not two — the cheap model has a
lot of room to be wrong before price stops favouring it. The commonly-cited "2x
the turns" figure, even if it were sourced, would *not* by itself justify paying
for Opus on cost grounds alone.

The real argument for Opus is therefore **not** token economics. It's that a
failed agentic run costs reviewer attention and wall-clock time, and that the
one harness-controlled measurement available (finding #3) put a cheap model
dead last. Whether that holds for *your* workload is exactly what finding #2
says nobody has measured.

**Daily agent volume, 10K turns/day at 20K in / 2K out, uncached:**

| Model | Per turn | Per day | Per month |
|---|---|---|---|
| Opus 5 | $0.150 | $1,500 | $45,000 |
| Sonnet 5 (intro) | $0.060 | $600 | $18,000 |
| Sonnet 5 (from Sep 1) | $0.090 | $900 | $27,000 |
| Haiku 4.5 | $0.030 | $300 | $9,000 |
| GLM-5.2 | $0.037 | $368 | $11,040 |

At this volume the Sonnet 5 price change is **$9,000/month**. That is the single
most financially material dated item in this document.

---

## The measurement you actually need

Because finding #2 is an evidence gap and not a fact, the honest recommendation
for any real model-swap decision is to measure it rather than read a table:

1. Pick 20–30 representative tasks from your actual backlog. Not benchmarks —
   your issues.
2. Run each through both models in the **same harness**, same prompts, same
   tools. Harness matters enormously (see the GLM-5.1 Terminal-Bench result).
3. Record, per task: total input tokens, total output tokens, number of turns,
   and pass/fail against your own acceptance criteria.
4. Compute `total_cost_per_passed_task`, not cost per token. That's the only
   number that answers the question.

Anything short of this is inference from vendor marketing.

---

## Dated watchlist

Things in this document that expire. Check these first on any refresh.

| Date | What |
|---|---|
| **2026-08-05** | Claude Opus 4.1 (`claude-opus-4-1-20250805`) retires — **2 days from verification date** |
| **2026-08-15** | xAI `grok-code-fast-1` hard-retires → `grok-build-0.1` |
| **2026-08-31** | Claude Sonnet 5 intro pricing ends: $2/$10 → $3/$15 |
| undated | GLM-5.2 cached-input promo ($0.26) — no expiry published |
| undated | Qwen3.7-Max/Plus prices include an active promo — no expiry published |

---

## Known gaps

Stated explicitly so nobody fills them with a plausible guess.

- **No cross-model turns/tokens-to-completion study exists** as published
  research. This is the big one.
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
- **A cluster of SEO sites** (digitalapplied.com, mindstudio.ai, verdent.ai,
  codingfleet.com, lushbinary.com, aipricing.guru) recurs across nearly every
  model search and was confirmed to reuse templated phrasing with swapped
  numbers, sometimes self-contradicting within one article. Multiple hits across
  those domains is **not** corroboration.

---

## Refreshing this document

Run `/grid-researcher` with the brief below. Then update: the pricing tables,
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
> 4. Pull **Terminal-Bench** (tbench.ai) and **SWE-bench Pro** (Scale AI) current
>    standings. Do NOT use SWE-bench Verified as a capability signal — it is
>    contaminated and vendor-self-reported.
> 5. Search again for any rigorous cross-model turns-to-completion or
>    tokens-to-completion study in agentic loops. As of Aug 2026 none existed.
>    If one now does, it is the most important finding in the refresh.
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
