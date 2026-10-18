# Delegation gate

**Question (OQ-1):** when an orchestrator in a Claude Desktop surface hands work to
plugin-supplied subagents, does delegation actually happen, with the subagents'
own tools and model honoured?

Delegation is what makes the grid worth shipping: without it a plugin is a set of
single-thread prompts, which Cowork already offers. Everything past Phase 1 is
blocked on this.

## What is already known

- Claude Code (terminal) delegates to subagents. Control case. (Anthropic docs; high confidence.)
- The Desktop Code tab shows subagents in a tasks pane and installs plugins. (Anthropic docs; high.)
- Cowork loads `agents/*.md` from plugins. Whether it **delegates** to them, or honours `tools:`/`model:` frontmatter, is undocumented. (Single-source; low-med.)
- `docs/PLUGINS.md` flags that bare agent names in rosters may not resolve against namespaced plugin agents. Unverified.

## Definition of "delegation works"

| ID | Criterion | Evidence |
|----|-----------|----------|
| D1 | The orchestrator causes at least two distinct subagent invocations | Subagent entries visible in the UI or transcript |
| D2 | A subagent's `tools:` restriction is honoured | Probe: a tool-less agent cannot read the file |
| D3 | A reply from subagent 1 is passed to subagent 2 and composed into one answer | Final answer quotes a value only agent 1 could know |
| D4 | Plugin-namespaced agents resolve when the orchestrator names them | Run once with bare names, once namespaced |
| D5 | Works from a natural-language request, not only a slash command | Same task, typed plainly |

## Phase 1 — probe plugin (about 30 minutes, hand-built, throwaway)

A scratch private GitHub repo containing a marketplace and one plugin:

```
delegation-probe/
├── .claude-plugin/marketplace.json     # one plugin entry, relative source ./plugin
└── plugin/
    ├── .claude-plugin/plugin.json      # name: delegation-probe, version: 0.0.1
    ├── agents/probe-alpha.md           # tools: Read   -- reads the secret file
    ├── agents/probe-beta.md            # no tools      -- relays what alpha told it
    └── commands/probe.md               # orchestrator
```

- `probe-alpha`: frontmatter `tools: Read`. Instruction: read `probe-secret.txt` from the connected folder, reply `ALPHA: <contents>`.
- `probe-beta`: no tools. Instruction: reply `BETA: <the value you were handed>`. It cannot read the file, so it can only answer if alpha's reply was passed to it.
- `commands/probe.md`: "Delegate step 1 to probe-alpha. Delegate step 2 to probe-beta, passing alpha's reply. Do not read the file yourself. Report each agent's name and reply."
- `probe-secret.txt` in the connected folder holds a fresh random string the model has not seen.
- Validate the layout with `claude plugin validate --strict` before testing. The marketplace.json shape above is from memory of the spec; the validator is the check.

**Pass:** final answer contains `BETA:` plus the secret, and the UI shows two subagent invocations.
**Fail signals:** the orchestrator reads the file itself (no subagent entries), or beta reports it cannot see the value.

## Phase 2 — `research-brief` plugin (after Phase 1 passes; not built)

Realistic workload, built from the existing built agents (no new content):
`/start` (minimal router), `/brief` (orchestrator), a researcher agent (from
`core-researcher`), and a writer agent (`grid-copywriter` or `grid-technical-writer`).
Task: research a topic, produce a one-page brief as a docx. Exercises install,
skill invocation, two-agent delegation, and a document deliverable in one pass.

Chosen over SEO/PPC (need data connectors) and PM (needs project context) because
every persona can use it and it has no outward side effects.

## Mac checklist

Run each on: terminal (control), Code tab, Cowork. Record in the table.

1. Desktop shows both a Cowork tab and a Code tab for the logged-in user.
2. Add the scratch marketplace (UI, then by one plain sentence). Note whether git credentials are needed for a private repo (OQ-3).
3. Install `delegation-probe`.
4. Run `/delegation-probe:probe` with the secret file in the connected folder. Check D1-D3.
5. Repeat in plain language (D5).
6. Repeat with bare vs namespaced agent names in `probe.md` (D4).
7. Push a change to the marketplace repo; note whether and when the colleague side updates (OQ-4).
8. Ask Cowork to perform the install itself; note whether it can write outside connected folders.
9. Confirm Cowork does not read `~/.claude/skills` (reported by two sources).

## Results (fill in)

| Check | Terminal | Code tab | Cowork | Notes |
|-------|----------|----------|--------|-------|
| Both tabs present | n/a | | | |
| Marketplace add (private repo) | | | | |
| D1 two subagent invocations | | | | |
| D2 tools restriction | | | | |
| D3 handoff composed | | | | |
| D4 name resolution (bare / namespaced) | | | | |
| D5 natural language | | | | |
| Update propagation | | | | |
| Cowork self-install | n/a | n/a | | |
| docx output (Phase 2) | | | | |

## Decision tree

- **Cowork passes D1-D4:** Plan A. Cowork is the primary surface; the Code tab handles repo and code work.
- **Cowork fails D1, Code tab passes:** Plan B.
  - Cowork bundles ship orchestrators flattened into single-thread playbooks (needs a build flag).
  - Orchestrated work runs in the Code tab.
  - Raises the priority of the non-technical ADE (ADR-005), because the Code tab is the only delegating surface and is developer-flavoured.
- **Only D4 fails:** build orchestrators with namespaced agent names (a builder change); otherwise Plan A.
- **Code tab and terminal both fail D1:** stop; the probe is wrong. Debug the probe before concluding anything.
- **Plan C, independent of the above:** a non-technical ADE wrapping the unmodified Claude Code binary (ADR-005). It would deliver delegation by construction.
