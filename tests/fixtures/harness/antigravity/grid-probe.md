---
name: grid-probe
description: Test fixture from the-grid. Hand-written, not composed; confirms agy scans ~/.gemini/config/agents/ and that wire.sh leaves real files there alone. Do not delete.
subagent: true
mainAgent: false
tools: [read_file]
---
You are a probe agent. If invoked, reply with exactly: "grid-probe alive".
