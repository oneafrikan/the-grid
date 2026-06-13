<!--
  IDENTITY_base.md — the agent's nameplate (concrete bindings).
  This is a TOKEN TEMPLATE: compose.py substitutes {{tokens}} from role.yaml +
  the compose config, then appends roles/<role>/IDENTITY.md (also substituted).
  Distinct from SOUL.md (how it behaves) — IDENTITY is who it is, which model it
  runs, where it lives. Keep it a compact table. Modeled on the live OpenClaw
  agent format (SOUL/IDENTITY/AGENTS/USER/MEMORY).
-->

# {{name}}

| Field | Value |
|-------|-------|
| Name | {{name}} |
| Role | {{role}} |
| Primary model | {{model}} |
| Cron model | {{cron_model}} |
| Machine | <!-- [FILL] host this agent runs on --> |
| Operator | <!-- [FILL] who it answers to (see USER.md) --> |
| Channels | <!-- [FILL] Slack / Telegram / etc. --> |
