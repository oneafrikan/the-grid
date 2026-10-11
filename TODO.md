# the-grid TODO

> **Open work now lives in GitHub Issues** — they are the current state of play.
> Browse: `gh issue list --repo oneafrikan/the-grid` (or the repo's Issues tab).
> This file keeps only the **issue map** (below). Shipped-work history is kept
> privately. Add new work as an issue, not here.

**Current focus (2026-09-11):** the-grid is being shared with other people.
**#24**/**#39** (de-Gareth audit) closed 2026-09-11. **#25** (public-facing
README + quickstart) is the remaining gating work — everything else is
downstream of the repo being usable by someone who isn't Gareth.

Behind that: `agent-factory` is a multi-target compiler with the **Claude Code**
target shipped. The next targets (**#31** opencode, **#33** Codex, **#32** Gemini,
**#30** Cursor) are scoped from the 2026-07-24 portability research but not
built. OpenClaw/Paperclip emitters (**#3**, **#4**) remain the deeper lift.

---

## Open issues (map)

Regenerate with:
`gh issue list --state open --limit 50 --json number,title,labels`

### Public-readiness (gating)

| # | Title | Labels |
|---|-------|--------|
| [#25](https://github.com/oneafrikan/the-grid/issues/25) | Public-facing README + adopt-the-grid quickstart | docs, ready-for-agent |
| [#37](https://github.com/oneafrikan/the-grid/issues/37) | 22 submodules use SSH clone URLs — fresh-machine bootstrap can fail | wiring, infra, ready-for-agent |

### agent-factory — new compose targets

| # | Title | Labels |
|---|-------|--------|
| [#31](https://github.com/oneafrikan/the-grid/issues/31) | New compose.py target: opencode | ready-for-agent |
| [#33](https://github.com/oneafrikan/the-grid/issues/33) | New compose.py target: OpenAI Codex CLI | ready-for-human |
| [#32](https://github.com/oneafrikan/the-grid/issues/32) | New compose.py target: Gemini CLI | ready-for-human |
| [#30](https://github.com/oneafrikan/the-grid/issues/30) | Cursor: validate zero-cost reuse of claude-code subagent output | ready-for-agent |
| [#36](https://github.com/oneafrikan/the-grid/issues/36) | New compose.py target: portable single-file personas for chat-UI Projects | ready-for-human |
| [#34](https://github.com/oneafrikan/the-grid/issues/34) | Amp: verify custom-agent mechanism before scoping a target | deferred, needs-info |
| [#35](https://github.com/oneafrikan/the-grid/issues/35) | Continue: decide skip or reframe — doesn't map to the roster model | deferred, question |
| [#3](https://github.com/oneafrikan/the-grid/issues/3) | agent-factory target: OpenClaw emitter (remote host) | needs-info |
| [#4](https://github.com/oneafrikan/the-grid/issues/4) | agent-factory target: async/autonomous via Paperclip | needs-info, severity:medium |

Implementation plan for #3/#4, scoped to a curated orchestrator roster (not a
full-roster port) and chunked into single-session specialist work:
`agent-factory/openclaw/README.md`.

### agent-factory — everything else

| # | Title | Labels |
|---|-------|--------|
| [#5](https://github.com/oneafrikan/the-grid/issues/5) | agent-factory: flesh stack overlays (LAMP + others) | superseded by rule packs (docs/rules.md) |
| [#6](https://github.com/oneafrikan/the-grid/issues/6) | agent-factory: populate `skills/` from repos submodules | needs-human |
| [#13](https://github.com/oneafrikan/the-grid/issues/13) | Optional: deepen growth-hacker to marketing-director orchestrator | backlog |
| [#20](https://github.com/oneafrikan/the-grid/issues/20) | Inject LEARNINGS.md into composed agents at compose time | ready-for-human |
| [#23](https://github.com/oneafrikan/the-grid/issues/23) | compose.py golden-output conformance tests | ready-for-agent |

### Feedback loops & dogfooding

| # | Title | Labels |
|---|-------|--------|
| [#18](https://github.com/oneafrikan/the-grid/issues/18) | skill-scout autonomy: scheduled scout → PR proposals against baseline | ready-for-agent |
| [#19](https://github.com/oneafrikan/the-grid/issues/19) | Close the learnings loop: mine-learnings output → candidate skills | ready-for-agent |
| [#16](https://github.com/oneafrikan/the-grid/issues/16) | Create agent self-improving capability | needs-info |
| [#21](https://github.com/oneafrikan/the-grid/issues/21) | Factory chain e2e: one command from idea → staffed, looping project | ready-for-human |
| [#22](https://github.com/oneafrikan/the-grid/issues/22) | Dogfood milestone: ship one real feature via /grid-ceo-orchestrator | needs-info |

### Specs, docs, backlog

| # | Title | Labels |
|---|-------|--------|
| [#38](https://github.com/oneafrikan/the-grid/issues/38) | Evaluate OpenSpec stores for cross-repo planning (+ steal `--remote`) | deferred, ready-for-human |
| [#7](https://github.com/oneafrikan/the-grid/issues/7) | Decide fate of the LAMP build prompt (likely superseded) + 4 gaps | docs, ready-for-human |
| [#12](https://github.com/oneafrikan/the-grid/issues/12) | Add OpenGAP + soulspec as reference submodules | ready-for-human |
| [#29](https://github.com/oneafrikan/the-grid/issues/29) | finance-agents-base: implement Layer-1 guardrail/rules.py (hard-limit veto) | ready-for-human, severity:medium |

---

Shipped-work history is kept privately; see git log.
