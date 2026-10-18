# Business tier — spec

Status: agreed design, unbuilt. Items marked **[unverified]** come from research
or inference and are what the Mac pilot tests. See [RESEARCH.md](RESEARCH.md).

## 1. Principle

- **The grid is the factory. A business repo is the product.**
- Agents and roles come from the public grid. They are **not** copied or forked into the business repo.
- The business repo holds what is specific to that business: context, business-only skills and templates, and which grid pieces go in which bundle.
- Anyone using the-grid can cut their own business repo the same way.

Tiers: public (`the-grid`) < business (`the-grid-<business>`) < private (`the-grid-private`).
Colleagues get public + business only. The private tier is the operator's.

## 2. End-to-end user journey

**A. One-off setup (maintainer, terminal)**
1. Cut `the-grid-<business>` from a business template (project-factory; template not yet written).
2. Pin the public grid version (`grid.pin`).
3. Write `context/` and `bundles.json`.
4. Push to private GitHub; CI builds the plugins and `marketplace.json`.

**B. Colleague onboarding (target: about 2 minutes)**
1. Claude Desktop is installed and logged in (assumed; plan tiers are out of scope).
2. Open Cowork or the Code tab.
3. One sentence: "Add the marketplace github.com/<org>/the-grid-<business> and show me what is available." **[unverified]** Fallback: the Plugins UI (+ > Plugins).
4. Tick the bundles wanted (job-shaped: SEO, PPC, content, product management, analyst).
5. Run `/start` (front door), say what the job is, get pointed to the right bundle.
6. Connect a working folder.

**C. Daily use**
1. Ask in plain language, or run a slash command.
2. The orchestrator runs a playbook and delegates to specialist agents.
3. Output lands in the connected folder (docx, xlsx, md, pdf).
4. Anything outward-facing (spend, publishing) waits for human approval, as the role contracts already require.

**D. Updates:** maintainer pushes; CI rebuilds; colleagues receive the update next session or after one click **[unverified]**.

**E. Terminal users:** same repo, same plugins via `claude plugin ...`, or wire it with `wire.sh`.

## 3. Repo architecture

```
the-grid-<business>/
├── .claude-plugin/marketplace.json     # GENERATED catalogue of bundles
├── plugins/<business>-<bundle>/        # GENERATED: grid agents/skills + this business's context
│   ├── .claude-plugin/plugin.json
│   ├── agents/  skills/  commands/  (.mcp.json)
├── context/                            # SOURCE: voice, glossary, audiences, tool stack, policies, templates
├── skills/                             # SOURCE: business-only skills (house style, report templates)
├── bundles.json                        # which grid roles/skills + which context go in which bundle
├── grid.pin                            # public-grid commit the build used
├── .github/workflows/build.yml         # checkout grid@pin, compose, build, commit plugins/
└── README.md  START-HERE.md  CLAUDE.md  TODO.md
```

- Build flow: `bundles.json` + `context/` + business `skills/` + the pinned grid -> CI -> `plugins/` + `marketplace.json`.
- Colleagues only ever see built output. No `compose.py`, no venv, no private tier.
- Plugins are named for the business and bundle, but the agents inside are grid roles with business context applied.
- Build agents with the lean profile (role judgement, scope, procedure; no persona or memory boot) to protect context budget.
- The public grid already has the machinery: `scripts/build-plugins.py`, `plugins/bundles.json`, `docs/PLUGINS.md`. The business build is a second consumer. Expected changes (inferred, builder not yet read): accept a bundles file and output dir outside the grid, compose from a pinned checkout, and apply context (OQ-2).
- Layering now applies mainly to **context** (public < business < private). Role overrides via an ordered roles-dir list remain possible but are no longer the primary mechanism.

### OQ-2: how business context reaches the agents

| Option | How | For | Against |
|--------|-----|-----|---------|
| a. Read-first skill | Bundle ships a `<business>-context` skill; agent boot sequence says "if present, read it first" (precedent: the SPECS.md boot check in `agent-factory/_core/AGENTS_base.md`) | Small, conditional, no per-agent duplication | Relies on the model following the boot step |
| b. Build-time injection | Builder appends a context block to every bundled agent | Deterministic | Duplicates text into every agent; context cost; builder complexity |

Leaning (a), with (b) as fallback if the pilot shows agents skip the boot step. Decide after the delegation gate.

## 4. The Claude flow

```
colleague message
  -> Claude matches a plugin skill/command by its description
  -> loads that playbook (descriptions load first, bodies on demand)
  -> orchestrator delegates to specialist agents          <- THE GATE (OQ-1)
  -> agents read/write the connected folder, use connectors if any
  -> first-party docx/xlsx/pdf skills render the deliverable
  -> result + sources + assumptions; approval asked for outward actions
```

- Naming: plugin skills are `/plugin:skill`, agents are `plugin:agent`. Orchestrator rosters name agents bare; resolution is unverified (OQ-5, noted in `docs/PLUGINS.md`).
- Fallback if Cowork will not delegate: build orchestrators as single-thread playbooks (see DELEGATION-GATE).

## 5. What the end user gets

- A front door (`/start`) that takes plain language and recommends a bundle.
- 5-6 job-shaped bundles, each with a few plainly named commands backed by named specialists.
- Deliverables as real files in their folder. Doc creation and conversion are probably covered by first-party docx/pdf/pptx/xlsx skills **[unverified in Cowork]**.
- Evidence-first outputs (sources, assumptions, stated gaps) and human approval for outward actions.
- Updates without running commands **[unverified]**.
- Not included: terminal, Python, the private tier, the engineering team unless that bundle is chosen, autonomous loops.

## 6. How they use it

1. Ask: "Research how competitors position X and give me a one-page brief."
2. Slash: `/brief`, `/seo-audit`.
3. Front door: `/start`, "I'm a PPC manager", then it suggests the PPC bundle.
4. Code tab: repo or code work.
5. Optional later: `/feedback` files an issue on the business repo.

## 7. Out of scope (for now)

- Any custom UI (see DECISIONS ADR-005 for the long-term direction).
- Touching how Claude plan tiers work.
- Non-Claude runtimes (low adoption; the multi-harness work in the uplift covers them separately).
