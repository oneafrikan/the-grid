# Decisions log

Format: status, date, decision, why, consequences. Add; do not rewrite history. Mark a superseded entry and link the new one.

## ADR-001 — Plugin route first (accepted, 2026-10-18)

- **Decision:** deliver the grid to non-terminal colleagues as Claude Code plugins distributed from a private git marketplace, consumed in Claude Desktop (Cowork and Code tab).
- **Why:** plugins install in Cowork, the Code tab and the terminal from one artefact; the public grid already builds two plugins; no new UI to maintain.
- **Consequence:** gated on the delegation question (DELEGATION-GATE).

## ADR-002 — Agents come from the grid; the business repo holds context (accepted, 2026-10-18)

- **Decision:** the business repo contains business context, business-only skills/templates and bundle definitions. It does **not** contain its own agents or roles.
- **Why:** business-named agents would be near-duplicates of grid roles and would drift. Operator correction after an earlier draft proposed `roles/` in the business repo.
- **Consequence:** the role-layering change (an ordered roles-dir list) is no longer the primary mechanism; layering applies to context. #274 updated to match. Context delivery mechanism is OQ-2.

## ADR-003 — CI builds; colleagues consume built output (accepted, 2026-10-18)

- **Decision:** `compose.py` and the plugin builder run in CI against a pinned grid checkout. Colleagues install built plugins only.
- **Why:** removes git, Python and venv from non-technical machines. Matches the design of `scripts/build-plugins.py` (generated, committed, drift-checked).

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

## ADR-007 — Plan tiers are out of scope (accepted, 2026-10-18)

- **Decision:** assume colleagues have Claude Desktop installed and are logged in. The design does not depend on or alter how Claude plan tiers work.
- **Caveat:** research reported that Enterprise Cowork may be cloud-only and Team has no group scoping. These are noted in RESEARCH.md, not designed around.

## ADR-008 — Surface split: Cowork for cloud work, Code tab for local work, business tier single-thread (accepted, 2026-11-05)

- **Decision (operator):** "anything that runs in the cloud can be done in Cowork; the business tier should ship business-wide single-thread skills; Cowork ships the full agent army." Interpreted as:
  - **Cowork:** cloud-side work (research, drafting, docs, connectors). The full the-grid plugins (`grid-core` + `grid-agents`) are installed there.
  - **Business tier** (`the-grid-<business>` plugin for colleagues): business-wide single-thread skills only. No dependence on subagent delegation.
  - **Code tab:** local file and repo work. It reads the wired `~/.claude`, delegates to subagents and sees the local folder.
- **Why (DELEGATION-GATE results, 2026-11-05, macOS):**
  - Cowork: one subagent invocation by namespaced name (`grid-agents:grid-qa-engineer`) ran, so delegation to plugin agents works. Its tools ran in Cowork's cloud container, which cannot see the folder connected on the Mac.
  - Code tab: a bare-name subagent (`grid-qa-engineer`) ran and listed the connected folder's files. The namespaced name failed because no plugin is installed there.
- **OQ-1 answered for Cowork:** delegation works, local file access does not. Two-agent runs (D1 full), D2, D3 and D5 are still untested; this decision does not depend on them.
- **Consequences:**
  - Plan B in the decision tree (flattened orchestrators for Cowork) is not needed for the full grid; only the business-tier skills are single-thread.
  - Orchestrated work on local files runs in the Code tab.
  - The ADR-005 interaction clause (ADE as main path if Cowork cannot delegate) is not triggered; ADR-005 stays open as a long-term direction.
  - Still untested: OQ-3 (private marketplace credentials), OQ-4 (update propagation), Cowork self-install, docx output.
