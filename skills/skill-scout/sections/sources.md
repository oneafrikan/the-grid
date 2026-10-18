## Sources

**Ranked directories** — already sorted by popularity, so we just read the
listing rather than calling any API:

- **skills.sh** — homepage leaderboard at <https://www.skills.sh/>. Shows skills
  ranked by installs (tabs: All Time / Trending (24h) / Hot). Use the **All Time**
  ranking unless the user asks for trending. Each row gives a skill name, an
  install count (e.g. "494.3K", "1.8M"), and an owner/repo (e.g. `vercel-labs/skills`).

- **mcp.directory** — leaderboard at <https://mcp.directory/skills/leaderboard>.
  Top 50 skills ranked by combined installs + views, server-rendered (one fetch
  returns the ranked list). Each row gives skill name, owner, installs, and views.
  Rank on installs; treat views as a tiebreaker only.

**Local library submodules** — checked out under `repos/`, so no network needed.
These are the-grid's *library* tier (indexed, not wired). Each is fair game to
scout for skills worth promoting to wired:

- **repos/voltagent**, **repos/sjkncs**, **repos/hesamsheikh** — awesome-list
  indexes (markdown link lists, often `categories/*.md`), pointing at clawskills.sh
  etc. **Not install-ranked** — browse-by-topic.
- **repos/clawhub** and the rest of the library tier — actual
  `SKILL.md` collections (sometimes 1000s). Grep their frontmatter locally for
  topics, then dedupe against what's already wired.
- Keep any of them fresh with `git submodule update --remote repos/<name>` before
  scouting. See `SKILLS.md` for the current library list + counts.

**Web directories** (OpenClaw / cross-ecosystem) — not git repos; fetch the page.
Most are JS-heavy app shells, so confirm each returns a usable listing before
relying on it, and prefer ones exposing install/popularity counts:

- clawhub.ai · skillsmp.com · playbooks.com/skills · lobehub.com/skills ·
  clawbot.ai/skills · explainx.ai/skills · llmbase.ai/openclaw · Agensi (paid).

<!-- Vetted but UNCONFIRMED candidates — verify each fetches cleanly (ranked list,
     not a JS-only shell or rate-limited stub) before promoting into the list above:
       - mcpmarket.com/tools/skills/leaderboard (install-ranked; was HTTP 429 when checked)
       - claudeskills.info/best/ and agent-skills.cc/claude-skills/hot (ranked by GitHub stars, not installs)
     Plain-text fallbacks (no install ranking, but trivially fetchable as raw README/JSON):
       - github.com/hesreallyhim/awesome-claude-code, github.com/VoltAgent/awesome-agent-skills
       - github.com/JSONbored/awesome-claude (ships a structured JSON registry)
     Only add a source if its listing is install- or popularity-ranked AND readable
     with a single fetch (no auth, not a JS-only shell). -->
