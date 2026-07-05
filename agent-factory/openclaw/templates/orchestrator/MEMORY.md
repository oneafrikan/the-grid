<!--
Thin passthrough template. Session B2's write_openclaw() fills this from
compose.py's render_agent(agent)["MEMORY.md"] (existing _core/MEMORY_base.md +
role-layer merge) on FIRST generation only. See openclaw/README.md for the
token list.

Agent-writable in the deployed workspace (mode 664) per B2's file-permission
scheme, and PRESERVED ON REGEN — once a live agent has appended real memory,
re-running the deploy script must not clobber it with this template's
rendered content again (matches Guide's generate.sh regen contract).
-->
{{RENDERED_CONTENT}}
