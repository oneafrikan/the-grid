<!--
Passthrough template, but distinct from IDENTITY/SOUL/AGENTS/USER/MEMORY
above: this is NOT filled from render_agent() (that function has no
"EXPERTISE.md" key — it renders exactly the 5-file identity model). Per the
plan doc and the B1 task brief, EXPERTISE.md instead carries the role's own
SKILL.md content VERBATIM — this is a direct port, not bespoke-authored the
way Guide's EXPERTISE.md is (Guide's is a reasoning/voice layer written by
hand; the grid's already has an equivalent in every role's SKILL.md, so no new
authoring is needed here).

Session B2's write_openclaw() fills {{ROLE_SKILL_CONTENT}} by reading
`agent-factory/roles/<role>/SKILL.md` directly (the same file
emit_cc_subagent()/emit_cc_skill() already read for the claude-code target)
and substituting its full contents. See openclaw/README.md for the token list.

Gareth-maintained in the deployed workspace (mode 640) and PRESERVED ON
REGEN, matching Guide's EXPERTISE.md contract — a regenerate must not clobber
a workspace-local edit to this file without an explicit re-copy step.
-->
{{ROLE_SKILL_CONTENT}}
