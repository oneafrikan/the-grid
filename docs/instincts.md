# Instincts: habit learning from your own sessions

Opt-in, per project. A hook records what you do in a session; once a week one cheap model
call turns those observations into short habit rules ("instincts"); the strong ones are
injected back at session start. Nothing here is on until you switch it on for a project.

## What is captured

- **Events:** Bash, Edit, Write, MultiEdit and NotebookEdit calls (and their failures), and the prompts you submit.
- **Content:** the command, the file path and your prompt text. Never tool output and never file contents.
- **Scrubbed before it is written:** API keys, bearer tokens, JWTs, PEM blocks and similar are replaced with `[REDACTED]`. Any call that touches `.env`, `id_rsa`, `id_ed25519`, `*.pem`, `credentials` or `.netrc` is dropped entirely.
- **Not captured:** subagent calls, unattended sessions (loop worker, headless handoff child, cron), and any repo with no git remote (no stable project id).

## Privacy

- Everything is private and outside the public repo: raw observations in `${GRID_STATE_DIR:-~/.grid}/instincts/` (local to the machine), instincts in `~/.the-grid-private/learning/instincts/`.
- Raw observations are deleted 28 days after a successful analysis.
- The project id is a 12-character hash of the git remote URL, not the URL.
- The weekly analysis sends a digest of the scrubbed observations to a model (default `haiku`, `$0.05` cap per project). Do not enable it on a project whose prompts you would not send to a model.

## How to enable

1. In the project's `.grid/project.yaml` add a top-level `learning: on` (`true` also works; anything else is off).
2. Register the hooks with `agent-factory/deploy_hooks.py <project>` (from the hook-profiles change). The `instincts-*` hooks are emitted whenever the flag is on, under every hook profile including `off`.
3. Default hook target is `local` (`.claude/settings.local.json`). With `hooks.target: shared`, a collaborator without the-grid sees a non-blocking hook error on each captured event.
4. To stop: set `learning: off` (or remove the line) and re-run the emitter to remove the hooks. Capture and inject also re-check the flag, so a stale settings file stops recording at once.

## Read it

- `scripts/instincts.sh show [PROJECT]` — merged instincts (default: the current repo).
- `scripts/instincts.sh status [--project ID]` — the funnel per project. Three different zeros:
  - `ret=0`: the model saw no habit.
  - `ret>0 valid=0`: the prompt and the validator disagree.
  - `valid>0 kept=0`: nothing new this week.
- `scripts/instincts.sh analyse --all --dry-run` — print the digest and plan; calls no model, writes nothing.
- `scripts/instincts.sh promote` / `approve ID` — an instinct seen in 2+ projects becomes a candidate; it is global only after you approve it.

## Forget and tune

- `scripts/instincts.sh retire ID [PROJECT]` — stop using one instinct.
- `scripts/instincts.sh forget PROJECT --yes` — delete the local observations and this machine's instincts for a project.
- Thresholds are environment variables, not a config file: `INSTINCTS_MODEL`, `INSTINCTS_BUDGET_USD`, `INSTINCTS_TIMEOUT_S`, `INSTINCTS_MIN_OBS`, `INSTINCTS_MAX_PROJECTS`, `INSTINCTS_MIN_CONF`, `INSTINCTS_MAX_ITEMS`, `INSTINCTS_MAX_CHARS`.

## Kill switches

- `GRID_INSTINCTS=0` — disables capture and injection.
- `GRID_HOOKS=off` — every grid hook, including these.
- `GRID_DISABLED_HOOKS=<id>` — one hook, e.g. `instincts-capture-prompt`.
- `learning: off` in `.grid/project.yaml` — per project.

## Learning desk

- **Tank `evolve`:** `scripts/instincts.sh clusters` lists clusters of 3+ active instincts (confidence >= 0.6, same domain) and every global instinct with confidence >= 0.75. Ask tank to evolve one; it writes a draft to `~/.the-grid-private/learning/tank/skill-drafts/<slug>/SKILL.md`. Nothing is wired: you review the draft and move it into `skills/` in a normal commit.
- **Oracle:** if you name the instincts store, it may offer `preference` instincts (confidence >= 0.6) as candidate profile entries tagged OBSERVED, one at a time, saved only on a yes.
- **Instincts vs `LEARNINGS.md`:** instincts are soft, per project and machine-learned; `LEARNINGS.md` is durable, human-approved and public. They stay separate. A procedural learning can be handed to tank `evolve`.
