# The factory chain: empty directory to a staffed, looping project

A runbook for the three entry points, in order. Each step is a command you run by hand; nothing here is chained by a script. Every command and flag below is taken from the script's own usage text or its README.

| Step | Entry point | Factory | Result |
|---|---|---|---|
| 1 | `project-factory/scripts/cut-project.sh` | project-factory | a seeded, git-initialised project |
| 2 | `agent-factory/deploy.py` | agent-factory | a lean set of grid agents in the project's `.claude/` |
| 3 | `scripts/instantiate.sh` | automation-factory | the `issue-loop` cut into a tracked `loop/` |

All commands run from a checkout of the-grid unless a step says "in the project". `<project-dir>` is the new project's directory, `<owner>/<repo>` its GitHub repo.

## Before you start

- `git`, `gh` (authenticated), `jq`, `claude`, `timeout` and `python3` on `PATH`; the issue-loop runner refuses to start without them.
- The agent-factory venv, once per checkout: `cd agent-factory && python3 -m venv .venv && .venv/bin/pip install -r requirements.txt`.
- An empty GitHub repo for the project (create it yourself; no step here does).

## 1. Seed the project

List the templates (the script prints them when run with too few arguments), then cut one into an empty directory:

```bash
bash project-factory/scripts/cut-project.sh
bash project-factory/scripts/cut-project.sh [--with-related] <template> <project-dir>
```

- An absent or empty `<project-dir>` is a **seed**: the script lays down `templates/_common/` and then `templates/<template>/`, runs `git init` and sets `core.hooksPath=.githooks`.
- A non-empty directory is a **retrofit**: files that already exist and differ are skipped and listed, never overwritten.
- It generates `MAP.md` from the project's own `scripts/map.py`.
- Re-running is safe; it only adds what is missing.

Check: the output ends with `Done. N file(s) written, 0 skipped.` for a seed.

## 2. Fill the stubs

In the project, replace the `<fill>` markers:

1. `PURPOSE.md` and `GUARDRAILS.md`: the problem, and the must-nots with how each is checked.
2. `.grid/project.yaml`: the project facts every deployed agent receives (written verbatim into their prompts, so treat it like `CLAUDE.md`).
3. `loop/loop.conf.seed`: at least `VERIFY_CMD`, the check that must pass before anything is pushed. `loop/ENABLE.md` lists the rest.

Then commit, add the remote and push:

```bash
git add -A
git commit -m "Seed project"
git remote add origin git@github.com:<owner>/<repo>.git
git push -u origin HEAD
```

## 3. Deploy the agents

List the roles, then deploy a selection (lean profile by default) into the project's `.claude/`:

```bash
agent-factory/.venv/bin/python agent-factory/deploy.py --list
agent-factory/.venv/bin/python agent-factory/deploy.py <project-dir> --roles fullstack-engineer,sdet,technical-writer
agent-factory/.venv/bin/python agent-factory/deploy.py <project-dir> --check
```

- Files land as `.claude/agents/grid-<role>.md` (orchestrators as `.claude/skills/grid-<role>/SKILL.md`) plus `.claude/grid-agents.lock`.
- They carry a GENERATED marker. Never edit them; change the role in the-grid or the facts in `.grid/project.yaml` and re-run.
- `--dry-run` shows the plan and writes nothing; `--profile full` renders the full persona instead of the lean cut.
- `--check` exits 1 on drift. It writes nothing.

Check: `--check` exits 0. Commit `.claude/agents/`, `.claude/skills/` and `.claude/grid-agents.lock`.

## 4. Cut the issue-loop

```bash
bash scripts/instantiate.sh issue-loop <project-dir> --profile work --verify-cmd '<the project check>'
```

- `--profile` is `personal`, `work` or `mac-mini`. `work` and `mac-mini` ship the headless runner and open draft PRs; `personal` is the interactive `/loop` only.
- Other options, none required: `--repo`, `--issue-repo`, `--project-context`, `--label`, `--review-focus`, `--base-branch`, `--mode`, `--land`, `--setup-cmd`, `--worker-model`, `--agent-labels`, `--fast-verify`, `--cron-every`, `--cron-log`. Run the script with no arguments for the list.
- It copies the pattern into a tracked `loop/`, renders `loop/loop.conf` once (a re-run leaves your edits alone), runs `loop/setup.sh` and creates the opt-in labels in the issue repo.
- It writes no scheduler file and installs nothing.
- A second identical run prints no `wrote:` line.

Check: `loop/run-issue.sh` and `loop/loop.conf` exist in the project. Commit `loop/` and push.

## 5. Run it by hand

In the project:

1. File an issue and label it `ready-for-agent`.
2. Run `bash loop/run-issue.sh`. It works the lowest-numbered labelled issue, runs `VERIFY_CMD` itself, then pushes `issue-<N>` and opens a draft PR for a human to merge.
3. Read the PR. The loop never merges.

Exit codes are 0 for any issue-level outcome, 1 for an infrastructure failure and 2 for a preflight problem; see [`patterns/issue-loop/README.md`](../patterns/issue-loop/README.md).

## 6. Optionally schedule it

Only after a hand-started run behaved. Re-run the cut with `--cron-every N`:

```bash
bash scripts/instantiate.sh issue-loop <project-dir> --profile work --verify-cmd '<the project check>' --cron-every 15
```

- It prints one crontab line; installing it is yours to do.
- Only the `pr` profiles (and `--land direct`) accept `--cron-every`.

## Where to go next

- How the loop is fed by triage: [gh-triage to issue-loop](gh-triage-to-issue-loop.md).
- Template contents and the charter files: [`project-factory/README.md`](../../project-factory/README.md).
- Roles, profiles and drift checks: [`agent-factory/README.md`](../../agent-factory/README.md).

Not yet scripted: see issue #21
