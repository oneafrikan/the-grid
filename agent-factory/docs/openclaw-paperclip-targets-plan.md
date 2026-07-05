# Deploy grid agents into OpenClaw and Paperclip as real working agents

## Context

the-grid's `agent-factory` already composes role definitions (identity + skills + org
topology) into a working Claude Code target — `compose.py --target=claude-code` renders
each role, `wire.sh` symlinks the output live. Two more targets were always the intended
next step (README: "OpenClaw + Paperclip targets... deferred"; TODO.md issues #3/#4) but
never built.

Goal: give two curated, hand-picked sets of grid roles a real, working existence in each
runtime — not a full-roster port, and not a live sync between the two runtimes. Each
target is a **one-way compile-and-deploy**, same relationship compose.py already has with
Claude Code: the-grid stays the single source of truth; a renderer produces target-shaped
output; a deploy step makes it live in that runtime.

**Scope, fixed by conversation:**
- **OpenClaw** (the messaging surface Gareth works from directly) gets the **5 orchestrator
  roles**: `ceo-orchestrator`, `tech-lead`, `finance-manager`, `growth-hacker`,
  `product-manager`. These already have (or, for product-manager, can trivially get) their
  specialist reports wired as local Claude Code subagents (via the existing `project:grid`
  compose + `wire.sh`) — an OpenClaw orchestrator delegates to them through OpenClaw's
  existing ACP subagent mechanism (`subagents.allowAgents`), not through Paperclip. No new
  delegation plumbing needed for that part.
- **Paperclip** gets the **dev team + growth arm**: `ceo-orchestrator` + `tech-lead` +
  tech-lead's 10 specialist reports (`backend-dev`, `frontend-dev`, `designer`,
  `qa-engineer`, `security-reviewer`, `devops`, `data-engineer`, `data-scientist`,
  `researcher`, `project-manager`) + `growth-hacker` + growth-hacker's own specialist
  reports (its "marketing arm" — confirm exact list from `growth-hacker`'s
  `delegates_to` in `agent-factory/examples/grid.yaml` during Session A1; known
  candidates: `ad-copy`, `copywriter`, `paid-search`, `paid-social`, `seo`). Same logic
  applied consistently: an orchestrator's full report branch comes with it. `finance-manager`
  and `product-manager` are explicitly **out of scope** for Paperclip this phase (separate
  initiatives — finance desk / product — can be added the same way later, same mechanism).

Two independent deliverables. No adapter layer, no Paperclip↔OpenClaw skill sync.

**OpenClaw design model: mirror the Guide pattern, don't invent one.** Gareth already runs
a mature, battle-tested agent-factory for OpenClaw at `~/Guide/guide-core/agent-factory`
(the guide-server project — a different machine, same OpenClaw software). It has a proven
roster/template/generate/register/test workflow, with real bug fixes behind its design
choices (e.g. file-permission scheme, EXPERTISE.md preservation-on-regen). The grid's
OpenClaw target should be that same pattern, adapted — not a fresh design built up from
OpenClaw primitives.

**Execution model:** this plan is implemented by grid specialist subagents (via the `Agent`
tool), one session/chunk at a time — not built end-to-end in one sitting by whoever picks
this up. Each session below names the specialist and has a standalone definition of done.
Sessions are ordered; later ones depend on earlier ones as noted.

## Paperclip storage model: DB vs disk (verified 2026-07-05)

Read `paperclip/src/server/src/services/agent-instructions.ts` and
`company-skills.ts` directly to confirm this — don't assume it holds after
upstream changes. Also documented in `~/paperclip/CLAUDE.md`.

- **Agent instructions bundle** (`AGENTS.md`, `SOUL.md`, etc.) is **disk-first**.
  Postgres only stores pointers in `adapterConfig`
  (`instructionsRootPath`/`instructionsEntryFile`/`instructionsBundleMode`).
  The actual file content lives at
  `<PAPERCLIP_HOME>/instances/<instanceId>/companies/<companyId>/agents/<agentId>/instructions/`
  — real `fs.readFile`/`writeFile`, confirmed in `agent-instructions.ts`. This
  is what `GET/PUT /api/agents/{id}/instructions-bundle/file` reads and writes.
  A hire's `instructionsBundle.files` payload materializes straight to these
  files at hire time (proven live — see Session A3 log).
- **Company skills** are **DB-first**. Canonical content lives in Postgres,
  `companySkills` table (Drizzle ORM) — markdown is a column, not a file
  reference. `POST /companies/{id}/skills` just inserts a row. Skills are
  materialized to disk **on demand** (first heartbeat, or on-demand fetch) at
  `<PAPERCLIP_HOME>/instances/<instanceId>/skills/<companyId>/__runtime__/<skill>/`
  — confirmed via `resolveManagedSkillsRoot()` / `materializeRuntimeSkillFiles()`.
- **`PAPERCLIP_HOME`** resolves to `~/.paperclip` by default, but scout's
  Docker deployment sets it to `/paperclip` inside the container, bind-mounted
  from `/home/gareth/paperclip/data/docker-paperclip` on the host — so on
  scout, the real host-side instructions path is
  `/home/gareth/paperclip/data/docker-paperclip/instances/default/companies/<companyId>/agents/<agentId>/instructions/`.
- **Practical implication for `deploy_paperclip.py`**: the existing-agent 403
  blocker (item #1 in the 2026-07-05 handoff) only affects the *disk-backed*
  instructions-bundle PUT — it has no bearing on the DB-backed skills sync
  path, which already works via the agent API key with no board auth needed.

## What's reusable vs. what's genuinely new

From investigation (`agent-factory/compose.py`, `paperclip/src`, `~/.openclaw`,
`~/Guide/guide-core/agent-factory`):

- **compose.py's input model is already target-agnostic**: `load_config()`, `render_agent()`
  (the 5-file SOUL/IDENTITY/AGENTS/USER/MEMORY merge), `agent_skills()`, `role_meta()`,
  roster-table injection, model resolution — all reusable unchanged by new targets.
- **OpenClaw rendering is basically already done.** Today's default `--target` (no explicit
  name, i.e. "not claude-code") already emits the real 5-file identity model per role,
  unflattened, to `projects/<name>/<role>/*.md` — this is exactly the content an OpenClaw
  workspace needs. The gap is entirely the **deploy** half: nothing registers those files
  into a live `~/.openclaw` workspace/agent/config.
- **Paperclip has neither renderer nor deploy today** — both need building. But the API
  surface is well-understood and already proven live: 3 agents exist right now in a
  dormant company "Cogniskeleton" (`58077af9-…f93a`), created via exactly the mechanism
  this plan will script (`POST /agent-hires`), one (`Guide-Main`) built from a hand-written
  payload as a working precedent.
- Confirmed via code: **Paperclip skill content can be pushed as raw markdown** —
  `POST /api/companies/:companyId/skills` takes `{name, slug, description, markdown}`
  directly; the server writes it to its own managed skills dir. No shared filesystem or
  container mount between the-grid and the Paperclip container is required.
- Confirmed via code: **instructionsBundle is a `files: {filename: content}` map**, not a
  single blob — so the unflattened 5-file `render_agent()` output maps onto it directly,
  no flattening step needed (unlike the Claude Code target, which does flatten).
- Guide's `agent-factory` already solves the OpenClaw registration problem end to end for a
  different roster: `roster.json` (status lifecycle) + `roles/*.env` + `templates/<type>/*.md`
  + `generate.sh` (regenerate-without-clobbering-agent-state) + `ADD-AN-AGENT.md` (the
  register/bind/allowlist/test runbook). The grid's OpenClaw target ports this shape,
  swapping the config source (role.yaml instead of `.env`) and messaging surface (Telegram
  instead of Slack).

## Sessions

### Session 0 — Persist this plan into the-grid repo

**Specialist:** none needed — administrative. Do directly or via `grid-project-manager`.

- Write this document to `agent-factory/docs/openclaw-paperclip-targets-plan.md`.
- Add a one-line pointer to it from `agent-factory/README.md`'s "remaining work" section and
  the-grid's root `TODO.md` (next to issues #3/#4).
- Commit + push. This makes the plan durable and discoverable independent of any Claude Code
  session's local plan-file storage.
- **Done when:** the doc exists in the repo, is committed, and is linked from README/TODO.

### Session A1 — Paperclip renderer (`compose.py --target=paperclip`)

**Specialist:** `grid-backend-dev`. **Depends on:** Session 0.

- Add `write_paperclip(config, project_dir, slug)` to `compose.py`, parallel to
  `write_claude_code()`. Pure rendering, no network calls.
- Confirm `growth-hacker`'s actual `delegates_to` list from `agent-factory/examples/grid.yaml`
  (or wherever the real compose-config for this rollout lives) — lock the exact 13+N-agent
  roster for Paperclip before building payloads.
- Per agent: `name`, `title` (`role.yaml`), `capabilities` (role summary), `adapterType:
  "claude_local"`, `instructionsBundle.files` = unflattened 5-file dict from
  `render_agent(agent, slug=slug)` (`entryFile: "AGENTS.md"`), `desiredSkills` from
  `agent_skills(agent)`, `reportsTo` = parent **role name** (placeholder, resolved to a UUID
  at deploy time).
- Output: `projects/<name>/_paperclip/manifest.json`, topologically ordered (parents before
  children). Sibling to `_claude-code/`.
- **Done when:** running compose.py with `--target=paperclip` against the grid project
  produces a manifest.json covering the full agreed roster, diffable/reviewable, no API
  calls made.

### Session A2 — Paperclip deploy script + company bootstrap

**Specialist:** `grid-devops`. **Depends on:** A1.

- `agent-factory/scripts/deploy_paperclip.py`. Env: `PAPERCLIP_API_URL`,
  `PAPERCLIP_API_KEY`, `PAPERCLIP_COMPANY_ID`.
- Bootstrap a **new company** (not the dormant "Cogniskeleton" — that's a separate,
  unrelated experiment) — e.g. "The Grid". `--create-company` flag for one-time setup.
- Skills: for each unique skill key in the manifest, `GET /companies/:id/skills`; if
  missing, read the skill's `SKILL.md` from the-grid filesystem and `POST
  /companies/:id/skills` with raw markdown. Idempotent.
- Agents: walk manifest in topological order; `GET /companies/:id/agents` + match by name;
  `PATCH` if found, `POST /agent-hires` if not, resolving `reportsTo` from the real UUID of
  the already-created parent. Idempotent by construction, same idiom as `wire.sh`.
- Flag, don't fix yet: `PAPERCLIP_API_KEY` in `~/jarvis-core/docker-compose.yml` is
  plaintext — fine to reuse, worth a real secret later.
- **Done when:** script is idempotent (two consecutive runs produce no diff on the second),
  and dry-run/`--company-only` mode works without touching agents.

### Session A3 — Paperclip pilot hire + verification

**Specialist:** `grid-devops`. **Depends on:** A2.

- Resolve the open question: what `cwd` does each `claude_local` agent operate in? (Likely
  a per-agent git worktree, matching `~/worktrees/<name>` convention.) Decide and wire it
  into A2's payload builder if not already parameterized.
- Run the deploy script for real against the new company.
- Verify: `GET /companies/:id/agents` roster + `reportsTo` tree matches the agreed shape;
  `GET /agents/:id/instructions-bundle` on one agent matches source; one
  `POST /agents/:id/wakeup` confirms the `claude_local` adapter actually runs and does real
  work in its `cwd`.
- **Done when:** the full roster exists in Paperclip, one agent has been proven to actually
  execute, and the run is reproducible (re-running A2's script is a clean no-op).

### Session B1 — OpenClaw template set + roster.json

**Specialist:** `grid-backend-dev`. **Depends on:** Session 0.

- New `agent-factory/openclaw/templates/orchestrator/{IDENTITY,SOUL,AGENTS,USER,MEMORY,
  BOOT,TOOLS,HEARTBEAT,EXPERTISE}.md`, ported from Guide's template shape
  (`~/Guide/guide-core/agent-factory/templates/specialist/`).
  - `IDENTITY/SOUL/AGENTS/USER/MEMORY` sourced from `render_agent()` (no new merge logic).
  - `BOOT.md` new: explicit pre-load sequence (EXPERTISE.md first, then identity/roster),
    distinct from `AGENTS.md`'s ongoing operating rules — Guide's boot/operate split.
  - `EXPERTISE.md` = the role's existing `SKILL.md` content, ported verbatim.
  - `TOOLS.md`/`HEARTBEAT.md` thin scaffolds; `HEARTBEAT.md` starts empty (cadence via cron,
    not the heartbeat API — matches how `coach` already runs on scout).
- New `agent-factory/openclaw/roster.json`: one entry per orchestrator (`ceo-orchestrator`,
  `tech-lead`, `finance-manager`, `growth-hacker`, `product-manager`), `status: planned`.
- **Done when:** templates render correctly for all 5 orchestrators via a dry run, and
  `roster.json` validates as JSON with all 5 entries.

### Session B2 — `compose.py write_openclaw()` + safety-scheme docs

**Specialist:** `grid-backend-dev`. **Depends on:** B1.

- Extend `compose.py` with `write_openclaw()` emitting the Guide-shaped file set to
  `projects/<name>/_openclaw/<role>/`.
- Document the ported file-permission scheme (this is a hard-won pattern from Guide —
  references a real prior bug, #122, from getting it wrong) directly in
  `agent-factory/docs/openclaw-paperclip-targets-plan.md`:

  | Files | Mode | Who writes |
  |---|---|---|
  | `IDENTITY.md`, `SOUL.md` | 440 | Regenerated from source every run; locked |
  | `AGENTS.md`, `USER.md`, `BOOT.md`, `BOOTSTRAP.md` | 644 | Gareth/engineer edits directly |
  | `TOOLS.md`, `HEARTBEAT.md`, `MEMORY.md` | 664 | Agent-writable; **preserved on regen** |
  | `EXPERTISE.md` | 640 | Gareth-maintained; **preserved on regen** |

- **Done when:** `compose.py --target=openclaw-native` (or equivalent flag) produces the
  full file set + correct-looking permissions plan for all 5 orchestrators, matching B1's
  templates.

### Session B3 — OpenClaw deploy script (`deploy_openclaw.sh`)

**Specialist:** `grid-devops`. **Depends on:** B2.

Direct port of Guide's `generate.sh` regen logic + `ADD-AN-AGENT.md`'s registration steps,
adapted for scout's Telegram-only setup (no Slack):

1. **Install**: copy rendered files into `~/.openclaw/workspace-<role>` (create if missing).
   Always overwrite `IDENTITY/SOUL/AGENTS/USER.md` (source of truth); **skip**
   `MEMORY/TOOLS/HEARTBEAT/EXPERTISE.md` if they already have content. Apply B2's chmod
   scheme after every write.
2. **Agent dir**: create `~/.openclaw/agents/<role>/agent` (empty — auth provisioning is an
   open question, resolve empirically with a throwaway test agent in this session before
   touching a real orchestrator).
3. **Register + bind**:
   ```
   docker exec openclaw-gateway openclaw agents add <role> --workspace <path> --agent-dir <path> --non-interactive
   docker exec openclaw-gateway openclaw agents bind --agent <role> --bind telegram:<account-id>
   ```
   Messaging surface: one dedicated Telegram bot per orchestrator, matching the existing
   `coach` precedent — confirm with Gareth before binding for real.
4. **Mandatory allowlist step** (Guide flags this as easy to forget — silent drop, no error,
   no log): confirm scout's exact equivalent of `channels.telegram.accounts`/`allowFrom` and
   add the new account/group there.
5. **Safety dance** (`jarvis-core/CLAUDE.md`, reuse verbatim): snapshot cron state
   (`sqlite3 ~/.openclaw/state/openclaw.sqlite`), `docker compose restart`, verify cron job
   count unchanged, re-register auth keys, verify inbound message round-trip, commit
   `openclaw.json` to `jarvis-core`. Check empirically whether scout has Guide's
   "permissions reset to 700 after restart" quirk — don't assume either way.
- **Done when:** the script runs end-to-end against a **throwaway test agent** (not a real
  orchestrator yet) and every step above is confirmed working, including a real send/receive
  message round trip.

### Session B4 — OpenClaw pilot: `finance-manager`

**Specialist:** `grid-devops` for the deploy; **Gareth himself** for the test-as-Gareth
step (can't be delegated — it's his own verification). **Depends on:** B3.

- Deploy `finance-manager` for real using B3's script. `roster.json` status → `testing`.
- Test-as-Gareth-first checklist (ported from Guide's `ADD-AN-AGENT.md` Step 5):
  - Tone/style matches `finance-manager`'s `SOUL.md`.
  - Correctly scoped to its own domain, no bleed from another orchestrator's context.
  - **Signals-awareness check**: ask "if I asked you to modify a script, what would you do?"
    — correct answer is "file a signal," not attempt to self-edit (matches the-grid's
    existing convention, already documented in `main`'s own `AGENTS.md`).
- Confirm `main`/`household`/`coach` unaffected by the restart.
- **Done when:** `finance-manager` responds correctly over its bound Telegram surface,
  passes all three checks above, and `roster.json` status flips to `production`.

### Session B5 — OpenClaw rollout: remaining 4 orchestrators

**Specialist:** `grid-devops`. **Depends on:** B4 passing cleanly (no do-over of B3/B4 needed).

- Repeat B4's deploy + verification for `ceo-orchestrator`, `tech-lead`, `growth-hacker`,
  `product-manager`, one at a time, flipping each to `production` in `roster.json` as
  confirmed.
- **Done when:** all 5 orchestrators are `production` in `roster.json` and independently
  verified.

### Session C — Security review (before B4, gates the pilot)

**Specialist:** `grid-security-reviewer`. **Depends on:** A2 + B3 existing (code to review).

- Review `deploy_paperclip.py` and `deploy_openclaw.sh` for credential handling (the
  existing plaintext `PAPERCLIP_API_KEY`, any new Telegram bot tokens), the OpenClaw
  exec/tool permission profile assigned to each new orchestrator (port Guide's
  `securityDefaults`/`permissionProfiles` concept from `roster.json` — explicit
  exec/tool scoping per agent, not implicit full access), and the file-permission scheme
  from B2.
- **Done when:** findings are triaged and any blocking issues are fixed before B4 runs.

## Ordering summary

```
Session 0 (persist plan)
  ├─ A1 → A2 → A3                     (Paperclip track)
  └─ B1 → B2 → B3 ─┬─ C (security)
                    └─ B4 → B5         (OpenClaw track, gated by C)
```

Paperclip and OpenClaw tracks are independent and can run in parallel after Session 0.

## Files touched

- `agent-factory/docs/openclaw-paperclip-targets-plan.md` — this plan, persisted (Session 0).
- `agent-factory/compose.py` — add `write_paperclip()`, `write_openclaw()`, `--target` choices.
- `agent-factory/openclaw/templates/orchestrator/*.md` — new, ported from Guide's template shape.
- `agent-factory/openclaw/roster.json` — new, ported from Guide's status-lifecycle roster.
- `agent-factory/scripts/deploy_paperclip.py` — new.
- `agent-factory/scripts/deploy_openclaw.sh` — new.
- `~/jarvis-core/config/openclaw.json` (canonical copy) — new agent entries, via documented
  edit procedure.
- No changes to Paperclip or OpenClaw source themselves, and no changes to Guide's own
  `guide-core` repo — the grid's version is a sibling implementation of the same pattern,
  not a shared/refactored dependency between the two projects.
