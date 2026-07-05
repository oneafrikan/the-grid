<!--
Thin passthrough template. Session B2's write_openclaw() calls compose.py's
existing render_agent(agent)["IDENTITY.md"] (same function the claude-code
target already uses — no new merge logic here) and substitutes the result for
{{RENDERED_CONTENT}} below, verbatim. This file exists only so the openclaw
template set has a complete, browsable 9-file shape mirroring Guide's
templates/specialist/ — see openclaw/README.md for the full token list and
which files are real templates (BOOT/TOOLS/HEARTBEAT/EXPERTISE) vs. passthrough
(this one).

Per B2/roadmap docs, this file is regenerated from source every run and is
Gareth/engineer read-only in the deployed workspace (mode 440) — never
agent-writable, never hand-edited downstream.
-->
{{RENDERED_CONTENT}}
