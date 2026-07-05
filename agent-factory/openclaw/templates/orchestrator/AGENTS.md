<!--
Thin passthrough template. Session B2's write_openclaw() fills this from
compose.py's render_agent(agent)["AGENTS.md"] — same content the claude-code
target already produces, including the generated {{ROSTER_TABLE}} roster of
this orchestrator's delegates_to (inject_roster() already handles this; no new
logic needed for the openclaw target). See openclaw/README.md for the token
list.

Gareth/engineer-editable in the deployed workspace (mode 644) per B2's
file-permission scheme — unlike IDENTITY/SOUL, this one is expected to pick up
direct edits over time (operating-rule tweaks) without a full recompose.
-->
{{RENDERED_CONTENT}}
