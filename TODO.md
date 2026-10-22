# the-grid TODO

> **Open work now lives in GitHub Issues** — they are the current state of play.
> Browse: `gh issue list --repo oneafrikan/the-grid` (or the repo's Issues tab).
> This file keeps only the **issue map** (below). Shipped-work history is kept
> privately. Add new work as an issue, not here.

**Current focus (2026-10-22):** the issue loop is live in this repo (untracked
`loop/`, `MODE=direct`, issues in the private tracker) and its first queue is drained
(86 issues landed, `main` green). Next: the operator installs the cron line (exact
line in `docs/issue-loop-runbook.md`, "Cron") and works the human issues. Deferred
until `main` is stable: `karpathy-loop` and `cli-cron`. Held: the `index.html` rebuild
(**#150**), blocked on the operator's render step (**#149**) and a `git rm`.

**#25** (public-facing README + quickstart) is the remaining gating work for the repo
being usable by someone who isn't the author. `main` is the only long-lived branch.

Behind that: `agent-factory` is a multi-target compiler. The **Claude Code** target is
live, and the `codex`, `opencode`, `gemini-cli` and `portable` targets are built
(skills, subagents and rules reach those harnesses via `harness:<name>`, see
`docs/harnesses.md`). **#31**, **#32**, **#33** and **#36** are closed; the real-install
smoke test of each harness is tracked in **#143**. The OpenClaw/Paperclip emitter work
(**#4**) remains the deeper lift.

---

## Open issues (map)

Regenerate with:
`gh issue list --state open --limit 50 --json number,title,labels`

### Public-readiness (gating)

| # | Title | Labels or status |
|---|-------|--------|
| [#25](https://github.com/oneafrikan/the-grid/issues/25) | Public-facing README + adopt-the-grid quickstart | docs, ready-for-agent |

### agent-factory — new compose targets

| # | Title | Labels or status |
|---|-------|--------|
| [#31](https://github.com/oneafrikan/the-grid/issues/31) | New compose.py target: opencode | built; closed, real-install check tracked in #143 |
| [#33](https://github.com/oneafrikan/the-grid/issues/33) | New compose.py target: OpenAI Codex CLI | built; closed, real-install check tracked in #143 |
| [#32](https://github.com/oneafrikan/the-grid/issues/32) | New compose.py target: Gemini CLI | built; closed, real-install check tracked in #143 |
| [#34](https://github.com/oneafrikan/the-grid/issues/34) | Amp: verify custom-agent mechanism before scoping a target | deferred, needs-info |
| [#4](https://github.com/oneafrikan/the-grid/issues/4) | agent-factory target: async/autonomous via Paperclip | needs-info, severity:medium |

Implementation plan for #4, scoped to a curated orchestrator roster (not a
full-roster port) and chunked into single-session specialist work:
`agent-factory/openclaw/README.md`.

### agent-factory — everything else

| # | Title | Labels or status |
|---|-------|--------|
| [#5](https://github.com/oneafrikan/the-grid/issues/5) | agent-factory: flesh stack overlays (LAMP + others) | superseded by rule packs (docs/rules.md) |
| [#6](https://github.com/oneafrikan/the-grid/issues/6) | agent-factory: populate `skills/` from repos submodules | needs-human |
| [#13](https://github.com/oneafrikan/the-grid/issues/13) | Optional: deepen growth-hacker to marketing-director orchestrator | backlog |
| [#23](https://github.com/oneafrikan/the-grid/issues/23) | compose.py golden-output conformance tests | built (`scripts/compose-goldens.sh`); issue still open |

### Feedback loops & dogfooding

| # | Title | Labels or status |
|---|-------|--------|
| [#18](https://github.com/oneafrikan/the-grid/issues/18) | skill-scout autonomy: scheduled scout → PR proposals against baseline | ready-for-agent |
| [#19](https://github.com/oneafrikan/the-grid/issues/19) | Close the learnings loop: mine-learnings output → candidate skills | ready-for-agent |
| [#16](https://github.com/oneafrikan/the-grid/issues/16) | Create agent self-improving capability | needs-info |
| [#21](https://github.com/oneafrikan/the-grid/issues/21) | Factory chain e2e: one command from idea → staffed, looping project | ready-for-human |
| [#22](https://github.com/oneafrikan/the-grid/issues/22) | Dogfood milestone: ship one real feature via /grid-ceo-orchestrator | needs-info |

### Specs, docs, backlog

| # | Title | Labels or status |
|---|-------|--------|
| [#38](https://github.com/oneafrikan/the-grid/issues/38) | Evaluate OpenSpec stores for cross-repo planning (+ steal `--remote`) | deferred, ready-for-human |
| [#7](https://github.com/oneafrikan/the-grid/issues/7) | Decide fate of the LAMP build prompt (likely superseded) + 4 gaps | docs, ready-for-human |
| [#12](https://github.com/oneafrikan/the-grid/issues/12) | Add OpenGAP + soulspec as reference submodules | ready-for-human |
| [#29](https://github.com/oneafrikan/the-grid/issues/29) | finance-agents-base: implement Layer-1 guardrail/rules.py (hard-limit veto) | ready-for-human, severity:medium |

### Issue-loop (`openspec/changes/issue-loop-v2`, no issue yet)

- **Working:** headless runner (`pr` draft PRs and `direct` landing on the base), runner-side verify, `--fast-verify`, `--cron-every` (one printed crontab line per repo, `loop/cron-run.sh`), unlimited daily count by default, stale-lock takeover, infra failures keep the label and back off (15 min doubling to 6 h).
- **Outstanding:** the group 7.0/7.4 `_retired/` decision; the HUMAN proofs on a throwaway repo (groups 8.7-8.9, 10, 12); remaining B3 tests (full doubling table with the 6 h cap, parallel stale-lock race, SIGKILL run).
- **Gaps to decide:** `instantiate.sh --mode direct` ships no runner and `--cron-every` refuses `direct`, so headless direct is only reachable by setting `MODE=direct` in a `pr` cut's `loop/loop.conf`.

### Deferred (no issue yet)

- `karpathy-loop` and `cli-agent-cron` (the unbuilt Phase B of `openspec/changes/loops`, tasks 6 to 8): deferred until the rebuilt issue-loop (`openspec/changes/issue-loop-v2`) is proven. See `openspec/changes/loops/SUPERSEDED.md`.

---

Shipped-work history is kept privately; see git log.
