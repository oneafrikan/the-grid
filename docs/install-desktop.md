# Install on Claude Desktop

Step-by-step install for the Claude Desktop app: the Code tab and Cowork. The short version lives in [INSTALL.md](../INSTALL.md#claude-desktop-code-tab-and-cowork).

## Which route is yours?

| User type | Route | Gets |
|---|---|---|
| Terminal Claude Code user who wants everything | clone + `bootstrap.sh --with-agents` ([INSTALL.md](../INSTALL.md#install)) | all wired skills and agents |
| Desktop app, Code tab | the same install as the terminal, because it shares `~/.claude` | same |
| Claude Code, no clone | `claude plugin marketplace add oneafrikan/the-grid`, then install `grid-core` and `grid-agents` | plugin skills and agents |
| Desktop app, Cowork | Customize → Plugins → Manage marketplaces → add `oneafrikan/the-grid` → install `grid-core` and `grid-agents` → fresh Cowork session | `grid-core`: skills plus the orchestrators `gsd`, `grid-tech-lead`, `grid-ceo-orchestrator`, `grid-growth-hacker`; `grid-agents`: the specialist agents |
| Teams: colleagues who never use git | point at [docs/business-tier](business-tier/README.md): git users add the business repo as a marketplace; everyone else uploads one zip per skill under Customize → Skills | the business repo's skills |

Pick **one** route per surface:

- The clone install plus the plugins lists every agent twice.
- A plugin plus a zip of the same skill gives that skill twice.

## Claude Code (terminal and the Desktop Code tab)

The terminal and the Desktop app's Code tab share `~/.claude`, so one install
covers both. Detail: [PLUGINS.md](PLUGINS.md#claude-desktop-code-tab-and-cowork).

Pick **one** route per machine (see above).

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
2. In Customize → Plugins → Manage marketplaces, add `oneafrikan/the-grid`. It is
   public: no git credentials are needed.
3. Install `grid-core` and `grid-agents` from the plugin listing.
4. Start a fresh Cowork session.

Troubleshooting: if the plugins are missing from the listing although the marketplace
shows in Manage marketplaces (seen after the plugins had been uninstalled), remove the
marketplace there and add it again. The listing comes back.

Do not ask Cowork in chat to add the marketplace and install the plugins. That runs the
`claude` command-line tool inside Cowork's cloud sandbox and installs into that
throwaway container: nothing appears in Customize → Plugins and a fresh session has
nothing. Cowork's built-in `cowork-plugin-management` plugin cannot install from a
marketplace either.

New releases may need a marketplace refresh or a reinstall; auto-update in Cowork is
not verified.

A private marketplace (a GitHub repo the account can read) works in the Desktop app
with no extra credentials; see OQ-3 in [business-tier](business-tier/README.md).

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

## Skill zip uploads (colleagues without repo access)

- Upload under Customize → Skills → Upload skill, not Customize → Plugins.
- The Plugins upload rejects a skill zip: "Zip must contain a .claude-plugin/plugin.json file or a top-level SKILL.md declaring plugin components".
- Zip layout: one folder named after the skill, with `SKILL.md` inside. The folder name must match the skill's `name`.
- Do not also install the same skill as a plugin: it appears twice.

**Caveats:**

- Subagents work on copies staged into Cowork's cloud container; the results are
  written back to your folder.
- Write-back replaces the originals. Keep the folder under git or back it up first.
- Use the Code tab for git repos.
