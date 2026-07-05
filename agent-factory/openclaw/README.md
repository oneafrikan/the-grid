# openclaw/ — OpenClaw target for agent-factory

Part of the plan at `../docs/openclaw-paperclip-targets-plan.md` (Session B1).
This directory holds the **template shell** for deploying the 5 grid
orchestrator roles (`ceo-orchestrator`, `tech-lead`, `finance-manager`,
`growth-hacker`, `product-manager`) as real OpenClaw agents. It does not (yet)
contain any renderer or deploy logic — that's session B2 (`compose.py
write_openclaw()`) and session B3 (`deploy_openclaw.sh`) respectively. Nothing
here has touched a live system: no docker exec, no writes to `~/.openclaw`.

Shape ported from Gareth's proven Guide agent-factory
(`~/Guide/guide-core/agent-factory/templates/specialist/` +
`~/Guide/guide-core/agent-factory/roster.json`) — adapted, not copied
verbatim. Guide targets Slack + personal Telegram instances for the safari
knowledge domain; this ports the same file shape and lifecycle discipline to
grid's dev-team orchestrators.

## Layout

```
openclaw/
├── README.md                          — this file
├── roster.json                        — status-lifecycle roster, one entry per orchestrator
└── templates/orchestrator/
    ├── IDENTITY.md   — passthrough (render_agent() output)
    ├── SOUL.md       — passthrough (render_agent() output)
    ├── AGENTS.md     — passthrough (render_agent() output)
    ├── USER.md       — passthrough (render_agent() output)
    ├── MEMORY.md     — passthrough (render_agent() output), preserved on regen
    ├── BOOT.md       — new: pre-load sequence (not in the claude-code target)
    ├── TOOLS.md      — new: thin scaffold, filled in as B3 resolves real paths
    ├── HEARTBEAT.md  — new: thin scaffold, empty by convention (cron, not heartbeat API)
    └── EXPERTISE.md  — passthrough for the role's own SKILL.md, ported verbatim
```

## Why 9 files, only 4 are "new"

`compose.py`'s existing `render_agent(agent)` already renders the 5-file
identity model (`IDENTITY.md`, `SOUL.md`, `AGENTS.md`, `USER.md`, `MEMORY.md`)
— this is the same function the claude-code target uses, and per the plan
doc's "what's reusable" section, is *already* OpenClaw-shaped output (the
default/no-target compose.py output is this exact 5-file set, unflattened).
So those 5 templates here are **thin passthroughs**: a single
`{{RENDERED_CONTENT}}` token, filled verbatim by session B2's
`write_openclaw()` calling `render_agent()` — no new merge logic, no
duplicated content.

`BOOT.md`, `TOOLS.md`, `HEARTBEAT.md` are genuinely new — scout's existing 3
OpenClaw agents (`main`, `household`, `coach`) don't have a `BOOT.md` today;
this plan introduces the boot/operate split Guide already uses (`BOOT.md` =
one-time pre-load sequence, `AGENTS.md` = ongoing operating rules).

`EXPERTISE.md` is also new-in-shape but not new-in-content: per the plan doc,
it holds the role's own `SKILL.md` **verbatim** (a direct port — the grid
roles already have this content; Guide's EXPERTISE.md is hand-authored
because Guide's specialists had no equivalent file to port).

## Token reference

Tokens are filled by session B2's `write_openclaw()`. None of them are
substituted by this session — B1 only defines the shell.

| Token | Source | Used in |
|---|---|---|
| `{{RENDERED_CONTENT}}` | `render_agent(agent)[filename]` (compose.py, unchanged) | IDENTITY.md, SOUL.md, AGENTS.md, USER.md, MEMORY.md |
| `{{ROLE_SKILL_CONTENT}}` | `roles/<role>/SKILL.md`, read verbatim | EXPERTISE.md |
| `{{ORCH_ROLE}}` | `role.yaml` → `name` (machine id, e.g. `tech-lead`; matches the `grid-<role>` Claude Code subagent naming convention wired by `wire.sh`) | BOOT.md, TOOLS.md, HEARTBEAT.md |
| `{{ORCH_TITLE}}` | `role.yaml` → `title` (human-readable, e.g. `Tech Lead`) | BOOT.md |
| `{{ORCH_SUMMARY}}` | `role.yaml` → `summary`, whitespace-collapsed (same normalisation `role_summary()` already does) | BOOT.md |

Not yet needed but likely for B2/B3 (not defined here — add when the
consuming code actually needs them, per the-grid's no-speculative-config
convention): a per-agent model token (`resolve_model(agent)` already exists
in compose.py and could feed an `{{ORCH_MODEL}}` token if a template ever
needs to print it — none of B1's templates do).

## File-permission scheme (for B2/B3 — not applied by B1)

Documented in full in `../docs/openclaw-paperclip-targets-plan.md` (Session
B2). Summary, so it's visible from this directory too:

| Files | Mode | Who writes | Preserved on regen? |
|---|---|---|---|
| `IDENTITY.md`, `SOUL.md` | 440 | Regenerated every run | No — always overwritten |
| `AGENTS.md`, `USER.md`, `BOOT.md` | 644 | Gareth/engineer edits directly | No — always overwritten |
| `TOOLS.md`, `HEARTBEAT.md`, `MEMORY.md` | 664 | Agent-writable | **Yes** |
| `EXPERTISE.md` | 640 | Gareth-maintained | **Yes** |

## roster.json

One entry per orchestrator role, `status: "planned"` (this session's baseline
— nothing has been built or deployed yet). Shape ported from Guide's
`roster.json`: a `_meta.statusValues` lifecycle
(`planned → building → testing → production → paused`), a `securityDefaults`
block, and a `permissionProfiles` map. Guide's version is tuned for its own
personal/channel/main agent split; this is a first-pass adaptation for grid's
orchestrator-only rollout — session C (security review, gates B4) is expected
to scrutinize and likely tighten it before any real deploy.

Validate after any edit:

```bash
python3 -c "import json; json.load(open('roster.json'))" && echo OK
```

## What this session does *not* do

- No changes to `compose.py` (session B2).
- No `deploy_openclaw.sh`, no `docker exec`, no writes under `~/.openclaw`
  (session B3).
- No real Telegram bindings, no security-profile tightening (sessions B3/B4
  and C respectively) — `roster.json`'s `telegram` field and permission
  profile are deliberately left as placeholders/first-pass here.
