<!--
Thin passthrough template. Session B2's write_openclaw() calls compose.py's
existing render_agent(agent)["IDENTITY.md"] (same function the claude-code
target already uses — no new merge logic here) and substitutes the result for
<!--
  IDENTITY_base.md — the agent's nameplate (concrete bindings).
  This is a TOKEN TEMPLATE: compose.py substitutes {{tokens}} from role.yaml +
  the compose config, then appends roles/<role>/IDENTITY.md (also substituted).
  Distinct from SOUL.md (how it behaves) — IDENTITY is who it is, which model it
  runs, where it lives. Keep it a compact table. Modeled on the live OpenClaw
  agent format (SOUL/IDENTITY/AGENTS/USER/MEMORY).

  your-machine// come from this install's local
  agent-factory/user.yaml (gitignored, per-person/per-machine — not a project
  config), not from role.yaml or the compose config. See user.yaml.example.
-->

# Fixture growth-hacker

| Field | Value |
|-------|-------|
| Name | Fixture growth-hacker |
| Role | Fixture growth-hacker |
| Primary model | sonnet |
| Cron model | haiku |
| Machine | your-machine |
| Operator |  |
| Channels |  |
 below, verbatim. This file exists only so the openclaw
template set has a complete, browsable 9-file shape mirroring the earlier factory's
template set — see openclaw/README.md for the full token list and
which files are real templates (BOOT/TOOLS/HEARTBEAT/EXPERTISE) vs. passthrough
(this one).

Per B2/roadmap docs, this file is regenerated from source every run and is
Operator/engineer read-only in the deployed workspace (mode 440) — never
agent-writable, never hand-edited downstream.
-->
<!--
  IDENTITY_base.md — the agent's nameplate (concrete bindings).
  This is a TOKEN TEMPLATE: compose.py substitutes {{tokens}} from role.yaml +
  the compose config, then appends roles/<role>/IDENTITY.md (also substituted).
  Distinct from SOUL.md (how it behaves) — IDENTITY is who it is, which model it
  runs, where it lives. Keep it a compact table. Modeled on the live OpenClaw
  agent format (SOUL/IDENTITY/AGENTS/USER/MEMORY).

  your-machine// come from this install's local
  agent-factory/user.yaml (gitignored, per-person/per-machine — not a project
  config), not from role.yaml or the compose config. See user.yaml.example.
-->

# Fixture growth-hacker

| Field | Value |
|-------|-------|
| Name | Fixture growth-hacker |
| Role | Fixture growth-hacker |
| Primary model | sonnet |
| Cron model | haiku |
| Machine | your-machine |
| Operator |  |
| Channels |  |

