<!--
Thin passthrough template. Session B2's write_openclaw() fills this from
compose.py's render_agent(agent)["USER.md"] (existing _core/USER_base.md +
role-layer merge). See openclaw/README.md for the token list.

Gareth/engineer-editable in the deployed workspace (mode 644) per B2's
file-permission scheme — this is where a real Telegram binding, operator
notes, etc. get added post-deploy (session B3/B4), not regenerated away.
-->
{{RENDERED_CONTENT}}
