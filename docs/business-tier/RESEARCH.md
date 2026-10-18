# Research log — 2026-10-17

Four passes: Cowork extensibility, front-ends for Claude Code, build-your-own options, and a repo map. Mostly single-source (Anthropic docs). Effort figures in days are estimates, not sourced. Nothing here was tested hands-on.

## Cowork and plugins

| Claim | Confidence | Source |
|-------|-----------|--------|
| A plugin folder (skills, agents, commands, hooks, MCP) installs in Cowork and Claude Code unchanged; agents load in Cowork | high | https://claude.com/docs/plugins/platform-support |
| SKILL.md follows the open Agent Skills spec; `name` and `description` required | high | https://claude.com/docs/skills/how-to |
| Cowork delegation to plugin agents, and `tools:`/`model:` frontmatter handling, are undocumented | low-med | gap |
| A marketplace can sync from a private GitHub repo; plugin source paths limited; no top-level `bin/`; 200 MB cap | high | https://claude.com/docs/plugins/org-sync |
| Org plugins also sync into Claude Code terminals (v2.1.273+) | high | https://code.claude.com/docs/en/plugins/loading |
| Cowork does not read `~/.claude/skills`; skills must be plugins or account-enabled | med-high (two sources) | https://code.claude.com/docs/en/skills |
| Enterprise Cowork "has no option to run locally"; cloud sessions need Desktop open for local folders | med (single source, contradicts local-files goal) | https://support.claude.com/en/articles/15811196 |

## Desktop and other front-ends

- The Desktop Code tab is a GUI over Claude Code on macOS: loads `~/.claude/skills/`, shows subagents in a tasks pane, installs plugins (+ > Plugins). `~/.claude/agents` and CLAUDE.md loading not confirmed. https://code.claude.com/docs/en/desktop
- claude.ai/code and Claude in Slack/Tag run in cloud sandboxes and read only repo-committed `.claude/`, not `~/.claude`.
- Community GUIs reviewed (opcode, claudecodeui, Conductor, Crystal, ACP clients): no prebuilt Mac installer, Node/terminal needed, engineer-oriented, or dormant. Not a fit as shipped. Their auth is a grey area under the policy below.
- Codex app, Gemini CLI GUI, opencode desktop: wrong runtime.
- Orca: not researched (OQ-6).

## Policy constraint (primary source)

https://code.claude.com/docs/en/legal-and-compliance : third-party developers may not offer claude.ai login or route requests through subscription credentials for users. Allowed: an end user signing in to the unmodified Claude Code binary; an organisation's own API key. Applies to any language or framework.

## Build-your-own options (estimates)

| Option | Verdict |
|--------|---------|
| Plugin + private marketplace | strongest; 2-4 days (inferred) |
| Managed settings for distribution | useful; `extraKnownMarketplaces`, `enabledPlugins`, `autoUpdate` |
| Agent SDK local app | duplicates the Code tab; auth risk |
| Slack/Teams bot | Claude Tag exists (cloud sandbox, usage billing); custom bot needs an API key |
| MCP server exposing agents | weak: remote cannot see local files; agent-as-tool needs its own LLM call |
| Open WebUI / LibreChat | no Claude Code integration found; likely a trap |

## Repo map (the-grid)

- Private tier is a single hardcoded path: `GRID_PRIVATE_ROLES_DIR` / `~/.the-grid-private/roles` (`agent-factory/compose.py`, `role_dir()`).
- `deploy.py` pushes roles only and indexes only public `examples/*.yaml`.
- `compose.py` overwrites `projects/<name>/` wholesale; a multi-layer design needs a "layer missing, refuse" guard.
- On `next`, plugin-marketplace is built: `plugins/grid-core`, `plugins/grid-agents`, `plugins/bundles.json`, `docs/PLUGINS.md`. `main` is far behind `next`.

## Gaps (not verified)

- Cowork delegation, frontmatter handling, `/skill` invocation.
- Which plans get the Code tab; whether admins can disable it.
- Whether Cowork can write outside connected folders (matters for any self-install idea).
- Marketplace auto-update behaviour for third-party marketplaces.
- Private-marketplace add on a machine with no git credentials.
- Orca.
