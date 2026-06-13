---
name: skill-scout
description: >
  Scout public agent-skill directories (ranked by installs) and propose new
  skills to add to the-grid, deduped against what's already wired. Use when
  the user says "skill-scout", "find new skills", "what skills should I add",
  "propose skills", or invokes /skill-scout.
---

# skill-scout

Find popular Claude skills the-grid doesn't have yet, and propose them — ranked
by install count. **Propose only.** Never add submodules or run `wire.sh`; the
user adds skills via the-grid's normal flow (`git submodule add … && bash wire.sh`).

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
- **repos/leoyeai**, **repos/clawhub**, and the rest of the library tier — actual
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

## How to run

1. **Gather candidates.**
   - *Ranked web directories:* WebFetch each listing page and pull the ranked rows
     — skill name, popularity number (installs), and source `owner/repo`. Normalise
     install counts ("1.8M" → 1_800_000) so they sort.
   - *Local library submodules:* read them straight off disk — `categories/*.md`
     for awesome-list indexes, or grep `SKILL.md` frontmatter for real collections.
     These have no install count — keep them in a separate, unranked pile.

2. **Load what the-grid already has.** From the repo root (`GRID_DIR`, default the
   repo this skill lives in):
   - Root-level skills: top-level directories containing a `SKILL.md`.
   - Submodule skills: `repos/*/**/SKILL.md` (one or more skill dirs per submodule).
   - Read each skill's `name:` from its frontmatter. Also note the source repo of
     each submodule (`git config -f .gitmodules` or the `repos/<name>` path) so a
     match on **either skill name or source repo** counts as "already have it".

3. **Dedupe.** Drop any candidate whose skill name OR source repo the-grid already
   carries. Matching is case-insensitive; compare on the bare skill name
   (ignore `owner/` prefixes) and on the `owner/repo` source.

4. **Rank and propose.** Sort the ranked-directory survivors by install count,
   descending. Present the top ~15 as a table:

   | Skill | Installs | Source (owner/repo) | Why it fits the-grid |
   |-------|---------:|---------------------|----------------------|

   For "Why it fits", write one honest line covering fit for a developer workflow
   (dev workflow, debugging, git, planning, testing, infra/ops). If a candidate
   is a poor fit, say so plainly rather than inventing a reason — or omit it.

   Then, **separately**, surface a handful of relevant picks from the local index
   (`repos/voltagent`) grouped by category — no install column, since it isn't
   ranked. Flag that these are OpenClaw-ecosystem skills worth a manual look, not
   ranked recommendations.

5. **Hand off, don't act.** End with the exact commands the user would run to add
   any they pick, but **do not run them**:

   ```bash
   git submodule add <repo-url> repos/<name>
   git submodule update --init
   bash wire.sh
   ```

## Notes

- "Based on installs" means the directory's own popularity ranking — we don't
  recompute it. If a source has no popularity signal, it doesn't belong here.
- Skills already in the-grid via a submodule (e.g. `repos/anthropic/skills/*`,
  `repos/gstack/*`) must be deduped by **source repo** too — a popular skill from
  `vercel-labs/skills` is "new" only if that repo isn't already a submodule.
- Keep the proposal short and skimmable. The user decides; this skill only scouts.
