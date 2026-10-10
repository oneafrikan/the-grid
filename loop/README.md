# loop/ — issue-loop automation (instantiated)

Cut from `automation-factory/patterns/issue-loop` (re-cut for PR mode and the headless
runner). An agent that works this repo's `ready-for-agent` issue backlog, either interactively
(`/loop`) or unattended overnight on a Linux box, opening **PRs to `next`** for a human to review and merge.
How the pattern works, and why it is built this way, is in
[`automation-factory/patterns/issue-loop/README.md`](../automation-factory/patterns/issue-loop/README.md).

| Module | File | Role |
|--------|------|------|
| **1 — review hook** | `hooks/post-commit-review.sh` | PostToolUse(Bash) hook: on every `git commit`, a backgrounded, capped `claude -p` review of that commit, posted on the branch's open PR (else issue `#N`). Stands down in headless runs. |
| **2 — loop prompt** | `loop-prompt.template.md` → `loop-prompt.md` (generated) | The interactive `/loop` prompt in PR mode: lowest `ready-for-agent` issue → `issue-<N>` worktree → implement → verify → commit (`#N`) → push → PR to `next` → `ready-for-human`. |
| **3 — headless runner** | `run-issues.sh`, `gh-app-token.sh`, `loop.conf` | Unattended runner; one tokenless, capped worker per issue; the runner pushes and opens the PR and runs the Opus review. |
| **4 — guard + worktree** | `hooks/guard-main-push.sh`, `hooks/new-agent-worktree.sh` | PreToolUse mistake-catcher for pushes and merges; cuts `issue-<N>` worktrees off `origin/next`. |
| **wiring** | `setup.sh` | Bakes this machine's absolute path into `loop-prompt.md` and merges the review and guard hooks into `.claude/settings.json` (only its own entries). Idempotent. |

## This repo's parameters

- **Base branch:** `next`. Every PR the loop opens targets `next`; nothing here pushes `main`.
- **Mode:** `pr` (the headless runner refuses `direct`).
- **Issue label:** `ready-for-agent` (opt-in gate: only a trusted person's label counts; see the trust gate in the pattern README).
- **Verify gate:** `GRID_REQUIRE_DENYLIST=1 bash scripts/gate.sh` (shellcheck, catalogue, role lint, bats, leak scan). The loop never commits a red build.
- **State labels:** `ready-for-human` (PR waiting), `needs-human` (ambiguous or refused by the trust gate), `blocked` (could not land it).
- **Role labels:** `role:grid-backend-dev`, `role:grid-devops`, `role:grid-technical-writer`, `role:grid-sdet`, `role:grid-prompt-engineer`, `role:core-platform-engineer` route an issue to that builder agent; read-only roles end `blocked`.
- **Label budgets:** `LABEL_BUDGETS=ws:rule-packs=15` raises the worker spend cap to 15 USD for rule-pack content issues (default cap 5).
- **Caps (`loop.conf`):** 3 issues per run, worker `sonnet` / review `opus`, 1800 s per worker, spend caps on every call.
- **Unattended use needs a dedicated unprivileged OS user** with its own clone and `claude` login, a GitHub App
  (no Workflows, no Administration) installed on this repo only, and a ruleset requiring a PR on `next` with an
  empty bypass list. The runner refuses to start without them. Nothing in this repo creates credentials.

## Run it

```bash
bash loop/setup.sh        # after any clone or repo move: regenerates machine wiring
```

- **Interactive:** in Claude Code, `/loop` with the contents of `loop/loop-prompt.md`.
- **Headless:** `bash loop/run-issues.sh` as the loop user (normally via the systemd user timer the `linux`
  profile of `scripts/instantiate.sh` writes; see `docs/uplift-runbook.md`). Exit 0 run finished, 1
  infrastructure failure mid-run, 2 preflight failed (the message names the fix).

## Notes

- `loop-prompt.md` is generated (absolute path baked in) and gitignored; `loop-prompt.template.md` is the tracked source.
- `.claude/settings.json` is gitignored (machine-specific hook paths); `setup.sh` re-derives it, nothing is lost on clone.
- `loop.conf` is rendered once by `instantiate.sh` and never overwritten by a re-run: tune it by hand.
- Re-cut command (from a clean tree, `gh` authenticated or `GH_TOKEN` set):
  `bash scripts/instantiate.sh issue-loop . --profile work --base-branch next --verify-cmd "GRID_REQUIRE_DENYLIST=1 bash scripts/gate.sh" --role-labels grid-backend-dev,grid-devops,grid-technical-writer,grid-sdet,grid-prompt-engineer,core-platform-engineer`
  (`loop/loop.conf` is left alone if it exists).
