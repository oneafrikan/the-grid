```markdown
# {{ORCH_ROLE}} uses cron for all scheduled behaviour, not the OpenClaw heartbeat API.
# Keep this file empty (or with only comments) to skip heartbeat API calls.
```

<!--
Genuinely new for the grid, but the convention isn't: mirrors the exact
wording already used by scout's `coach` agent
(~/.openclaw/workspace-coach/HEARTBEAT.md) and Guide's
templates/specialist/HEARTBEAT.md. Agent-writable in the deployed workspace
(mode 664) per B2's file-permission scheme, and PRESERVED ON REGEN — session
B2/B3 must not overwrite a live agent's own heartbeat tasks with this scaffold
on redeploy.

Token filled by session B2's write_openclaw():
  {{ORCH_ROLE}} — machine role id, e.g. "tech-lead"
See openclaw/README.md for the full token list.
-->

## Related

- [Heartbeat config](/gateway/config-agents)
