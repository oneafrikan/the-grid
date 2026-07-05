<!--
Thin scaffold — genuinely new for the grid (no claude-code equivalent). Ported
from Guide's templates/specialist/TOOLS.md shape, trimmed to what's known at
B1 time. Session B3's deploy script fills in the real workspace/agent-dir
paths once a target host/agent-dir layout is decided; session C reviews the
exec/tool permission profile referenced below before B4's pilot.

Tokens filled by session B2's write_openclaw():
  {{ORCH_ROLE}} — machine role id, e.g. "tech-lead"
See openclaw/README.md for the full token list.
-->
# Tools — {{ORCH_ROLE}}

## This Machine

- Hostname: scout (Beelink SER8, Ubuntu 24.04)
- Runs inside the `openclaw-gateway` Docker container alongside `main`,
  `household`, and `coach`.

## Key Paths

| Resource | Path |
|----------|------|
| My workspace | `~/.openclaw/workspace-{{ORCH_ROLE}}/` |
| Signals (engineering requests) | `~/.openclaw/workspace-{{ORCH_ROLE}}/signals/` |
| The-grid (source of truth for my identity + skills) | `~/.the-grid/` (read-only from my perspective) |
| My Claude Code specialists (wired, not mine to edit) | `~/.claude/agents/grid-<role>.md` |

## Tool Use

- Exec/tool permission profile: TBD — session C (security review) sets the
  real scoping before B4's pilot. Until then, treat as **denied by default**
  (matches roster.json's `securityDefaults`) rather than assuming access.
- Do not write to `~/.the-grid/` — it is the compose source of truth,
  regenerated from there, not from a live agent's edits.
- File a signal for anything requiring code, config, or script changes —
  do not attempt it directly (see SOUL.md / AGENTS.md escalation rules).

## My Channel

Telegram binding: TBD — resolved in session B3/B4, see roster.json
`telegram` field for this role's current status.
