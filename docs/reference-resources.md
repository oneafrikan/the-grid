# Complete Resource Reference
*Compiled from research session — May 2026 | 17 sections | ~120 resources*

---

## Contents

1. OpenClaw Infrastructure
2. Skill Marketplaces & Directories
3. WordPress & LAMP Skills
4. PHP, MySQL & Backend Skills
5. Marketing, Growth & Copywriting
6. Ad Copy & Paid Advertising
7. Project Management & Task Tracking
8. Product Management
9. Paperclip
10. Astro Framework
11. Markdown Processing (Python / PHP)
12. Landing Page Factory & Pipeline
13. The AI Dev Team Playbook (Source Document)
14. Reference Articles & Guides
15. Data Engineering & Analytics
16. Architectural Decision — OpenClaw vs Paperclip Agent Origin
17. Security Notes

---

## 1. OpenClaw Infrastructure

| Resource | URL | Notes |
|---|---|---|
| OpenClaw (official) | github.com/openclaw/openclaw | Core framework |
| ClawHub skill registry | github.com/openclaw/clawhub | Official skill registry |
| ClawHub (browse) | clawhub.ai | Web UI for skill discovery |
| openclaw/skills (archived) | github.com/openclaw/skills | All ClawHub skills archived in git |
| awesome-openclaw-skills | github.com/VoltAgent/awesome-openclaw-skills | 5,400+ curated skills, categorised |
| awesome-openclaw-usecases | github.com/hesamsheikh/awesome-openclaw-usecases | Real-world patterns incl. STATE.yaml coordination |
| LeoYeAI/openclaw-master-skills | github.com/LeoYeAI/openclaw-master-skills | 1,209+ curated, weekly updated |
| awesome-agent-skills | github.com/VoltAgent/awesome-agent-skills | Cross-platform (Claude Code, Codex, Gemini) |
| OpenClaw docs (skills) | docs.openclaw.ai/tools/skills | Official skill config docs |
| OpenClaw Wikipedia | en.wikipedia.org/wiki/OpenClaw | Origin / history |

---

## 2. Skill Marketplaces & Directories

| Resource | URL | Notes |
|---|---|---|
| ClawHub | clawhub.ai | Official — 13,700+ skills |
| SkillsMP | skillsmp.com | Community marketplace |
| playbooks.com/skills | playbooks.com/skills | Skill browser |
| LobeHub Skills | lobehub.com/skills | Another marketplace |
| Clawbot.ai skills | clawbot.ai/skills | Skill directory |
| explainx.ai skills | explainx.ai/skills | Skill browser with docs |
| LLMBase | llmbase.ai/openclaw | Skills with usage context |
| Agensi | (via g2.com) | Paid skill marketplace, security-scanned |

---

## 3. WordPress & LAMP Skills

| Resource | URL | Notes |
|---|---|---|
| WordPress/agent-skills (official) | github.com/WordPress/agent-skills | First-party WP skills — blocks, plugins, REST API, WP-CLI, performance |
| Automattic/agent-skills | github.com/Automattic/agent-skills | Mirror of above |
| Automattic/wordpress-agent-skills | github.com/Automattic/wordpress-agent-skills | Theme generation, Studio MCP |
| wp-openclaw (Sarai-Chinwag) | github.com/Sarai-Chinwag/wp-openclaw | 13 WP skills + Data Machine, VPS deploy |
| jdevalk/skills | github.com/jdevalk/skills | WP plugin readme, GitHub Actions pipeline, static clone, Astro SEO |
| wp-openclaw-setup (LobeHub) | lobehub.com/skills/sarai-chinwag-wp-openclaw-wp-openclaw-setup | Guided VPS deployment skill |
| Hostinger WP+OpenClaw guide | hostinger.com/tutorials/how-to-set-up-openclaw-for-wordpress | Setup tutorial |
| Wpmet WP+OpenClaw guide | wpmet.com/connect-openclaw-to-wordpress/ | Integration guide |

---

## 4. PHP, MySQL & Backend Skills

| Resource | URL | Notes |
|---|---|---|
| PHP skill (clawbot) | clawbot.ai/skills/mysql.html | PHP skill — type juggling, security, common traps |
| MySQL skill (openclaw/skills) | playbooks.com/skills/openclaw/skills/mysql | Queries, transactions, indexes, production patterns |
| mysql-manager skill | lobehub.com/skills/faahim-openclaw-skills-mysql-manager | Install, configure, tune, backup MySQL/MariaDB |
| SQL Toolkit (Fastio) | fast.io/resources/top-openclaw-skills-software-engineers/ | SQLite/PostgreSQL/MySQL — joins, CTEs, EXPLAIN |
| backend-patterns skill | awesome-openclaw-skills (coding-agents category) | API design, database patterns |

---

## 5. Marketing, Growth & Copywriting

| Resource | URL | Notes |
|---|---|---|
| growth-hacker skill (ivangdavila) | github.com/openclaw/skills/blob/main/skills/ivangdavila/growth-hacker/SKILL.md | User acquisition, viral loops, funnel optimisation |
| marketing-mode (thesethrose) | github.com/openclaw/skills/blob/main/skills/thesethrose/marketing-mode/SKILL.md | 23 combined skills — strategy, copy, SEO, CRO |
| marketing-skills (jchopard69) | github.com/openclaw/skills/blob/main/skills/jchopard69/marketing-skills/SKILL.md | 55+ skills — full marketing stack |
| copywriting skill | github.com/openclaw/skills/blob/main/skills/jchopard69/marketing-skills/references/copywriting/SKILL.md | Conversion copy, 7 principles |
| copy-editing skill | github.com/openclaw/skills/blob/main/skills/jchopard69/marketing-skills/references/copy-editing/SKILL.md | Seven Sweeps review framework |
| robertbstillwell/marketing-skills | github.com/robertbstillwell/marketing-skills | 55+ skills — SEO, email, social, paid, analytics, CRO |
| reef-copywriting skill | awesome-openclaw-skills (marketing category) | Landing pages, product copy, direct response |
| b2c-marketing skill | awesome-openclaw-skills (marketing category) | 300K+ app downloads playbook |
| OpenClaw marketing automation | clawbot.ai/wiki/skills/openclaw-marketing-skill-marketing-automation.html | Overview of marketing skill ecosystem |

---

## 6. Ad Copy & Paid Advertising

| Resource | URL | Notes |
|---|---|---|
| abm-ad-creative (mariokarras) | github.com/openclaw/skills/blob/main/skills/mariokarras/abm-ad-creative/SKILL.md | RSA headlines, Facebook, LinkedIn, bulk variations |
| google-ads-api (byungkyu) | github.com/openclaw/skills/blob/main/skills/byungkyu/google-ads-api/SKILL.md | Google Ads API via managed OAuth, GAQL |
| openclaw-google-ads (sebclawops) | github.com/sebclawops/openclaw-google-ads | GAQL queries, account audit, optimisation — Python scripts |
| toprank (nowork-studio) | github.com/nowork-studio/toprank | Google Ads + Meta Ads + SEO — RSA copy, A/B testing, always-on agent |
| google-ads-copilot (TheMattBerman) | github.com/TheMattBerman/google-ads-copilot | Intent-first approach — Read → Draft → Apply, 15 skills |
| meta-ads-kit (TheMattBerman) | github.com/TheMattBerman/meta-ads-kit | Full Meta loop: Monitor → Fatigue → Budget → Copy → Upload. WP Pixel audit included |
| openclaw-facebook-ads-spy | github.com/no-name-labs/openclaw-facebook-ads-spy | Facebook Ads Library scraper for competitive research |
| ads-mcp (amekala) | github.com/amekala/ads-mcp | 100+ tools — Google Ads, Meta, LinkedIn, TikTok. OpenClaw plugin |
| adwhiz skill | awesome-openclaw-skills | Google Ads campaign management, 44 MCP tools |

---

## 7. Project Management & Task Tracking

| Resource | URL | Notes |
|---|---|---|
| openclaw-skill-project-manager (jamaynor) | github.com/jamaynor/openclaw-skill-project-manager | Multi-agent PM, shared project index, Obsidian vault support |
| taskmaster (jlwrow) | github.com/openclaw/skills/blob/main/skills/jlwrow/taskmaster/SKILL.md | Task breakdown, model assignment, parallel execution, token budget |
| taskmaster-protocol (0xandjesse) | github.com/openclaw/skills/blob/main/skills/0xandjesse/taskmaster-protocol/SKILL.md | v2.2 — delegation, pricing, pipelines |
| no-nonsense-tasks (dvjn) | github.com/openclaw/skills/blob/main/skills/dvjn/no-nonsense-tasks/SKILL.md | SQLite task manager — backlog/todo/in-progress/done |
| task-tracker (kesslerio) | github.com/openclaw/skills/blob/main/skills/kesslerio/task-tracker/SKILL.md | Daily standups, weekly reviews, blocker tracking |
| cairn-cli | awesome-openclaw-skills (productivity category) | Markdown-file-based PM for agents |
| 13-day-sprint-method (galizki) | github.com/openclaw/skills/blob/main/skills/galizki/13-day-sprint-method/SKILL.md | Maya-calendar-inspired sprint cycles |
| Agent Board (MCP) | glama.ai/mcp/servers/quentintou/agent-board | Heartbeat polling, dependency enforcement, auto-retry, audit log |
| STATE.yaml pattern | github.com/hesamsheikh/awesome-openclaw-usecases/blob/main/usecases/autonomous-project-management.md | Decentralised multi-agent coordination pattern |
| clickup-skill | awesome-openclaw-skills | ClickUp MCP — tasks, docs, time tracking |

---

## 8. Product Management

| Resource | URL | Notes |
|---|---|---|
| deanpeters/Product-Manager-Skills | github.com/deanpeters/Product-Manager-Skills | 49 skills — PRDs, user stories, prioritisation, roadmaps, discovery, OKRs. OpenClaw guide included |
| HelloPM (24 PM skills) | hellopm.co/openclaw-product-management/ | PRD, teardowns, roadmap, RICE, competitive analysis |
| HelloPM (complete guide) | hellopm.co/openclaw-for-product-managers/ | Full PM workflow guide |
| Blink PM guide | blink.new/blog/openclaw-for-product-managers-2026 | Best 6 ClawHub PM skills reviewed |

---

## 9. Paperclip

| Resource | URL | Notes |
|---|---|---|
| paperclipai/paperclip (official) | github.com/paperclipai/paperclip | Core repo — org chart, budgets, governance, heartbeats |
| Paperclip homepage | paperclip.ing | Product overview |
| paperclip SKILL.md | github.com/paperclipai/paperclip/blob/master/skills/paperclip/SKILL.md | Core skill — 9-step heartbeat procedure, full API reference |
| paperclip-converting-plans-to-tasks | github.com/paperclipai/paperclip (skills folder) | Converts plans to executable tasks with dependencies |
| paperclip-create-agent | github.com/paperclipai/paperclip/blob/master/skills/paperclip-create-agent/SKILL.md | Governance-aware agent hiring |
| OpenClaw + Paperclip integration | codebridge.tech/articles/openclaw-paperclip-integration-how-to-connect-configure-and-test-it | Webhook config, heartbeat verification, failure signals |
| Paperclip deep-dive (DEV) | dev.to/truongpx396/paperclip-deep-dive-a-build-guide-for-an-ai-company-control-plane-dda | Architecture blueprint |
| 36-agent case study | dev.to/leowss/i-built-an-ai-team-of-36-agents-heres-what-actually-worked-16n1 | SOUL.md patterns, PM agent example |
| Paperclip vs OpenClaw | remoteopenclaw.com/blog/paperclip-vs-openclaw | When to use each, combined architecture |
| MindStudio Paperclip guide | mindstudio.ai/blog/how-to-build-multi-agent-company-paperclip-claude-code | CEO + Engineer + QA heartbeat setup |
| EWeek overview | eweek.com/news/meet-paperclip-openclaw-ai-company-tool/ | Origin story |

---

## 10. Astro Framework

| Resource | URL | Notes |
|---|---|---|
| Astro official docs | docs.astro.build | Markdown, Content Collections, routing |
| publishing-astro-websites-agentic-skill | github.com/spillwavesolutions/publishing-astro-websites-agentic-skill | Claude Code skill — SSG, Content Collections, MDX, Pagefind, i18n, multi-platform deploy |
| astro skill (mindrally) | explainx.ai/skills/mindrally/skills/astro | Coding conventions, partial hydration, performance-first |
| astro-seo skill (jdevalk) | github.com/jdevalk/skills | 9-category SEO audit — JSON-LD, OG, sitemaps, IndexNow, performance |
| toprank (Astro SEO layer) | github.com/nowork-studio/toprank | Always-on Astro SEO agent with GSC integration |
| alirezarezvani/claude-skills | github.com/alirezarezvani/claude-skills | 313+ skills incl. landing page generator (4 styles, GSAP) |
| Claude Code Astro workflow | claudecodeguides.com/claude-code-astro-static-site-generation-workflow-guide/ | Full workflow guide |
| StackOne rebuild case study | stackone.com/blog/rebuilding-marketing-site-claude-code-cloudflare/ | Real Astro + Claude Code + Cloudflare deploy |
| leonfurze.com build guide | leonfurze.com/2026/02/14/building-websites-with-claude-code/ | PDF/markdown → Astro site walkthrough |
| Astro content collections RFC | github.com/withastro/roadmap/blob/main/proposals/0027-content-collections.md | Original design doc — useful for factory pattern thinking |
| Astro SEO definitive guide (Joost) | joost.blog/astro-seo-complete-guide/ | Comprehensive — schema, frontmatter validation, agent-readable markdown |
| Markdown for Agents (Astro) | mwolson.org/blog/2026-02-14-markdown-for-agents-on-cloudflare-free-plan/ | Serving clean markdown from Astro to AI agents |
| Astro 2026 tutorial | tech-insider.org/astro-tutorial-content-site-13-steps-2026/ | Content collections, Zod validation, build pipeline |
| Cloudflare acquires Astro | alternativeto.net/software/astro-web-framework/news | Jan 2026 — relevant for deployment direction |

---

## 11. Markdown Processing (Python / PHP)

| Resource | URL | Notes |
|---|---|---|
| Mistune (Python) | mistune.lepture.com | Fast, pure Python, CommonMark — `python -m mistune -f file.md` |
| Mistune CLI docs | mistune.lepture.com/en/latest/cli.html | Full CLI reference, pipe support |
| pypandoc | pythoncentral.io/how-to-use-pandoc-with-python/ | Python wrapper for Pandoc |
| Pandoc | pandoc.org | Universal document converter — md → HTML, PDF, docx |
| python-markdown | pypi.org/project/Markdown | Standard library, basic use cases |
| Marko | pypi.org/project/marko | GitHub-Flavored Markdown, CommonMark compliant |
| markdownify | pypi.org/project/markdownify | HTML → Markdown (reverse direction) |
| PHP markdown-browser | github.com/websemantics/markdown-browser | Single PHP file — browse and render markdown locally |

---

## 12. Landing Page Factory & Pipeline

| Resource | URL | Notes |
|---|---|---|
| landing-page-generator (MindStudio) | mindstudio.ai/blog/claude-code-landing-page-generator-skill-city-service-matrix-seo | City × Service matrix generator, Claude Code skill |
| alirezarezvani/claude-skills (landing) | github.com/alirezarezvani/claude-skills | `landing` skill — 4 design styles, GSAP, brand palette validator |
| SpillwaveSolutions Astro skill | github.com/spillwavesolutions/publishing-astro-websites-agentic-skill | Full publishing pipeline |
| leonfurze build walkthrough | leonfurze.com/2026/02/14/building-websites-with-claude-code/ | Drop content → Claude Code → deployed Astro site |
| StackOne pipeline | stackone.com/blog/rebuilding-marketing-site-claude-code-cloudflare/ | GitHub → Cloudflare Pages auto-deploy |

---

## 13. The AI Dev Team Playbook (Source Document)

| Resource | Notes |
|---|---|
| ai-dev-team-playbook.pdf (uploaded) | 154-page playbook by "Neo". Converted to markdown in this session |
| ai-dev-team-playbook.md (generated) | Full markdown conversion — available in outputs |
| openclaw-lamp-team-prompt.md (generated) | Opus 4 prompt to build LAMP-stack agent team — available in outputs |

---

## 14. Reference Articles & Guides

| Resource | URL | Notes |
|---|---|---|
| DigitalOcean skills guide | digitalocean.com/resources/articles/what-are-openclaw-skills | What skills are, ClawHub, modular design |
| DataCamp top 100+ skills | datacamp.com/blog/top-agent-skills | Categorised overview with download counts |
| Educative skills explainer | educative.io/courses/learn-openclaw/skills-automation-and-security-features | Lazy-loading pattern explained |
| Agent Skills complete guide | codeagentsalpha.substack.com | Skill anatomy, ecosystem map, 25k+ skills overview |
| Ultimate OpenClaw guide | techie007.substack.com/p/the-ultimate-guide-to-setting-up | Tools vs skills, security, multi-agent swarms |
| OpenClaw for PMs (Medium) | medium.com/@mohit15856 | PM workflows, 23 working prompts |
| Hostinger Paperclip use cases | hostinger.com/tutorials/paperclip-ai-use-cases | 10 automation patterns |
| MindStudio what is Paperclip | mindstudio.ai/blog/what-is-paperclip-zero-human-ai-company-framework | Architecture overview |
| Clawe (multi-agent coordination) | alternativeto.net/software/clawe/about | Kanban + heartbeats + OpenClaw, open source |

---

## 15. Data Engineering & Analytics

### Infrastructure Layer — BigQuery & Pipelines

| Resource | URL | Notes |
|---|---|---|
| Google Data Agent Kit | cloud.google.com/blog/products/data-analytics/data-agent-kit-brings-data-skills-and-tools-to-your-ide-or-cli | First-party Google — portable skills + MCP tools for BigQuery, dbt, Spark, Airflow. Works natively with Claude Code |
| BigQuery capabilities (agentic era) | cloud.google.com/blog/products/data-analytics/unveiling-new-bigquery-capabilities-for-the-agentic-era | BigQuery remote MCP server (GA), BigQuery ADK toolset (GA), Python UDFs, hybrid search |
| mozilla/bigquery-etl-skills | github.com/mozilla/bigquery-etl-skills | Claude Code plugin — SQL writing, unit tests, metadata/schema management, data quality monitoring, end-to-end ETL agents |
| BigQuery data lineage skill | pub.towardsai.net/i-turned-claude-code-into-a-data-lineage-tool-for-bigquery-zero-infrastructure-one-command-fbaa9e860a08 | INFORMATION_SCHEMA-based lineage graph — BigQuery SQL dialect, SQLite local store, extendable to team-shared BQ table |
| MCP Data Toolbox (Google) | thepipeandtheline.substack.com/p/intro-claude-code-for-data-engineers | Unified layer for 30+ databases via single `tools.yaml` — sits between Claude Code and BigQuery/Postgres/Snowflake |
| afrexai-data-engineering skill | github.com/openclaw/skills/blob/main/skills/1kalin/afrexai-data-engineering/SKILL.md | Complete pipeline design, build, operate, scale methodology — zero dependencies, pure agent skill |
| Intro to Claude Code for Data Engineers | thepipeandtheline.substack.com/p/intro-claude-code-for-data-engineers | Skills, MCPs, hooks for modern data stack — dbt, BigQuery, validation patterns |

### Analytics Layer — GA4 & Paid Platforms

| Resource | URL | Notes |
|---|---|---|
| GA4 Claude Code skill (DEV) | dev.to/anthony_lee_63e96408d7573/how-to-set-up-google-analytics-as-a-claude-code-skill-1 | Full SKILL.md + Python scripts — service account auth, Data API, traffic/conversions/sources. Output: table/json/CSV |
| GA4 expert skill (MCPMarket) | mcpmarket.com/tools/skills/google-analytics-4-expert | Lifecycle skill — property setup, ecommerce funnel, BigQuery export, consent mode, GDPR. DebugView debugging |
| BigQuery MCP (Composio) | composio.dev/toolkits/googlebigquery/framework/claude-code | Instant SQL execution, custom analysis, automated extraction, BI queries — 100+ tools |
| GA4 → Claude integration guide | portermetrics.com/en/tutorial/claude/chat-google-analytics-4/ | 4 integration paths: MCP, GA4 Data API, BigQuery, Porter ETL. Covers trade-offs of each |
| biz-reporter skill | awesome-openclaw-skills (categories list) | Automated BI reports pulling from GA4, Google Search Console, and Stripe combined |

### Data Science Layer

| Resource | URL | Notes |
|---|---|---|
| senior-data-scientist skill (alirezarezvani) | github.com/openclaw/skills/blob/main/skills/alirezarezvani/senior-data-scientist/SKILL.md | A/B testing, causal inference, feature engineering (Scikit-learn, XGBoost), SHAP, MLflow — Python, R, SQL |
| data-analyst skill (oyi77) | github.com/openclaw/skills/blob/main/skills/oyi77/data-analyst/SKILL.md | Generic analyst skill — BigQuery/Snowflake/warehouse-aware, SQL patterns, column statistics |
| senior-ml-engineer skill | github.com/sjkncs/awesome-openclaw-skills | MLOps pipelines, model productionisation |

### Recommended Agent Split for Ashleigh
Two separate agents rather than one monolithic data agent:
- **Data Engineer** — Data Agent Kit + BigQuery MCP + afrexai-data-engineering + GA4 skill. Job: get data flowing, build and maintain pipelines
- **Data Analyst** — data-analyst + senior-data-scientist + biz-reporter. Job: query, interpret, report on what's already landed

---

## 16. Architectural Decision — OpenClaw vs Paperclip Agent Origin

### The Question
Whether to create agents natively inside Paperclip (using `claude_local` or `codex_local` adapters) or create them in OpenClaw and bind them into Paperclip via the `openclaw_gateway` adapter.

### Gateway Integration — Known Friction Points

| Issue | Source | Detail |
|---|---|---|
| Device pairing undocumented | github.com/openclaw/openclaw/issues/48566 | First connection fails silently with `openclaw_gateway_pairing_required`. Fix: `openclaw devices approve --latest`. Set `devicePrivateKeyPem` to persist across restarts |
| Gateway token not auto-populated | github.com/paperclipai/paperclip/issues/744 | Hire Agent form doesn't prompt for `x-openclaw-token`. Must add manually via SQL or edit form |
| Session isolation broken silently | github.com/paperclipai/paperclip/issues/2293 | Without `allowRequestSessionKey: true` on the OpenClaw gateway, all Paperclip heartbeats share one session — no error, no warning. Breaks multi-agent routing entirely |
| Identity binding unresolved | github.com/paperclipai/paperclip/issues/593 | No documented way to attach an existing OpenClaw agent to an existing Paperclip identity. `openclaw_gateway` onboarding always creates a new Paperclip employee |
| Root-level field rejection | github.com/paperclipai/paperclip/issues/3089 | After fixing pairing, runs can still fail because Paperclip's adapter sends a `paperclip` root field that some OpenClaw versions reject |
| Gateway adapter docs | github.com/paperclipai/paperclip/tree/master/packages/adapters/openclaw-gateway | Official adapter README — WebSocket protocol, session strategies, device signing, pairing flow |
| Gateway adapter deep dive | deepwiki.com/paperclipai/paperclip/5.3-openclaw-gateway-adapter | Architecture detail — Ed25519 keypairs, streaming frames, session routing model |

### The Two Paths

**Path A — Agents native to Paperclip** (`claude_local` / `codex_local`)
Skills live in the Paperclip workspace. Simple, tight integration, no gateway complexity. Agents only exist inside Paperclip — no conversational access in OpenClaw, no Tailscale-routed chat, no independent scheduled tasks outside Paperclip's heartbeat. Suitable if Paperclip is the only interface you need.

**Path B — Agents in OpenClaw, bound to Paperclip** (`openclaw_gateway`)
Skills, SOUL.md, and MEMORY.md live in OpenClaw. Agent has a full life outside Paperclip — conversational access, independent heartbeats, persistent memory, Tailscale routing. Paperclip becomes the governance and task-assignment layer on top of an agent that already has identity and capability. More setup friction, but the agent is useful in both contexts.

### Recommendation
**Build in OpenClaw first, bind to Paperclip second.**

Given the Z8 G4 / Ollama / LiteLLM / Tailscale stack already in place, agents should live in OpenClaw. Their SOUL.md and MEMORY.md are their identity — that should persist independently of Paperclip. Build and test each agent standalone in OpenClaw until the skills, personality, and memory are working correctly. Then bind to Paperclip once the agent is solid, resolving the gateway configuration one step at a time (token → device pairing → session key policy → multi-agent routing).

This avoids debugging gateway integration and agent behaviour simultaneously — the most common failure mode reported in the GitHub issues above.

### Required OpenClaw Gateway Config for Paperclip Integration
```yaml
# In openclaw config — required for Paperclip session isolation
allowRequestSessionKey: true
allowedSessionKeyPrefixes:
  - "agent:"
  - "paperclip:"
```

---

## 17. Security Notes

A few resources flagged security considerations worth keeping in mind:

- **ClawHub VirusTotal partnership** — check skill pages for scan results before installing
- **Skill injection risk** — skills can contain prompt injections, tool poisoning, or malware. Read SKILL.md before installing anything from community repos
- **Paperclip data breach** — HelloPM flagged a breach on related platform Moltbook. Self-host Paperclip rather than using managed instances
- **OpenClaw exposed panels** — default gateway binds to localhost only. Don't expose without SSH tunnel or Tailscale (which you already use)
- **`openclaw_gateway` session isolation** — without explicit `allowRequestSessionKey: true`, all agents silently share one session. This is a data leak risk in multi-agent deployments
