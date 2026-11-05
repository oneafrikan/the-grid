# Decisions log

Format: status, date, decision, why, consequences. Add; do not rewrite history. Mark a superseded entry and link the new one.

## ADR-001 — Plugin route first (accepted, 2026-10-18)

- **Decision:** deliver the grid to non-terminal colleagues as Claude Code plugins distributed from a private git marketplace, consumed in Claude Desktop (Cowork and Code tab).
- **Why:** plugins install in Cowork, the Code tab and the terminal from one artefact; the public grid already builds two plugins; no new UI to maintain.
- **Consequence:** gated on the delegation question (DELEGATION-GATE).
- **Update 2026-11-05:** gate answered (ADR-008). For v0 the grid-bundled-plugins part is deferred by ADR-009.

## ADR-002 — Agents come from the grid; the business repo holds context (accepted, 2026-10-18)

- **Decision:** the business repo contains business context, business-only skills/templates and bundle definitions. It does **not** contain its own agents or roles.
- **Why:** business-named agents would be near-duplicates of grid roles and would drift. Operator correction after an earlier draft proposed `roles/` in the business repo.
- **Consequence:** the role-layering change (an ordered roles-dir list) is no longer the primary mechanism; layering applies to context. #274 updated to match. Context delivery mechanism is OQ-2.

## ADR-003 — CI builds; colleagues consume built output (accepted, 2026-10-18)

- **Decision:** `compose.py` and the plugin builder run in CI against a pinned grid checkout. Colleagues install built plugins only.
- **Why:** removes git, Python and venv from non-technical machines. Matches the design of `scripts/build-plugins.py` (generated, committed, drift-checked).
- **Update 2026-11-05:** deferred for v0 by ADR-009 (no builder, no CI). Colleagues still consume built output: `scripts/package.sh` output, committed.

## ADR-004 — The private tier is not part of a colleague install (accepted, 2026-10-18)

- **Decision:** colleagues get public + business. Terminal-friendly staff may add the private tier themselves.

## ADR-005 — A non-technical ADE stays a long-term direction (open, 2026-10-18)

- **Direction (operator):** an agentic development environment in the spirit of Orca, designed for the needs of non-technical people rather than developers.
- **Earlier position (recorded, not adopted):** a research pass recommended deferring Portal (#241) in favour of plugins, and a comment saying so was posted on #241. The operator disagrees that a purpose-built environment is unnecessary.
- **Constraint found:** Anthropic's legal and compliance page says third-party products may not offer claude.ai login or route requests through users' subscription credentials. It allows an end user signing in to the unmodified Claude Code binary with their own subscription, and an organisation using its own API key. So the compliant shape is a shell that launches the unmodified Claude Code binary, not an Agent SDK app using subscription login. The constraint is language-independent.
- **Interaction with the gate:** if Cowork cannot delegate (Plan B), this becomes the main delivery path, because Claude Code does delegate.
- **Open:** OQ-6, evaluate Orca. Not yet looked at. #241 stays open; its first-pass comment should be softened to match this entry.

## ADR-006 — Pilot order: probe first, `research-brief` second; neither built yet (accepted, 2026-10-18)

- **Decision:** the first hand-built artefact is the throwaway delegation probe, then `research-brief`. Building is deferred; the operator runs the pilot on a Mac.
- **Why:** delegation is the deciding question and the probe answers it in about 30 minutes.
- **Update 2026-11-05:** the pilot order for the first artefacts is superseded by ADR-009 (v0 started with two other skills; `research-brief` is not built).

## ADR-007 — Plan tiers are out of scope (accepted, 2026-10-18)

- **Decision:** assume colleagues have Claude Desktop installed and are logged in. The design does not depend on or alter how Claude plan tiers work.
- **Caveat:** research reported that Enterprise Cowork may be cloud-only and Team has no group scoping. These are noted in RESEARCH.md, not designed around.

## ADR-008 — Surface split: Cowork for cloud work, Code tab for local work, business tier single-thread (accepted, 2026-11-05)

- **Decision (operator):** "anything that runs in the cloud can be done in Cowork; the business tier should ship business-wide single-thread skills; Cowork ships the full agent army." Interpreted as:
  - **Cowork:** cloud-side work (research, drafting, docs, connectors). The full the-grid plugins (`grid-core` + `grid-agents`) are installed there.
  - **Business tier** (`the-grid-<business>` plugin for colleagues): business-wide single-thread skills only. No dependence on subagent delegation.
  - **Code tab:** local file and repo work. It reads the wired `~/.claude`, delegates to subagents and sees the local folder directly.
- **Why (DELEGATION-GATE results, 2026-11-05, macOS; Cowork details self-reported, one run):**
  - Cowork: `/gsd` made 3 subagent calls by namespaced name (`grid-agents:grid-technical-writer` twice in parallel, then `grid-agents:grid-qa-engineer`); none failed. The roster names specialists bare; the orchestrator passed the namespaced names itself.
  - Cowork files: subagent tools run in Cowork's cloud container, which cannot reach the folder connected on the Mac. The main session can (through the linked computer): it copied the files into the container, subagents worked on the copies, and the main session wrote the results back. Write-back replaced the originals in place.
  - Code tab: a bare-name subagent (`grid-qa-engineer`) ran and listed the connected folder's files. The namespaced name failed because no plugin is installed there.
- **OQ-1 answered:** Cowork delegates. Subagents work in the cloud container on files the main session copies in, and results are written back to the Mac. D2 and D5 are still untested, D3 is partial; this decision does not depend on them.
- **OQ-5 answered for Cowork:** namespaced names resolve and the orchestrator mapped its bare roster names itself. A bare name passed directly to a plugin agent is untested.
- **Consequences:**
  - Plan B in the decision tree (flattened orchestrators for Cowork) is not needed. No builder change is required now. Namespacing roster names in the Cowork bundles stays an optional hardening step if a later run fails.
  - Cowork is viable for orchestrated local-file work by staging, but write-back replaces originals in place: keep the folder under version control or back it up first.
  - The Code tab stays the route for git repos and worktrees (Cowork's container has no access to the Mac's git checkout).
  - The business-tier skills are single-thread either way.
  - The ADR-005 interaction clause (ADE as main path if Cowork cannot delegate) is not triggered; ADR-005 stays open as a long-term direction.
  - Still untested: OQ-3 (private marketplace credentials), OQ-4 (update propagation), Cowork self-install, docx output.

## ADR-009 — Business tier v0: plain repo, marketplace for git users, zip upload for everyone else (accepted, 2026-11-05)

- **Decision (operator):** build the business repo as the simplest thing that works. It supersedes the builder-first plan (ADR-002/ADR-003 as the v0 path); ADR-008 still sets the surface split (business tier is single-thread skills).
  - **Repo:** a private repo in the business's own GitHub org (`the-grid-<business>`). The org is on the Team plan, so there is no "internal" visibility; per-team read access is to be arranged with the org admin.
  - **No builder, no CI, nothing composed from the grid.** Layout:
    - `.claude-plugin/marketplace.json` lists one plugin.
    - Skills live in `plugins/<plugin>/skills/<name>/`: `SKILL.md`, plus optional `references/` and `assets/`.
    - `scripts/package.sh` builds `dist/<name>/`: the `SKILL.md` plus ONE zip of the whole skill folder (assets included). Reproducible, committed.
  - **Two install routes:**
    - People with git access to the org add the repo as a plugin marketplace (`claude plugin marketplace add <org>/<repo>`; in Cowork, from its plugin settings) and install the plugin.
    - Everyone else downloads `dist/<name>/<name>.zip` and uploads it in Claude > Customize > Skills. If the upload rejects the assets, they unzip it, upload the skill, and add the assets into the chat.
  - **First skills:** two self-contained ones, a house email-style skill and a PowerPoint brand-guide skill that bundles its template and assets.
- **Why:** smallest footprint that gets skills to colleagues now. The zip route needs no git, no terminal and no plugin install. The marketplace route covers the people who do have org access.
- **Deferred, not planned now:**
  - the builder that composes bundles from a pinned grid (`grid.pin`, `bundles.json`);
  - layering business context into grid roles (OQ-2);
  - the project-factory business-repo template;
  - CI on the business repo.
- **Consequences:**
  - OQ-3 (private marketplace credentials) answered for accounts with org access (operator-run, 2026-11-05, Claude Desktop on macOS): a private org repo added as a marketplace needed no extra credentials, the plugin synced, and the Plugins page showed the skill with all its files including assets (a .pptx and images). A "Try in Cowork" action was offered. It only matters to the git-access route.
  - Still untested: that Customize > Skills accepts a skill zip with assets, used by a colleague without repo access (the fallback above is the workaround); whether the skill uses its bundled assets when building in Cowork; update propagation (OQ-4); and per-team access (needs the org admin).
