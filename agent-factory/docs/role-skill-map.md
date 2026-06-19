# Role → Skill Map & Roster Expansion Plan

> **Partly superseded (2026-06-19).** `growth-hacker` is now an **orchestrator**
> (the marketing-arm lead), so the team is **3 orchestrators + 17 specialists** — not
> the "Orchestrators: ceo-orchestrator, tech-lead" line below. Orchestrator rosters
> are now **generated** from each one's `delegates_to` in the compose config, not
> hand-written. This file is kept as the 2026-06-16 planning snapshot; for the current
> mechanism see `agent-factory/README.md` → *Rosters & delegation*.

Planning doc (2026-06-16). Maps the agent-factory roster to skill sources already
present as submodules in `repos/`, and proposes the broader-role expansion that
surfaced in the May-2026 research session (see `../../docs/reference-resources.md`
and `../../docs/reference-repos.md`).

**Status (2026-06-16): roster expansion DONE; skills population DEFERRED.**
Decisions made: added **seo, security-reviewer, designer, data-scientist,
project-manager** (5) — roster now **17**, all emitted + wired live. Skills
mechanism chosen = **(A) symlink from repos/**, but population is **deferred to the
OpenClaw-target work** (TODO #8): the live Claude Code subagents already get
ecosystem skills via `wire.sh`, so `agent-factory/skills/` only pays off for
compose-validation of declared bolt-ons + the by-name wiring the OpenClaw target
needs. project-manager kept separate from product-manager. Social/email/content
remain skills, not roles.

---

## 1. Current roster (12, built — 5-file model)

Orchestrators: `ceo-orchestrator`, `tech-lead`.
Specialists: `product-manager`, `backend-dev`, `frontend-dev`, `qa-engineer`,
`devops`, `data-engineer`, `data-analyst`, `copywriter`, `ad-copy`, `growth-hacker`.

## 2. Proposed new roles (the `..../` expansion slot)

All specialists (subagents) unless noted. Default `sonnet`.

| Role | Rationale | Skill sources (repos/) | Verdict |
|------|-----------|------------------------|---------|
| **seo** | SEO is a distinct discipline; currently homeless (falls to growth-hacker/copywriter) | `nowork-toprank`, `jdevalk` (astro-seo), marketing-mode SEO | **Add** |
| **security-reviewer** | Playbook ×30; no security lane today | `jeffallan/security-reviewer` + `secure-code-guardian`, `gstack/cso` | **Add** |
| **designer** (UI/UX) | frontend-dev *builds* but doesn't *design* | `anthropic` (canvas-design, frontend-design, theme-factory), `gstack/design-review` | **Add** |
| **data-scientist** | A/B, causal inference, ML — beyond data-analyst's query/report | `alirezarezvani/senior-data-scientist` | **Add (or fold into data-analyst)** |
| **project-manager** | Delivery/tasks vs product-manager's scope/PRD | `deanpeters`, `jamaynor` PM, taskmaster | **Optional — overlaps product-manager; confirm split** |
| social / email / content | Sub-specialisations of copywriter/growth-hacker | `robertbstillwell` (55+), marketing-skills | **Skip as roles — wire as skills instead** |

Recommendation: add **seo, security-reviewer, designer, data-scientist** (4).
Hold **project-manager** pending a clear PM-vs-PdM boundary. Treat social/email/
content as *skills*, not roles.

## 3. Role → skill source map (drives TODO #8)

Skills to curate into `agent-factory/skills/` from the existing submodules:

| Role | Skills (← repos/) |
|------|-------------------|
| ceo-orchestrator | paperclip; taskmaster / project-manager |
| tech-lead | taskmaster (`openclaw/skills`); paperclip |
| product-manager | `deanpeters/Product-Manager-Skills` (PRDs, RICE, OKRs, discovery) |
| backend-dev | php (clawbot), mysql (`openclaw/skills`), backend-patterns |
| frontend-dev | `spillwave-astro` (publishing), `alirezarezvani` (landing), astro skill |
| qa-engineer | `jeffallan/test-master`, `anthropic/webapp-testing`, playwright |
| devops | `jeffallan` (devops-engineer, terraform, kubernetes), `gstack/land-and-deploy` |
| data-engineer | `mozilla-bq-etl`, afrexai-data-engineering, GA4 skill, Google Data Agent Kit |
| data-analyst | oyi77/data-analyst, biz-reporter |
| data-scientist *(new)* | `alirezarezvani/senior-data-scientist` |
| copywriter | jchopard69 copywriting + copy-editing, reef-copywriting, `robertbstillwell` |
| ad-copy | abm-ad-creative, google-ads-api, `sebclawops`, `mattberman-google-ads`/`meta-ads`, `nowork-toprank`, `amekala-ads-mcp` |
| growth-hacker | ivangdavila/growth-hacker, marketing-mode, marketing-skills, `robertbstillwell` |
| researcher *(added 2026-06-16)* | `deep-research` skill; web-search/fetch tools; `hesamsheikh` (usecases). External/desk research → cited synthesis |
| seo *(new)* | `nowork-toprank`, `jdevalk` astro-seo, marketing-mode SEO |
| security-reviewer *(new)* | `jeffallan/security-reviewer` + secure-code-guardian, `gstack/cso` |
| designer *(new)* | `anthropic` canvas-design/frontend-design/theme-factory, `gstack/design-review` |
| ALL (autonomous target) | paperclip (when target 3 is built; `paperclip: true`) |

## 4. Skills-population mechanism — DECISION NEEDED

`agent-factory/skills/` is empty; compose validation requires a named bolt-on skill
to exist there. Sources are already in `repos/`. Options:

- **(A) Symlink** `agent-factory/skills/<name>` → `repos/<repo>/.../<skill>`.
  Reuses upstream, no duplication, tracks upstream. Matches wire.sh's symlink model.
  **Recommended.**
- **(B) Copy** skill content in. Decouples from upstream but duplicates + drifts.
- **(C) Resolve-by-name** across `repos/` in `compose.py` (no `skills/` dir at all).
  Most flexible, but changes the validation contract + loses curation control.

Recommendation: **(A)** — a curated symlink library is the factory's "shared skills
dir", consistent with how OpenClaw wires skills by name.

## 5. Divergence flag

The research doc recommended **build in OpenClaw first, bind Paperclip second**.
This session built **Claude Code first** (Gareth's call). Revisit when picking up
delivery targets 1 (OpenClaw) and 3 (Paperclip-autonomous).

## 6. Sequencing (once 4 is decided)

1. Add the agreed new roles via the sub-agent port pipeline (off tech-lead/backend-dev exemplars).
2. Populate `agent-factory/skills/` per §3 using the chosen mechanism.
3. Update `examples/full-team.yaml` (+ new roles, + per-role `skills:`), re-emit, re-wire.
4. Update README/TODO.
