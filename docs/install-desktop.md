# Install on Claude Desktop

Step-by-step install for the Claude Desktop app: the Code tab and Cowork. The short version lives in [INSTALL.md](../INSTALL.md#claude-desktop-code-tab-and-cowork).

## Claude Code (terminal and the Desktop Code tab)

The terminal and the Desktop app's Code tab share `~/.claude`, so one install
covers both. Detail: [PLUGINS.md](PLUGINS.md#claude-desktop-code-tab-and-cowork).

Pick **one** route per machine. Doing both lists every agent twice.

**Route 1, full (clone):** follow [Install](../INSTALL.md#install) in INSTALL.md (`bootstrap.sh`, or
`wire.sh`). Skills are live immediately.

**Route 2, no clone (plugins):**

1. Open a terminal.
2. Add the marketplace:
   ```bash
   claude plugin marketplace add oneafrikan/the-grid
   ```
3. Install the two plugins:
   ```bash
   claude plugin install grid-core@the-grid
   claude plugin install grid-agents@the-grid
   ```
4. Start a new Claude Code session so they load.

**Verify:**

1. Open the Desktop app's Code tab (or run `claude` in a terminal).
2. Ask: "what skills and sub-agents do you have".
3. You should see `grid-*` and `core-*` agents listed (Route 2 shows the `grid-agents`
   ones with a `grid-agents:` prefix).

**Code tab facts:** it delegates to subagents by bare name (for example
`grid-qa-engineer`) and sees the local folder directly. It is the route for git
repos and worktrees.

## Claude Cowork (Desktop app)

Cowork does not read `~/.claude`, so `wire.sh` does nothing for it. It gets the
grid only from plugins installed in Cowork. Detail:
[PLUGINS.md](PLUGINS.md#claude-desktop-code-tab-and-cowork).

1. Open the Claude Desktop app and switch to Cowork.
2. In Cowork's plugin settings, add the marketplace `oneafrikan/the-grid`. It is
   public: no git credentials are needed.
3. Install `grid-core` and `grid-agents`.
4. Fallback that worked: ask Cowork in chat to add the marketplace and install both
   plugins.

Optional third-party skills: add the upstream marketplaces listed in
[PLUGINS.md](PLUGINS.md#claude-desktop-code-tab-and-cowork) the same way.
`garrytan/gstack`, `HubSpot/agent-cli-skills` and `Fission-AI/openspec` have no
marketplace and cannot be installed in Cowork this way.

**Verify:**

1. Start a fresh Cowork session.
2. Ask what skills and sub-agents it has.
3. You should see the `grid-core` skills and the four orchestrator skills (`gsd`,
   `grid-tech-lead`, `grid-ceo-orchestrator`, `grid-growth-hacker`). Plugin agents are
   not listed there, but the orchestrators call them by `grid-agents:` name.

**Caveats:**

- Subagents work on copies staged into Cowork's cloud container; the results are
  written back to your folder.
- Write-back replaces the originals. Keep the folder under git or back it up first.
- Use the Code tab for git repos.
