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
