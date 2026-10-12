# Instincts: habit learning from your own sessions

Opt-in, per project. A hook records what you do in a session; once a week one cheap model
call turns those observations into short habit rules ("instincts"); the strong ones are
injected back at session start. Nothing here is on until you switch it on for a project.

## What is captured

- **Events:** Bash, Edit, Write, MultiEdit and NotebookEdit calls (and their failures), and the prompts you submit.
- **Content:** the command, the file path and your prompt text. Never tool output and never file contents.
- **Dropped, then scrubbed, before it is written:** any line holding a secret word with a value ("my password is ...", `TOKEN=...`), a long letter-and-digit run, an email address, a host name, an IP address, an SSN-like or card-like number is removed, and a prompt or command with no line left is not recorded at all. What remains is scrubbed: API keys, bearer tokens, JWTs, PEM blocks, password flags and similar become `[REDACTED]`. Absolute paths outside the project and your home are stored as `(outside)/<file name>`.
- **Never recorded:** any call that touches `.env`, `.envrc`, SSH keys, `*.pem`, `*.key`, `*.p12`, `*.pfx`, `.netrc`, `.pgpass`, `.npmrc`, `.pypirc`, `.kube`, `.docker/config`, `.aws/`, `.ssh/`, `credentials`, `*.tfstate` or `secrets.yml` is dropped entirely.
- **Not captured:** subagent calls, unattended sessions (loop worker, headless handoff child, cron), and any repo with no git remote (no stable project id).

## Privacy

- Everything is private and outside the public repo: raw observations in `${GRID_STATE_DIR:-~/.grid}/instincts/` (local to the machine), instincts in `~/.the-grid-private/learning/instincts/`.
- Raw observations are deleted 28 days after the end of their ISO week, whether or not an analysis ran: capture prunes old week files whenever it starts a new one, and the analyser does the same after a run.
- Store files are created `0600` and their directories `0700`.
- The project id is the first 12 hex characters of a SHA-256 of the normalised git remote URL. It is an identifier, not a secret: anyone who can guess the remote URL can recompute it, so do not treat the directory name as anonymous.
- `instincts.sh sync` (run at the end of every analysis) commits and pushes only `learning/instincts` in the private repo, and never touches your own work there: it is skipped while a rebase/merge is in progress, on a detached HEAD or with no upstream; the pull is skipped (no autostash) while tracked files outside the store are modified; files over 1 MiB are not committed; the push needs `<private>/.grid-private-remote` (first line = the push URL of the upstream remote, see `docs/usage.md`) and only own unpushed commits. A refused push because of a foreign unpushed commit makes `sync` exit 4; a missing or mismatched marker, or a remote with more than one push URL (`multiple-push-urls`), is a warning and exit 0.
- The weekly analysis sends a digest to a model (default `haiku`, `$0.05` cap per project). The digest holds no prompt text beyond keyword stems of corrections (the correction words plus a few plain words), and the same line-drop and path rules as capture are applied again before anything is sent. Only projects that still have the opt-in marker and `learning: on` are analysed; others show up as `not-enabled` or `opt-out` in `status`. The model call runs with a scrubbed environment (only `PATH`, `HOME`, locale, proxy and Claude auth variables; add more with `INSTINCTS_PASS_ENV="NAME1 NAME2"`) and a one-turn limit. The emitter prints a one-line notice saying so each time it emits the instincts hooks.

## How to enable

1. In the project's `.grid/project.yaml` add a top-level `learning: on` (`true` also works; anything else, including a bare `yes`, is off). If the key appears more than once the last one wins. The emitter and capture read it with the same parser.
2. Register the hooks with `agent-factory/deploy_hooks.py <project>` (from the hook-profiles change). The `instincts-*` hooks are emitted whenever the flag is on, under every hook profile including `off`. The same run writes a machine-local marker (`${GRID_STATE_DIR:-~/.grid}/instincts/enabled/<project-id>`); capture and inject need the flag AND a marker that lists this checkout, so a cloned repo that ships `learning: on` (or another clone with the same remote) records nothing until you run the emitter in it yourself. The project needs a git remote. If you enabled instincts before this marker existed, re-run the emitter once.
3. Default hook target is `local` (`.claude/settings.local.json`). With `hooks.target: shared`, a collaborator without the-grid sees a non-blocking hook error on each captured event.
4. To stop: set `learning: off` (or remove the line) and re-run the emitter to remove the hooks and the marker. Capture and inject also re-check the flag, so a stale settings file stops recording at once.

## Read it

- `scripts/instincts.sh show [PROJECT]` — merged instincts (default: the current repo). A new habit starts as `pending`: it is never injected into a session until you review it and run `scripts/instincts.sh approve ID` in that repo (it then becomes `active`). Habit text must be plain ASCII letters; anything that imitates the injection block, a chat turn, a download or a weaker permission setting is dropped. Injected hints appear as quoted lines ending with `[end of hints]`, and each injection writes its ids and confidences to the run log.
- `scripts/instincts.sh status [--project ID]` — the funnel per project. Three different zeros:
  - `ret=0`: the model saw no habit.
  - `ret>0 valid=0`: the prompt and the validator disagree.
  - `valid>0 kept=0`: nothing new this week.
- `scripts/instincts.sh analyse --all --dry-run` — print the digest and plan; calls no model, writes nothing.
- `scripts/instincts.sh promote` / `approve ID` — an instinct seen in 2+ projects becomes a candidate; it is global only after you approve it.

## Forget and tune

- `scripts/instincts.sh retire ID [PROJECT] [--global]` — stop using one instinct in a project. A GLOBAL instinct (shared by every project) is retired only with `--global`.
- `scripts/instincts.sh forget PROJECT --yes` — delete the local observations, this machine's instinct file, the project's status entry, its opt-in marker and (when no other host file remains) its `META.json`. It does not touch other hosts' files, derived `_global` lines or the git history of the private repo: purge those by hand. Capture stays off until the emitter is re-run; set `learning: off` to keep it off.
- Thresholds are environment variables, not a config file: `INSTINCTS_MODEL`, `INSTINCTS_BUDGET_USD`, `INSTINCTS_TIMEOUT_S`, `INSTINCTS_MIN_OBS`, `INSTINCTS_MAX_PROJECTS`, `INSTINCTS_MIN_CONF`, `INSTINCTS_MAX_ITEMS`, `INSTINCTS_MAX_CHARS`.

## Kill switches

- `GRID_INSTINCTS=0` — disables capture, injection and the weekly analysis (no model call, even with `--dry-run`).
- `GRID_HOOKS=off` — every grid hook, including these.
- `GRID_DISABLED_HOOKS=<id>` — one hook, e.g. `instincts-capture-prompt`.
- `learning: off` in `.grid/project.yaml` — per project.

## Learning desk

- **Tank `evolve`:** `scripts/instincts.sh clusters` lists clusters of 3+ active instincts (confidence >= 0.6, same domain) and every global instinct with confidence >= 0.75. Ask tank to evolve one; it writes a draft to `~/.the-grid-private/learning/tank/skill-drafts/<slug>/SKILL.md`. Nothing is wired: you review the draft and move it into `skills/` in a normal commit.
- **Oracle:** if you name the instincts store, it may offer `preference` instincts (confidence >= 0.6) as candidate profile entries tagged OBSERVED, one at a time, saved only on a yes.
- **Instincts vs `LEARNINGS.md`:** instincts are soft, per project and machine-learned; `LEARNINGS.md` is durable, human-approved and public. They stay separate. A procedural learning can be handed to tank `evolve`.
