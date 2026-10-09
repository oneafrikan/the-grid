# Uplift runbook: running the-grid's overnight loop

How to run the-grid's unattended issue loop on your own Linux box, and the human steps the uplift changes leave to you. Replace every `<placeholder>` with your own value.

This runbook describes the uplift changes in `openspec/changes/*/` (13 changes). Commands marked "needs loops Phase A" only exist once the `loops` change is merged to your working branch. Commands in Section 4 are copied from each change's `tasks.md`; if a `tasks.md` changes later, the `tasks.md` wins.

## Prerequisites

- `loops` Phase A (the runner `run-issues.sh`, `instantiate.sh --profile linux`, `scripts/lib/render-schedule.sh`) merged to your working branch. Section 1 Part 1 needs no new code; Part 2 and Sections 2 and 3 need Phase A.
- The loop builds only the groups that are not marked HUMAN. Every HUMAN group is yours (Section 4).

## Names used below

| Placeholder | Meaning |
|---|---|
| `<box>` | the Linux machine that runs the loop (Ubuntu 24.04 was used for the design) |
| `<loop-user>` | a dedicated unprivileged OS user for the loop |
| `<machine-account>` | a separate GitHub account that only the loop uses |
| `<owner>/the-grid` | the repo the loop works on (base branch `next`) |
| `<operator-login>` | your own GitHub login (the trusted actor) |
| `<slug>` | `owner/name` with every character outside `[A-Za-z0-9_.-]` replaced by `-`, e.g. `<owner>-the-grid` |
| Env file | `~<loop-user>/.config/the-grid/issue-loop.env` (mode 600) |
| Run log (loop box) | `~<loop-user>/.the-grid-private/runs.jsonl` |

Working as the bot user (used throughout):

```bash
# interactive shell as the bot user, with a working `systemctl --user` (spec: loops tasks 5.2)
sudo machinectl shell <loop-user>@
# alternative once linger is on:
sudo -iu <loop-user>
export XDG_RUNTIME_DIR=/run/user/$(id -u)
```

---

# 1. Tonight: box and accounts setup

Run on the box over SSH. `[sudo]` marks a step that needs sudo. `[browser]` marks a step done on github.com.

Why so much isolation (loops design, Q1 and Q13): the worker runs with `--dangerously-skip-permissions`. It never holds a GitHub token. The runner pushes, opens PRs and relabels using a token that belongs to a machine account with write access only, behind a ruleset that requires a PR on `next`. The runner refuses to start if any of that is missing.

## Part 1: needs no new code

1. Open an SSH session to the box: `ssh <box>`.

2. `[sudo]` Create the dedicated loop user (loops task 5.2).
   ```bash
   sudo useradd -m -s /bin/bash <loop-user>
   ```
   Success: `id <loop-user>` prints the user.

3. `[sudo]` Prove the loop user cannot read your home.
   ```bash
   echo "$HOME"                       # note this path: it goes into LOOP_OPERATOR_HOME in step 10
   chmod 700 "$HOME"
   sudo -u <loop-user> ls "$HOME"     # must FAIL with "Permission denied"
   ```
   Success: the `ls` fails.

4. `[sudo]` Install Claude Code as the loop user and log in once. The install one-liner is from Anthropic's install docs, not from the specs: check the current command first.
   ```bash
   sudo -iu <loop-user>
   curl -fsSL https://claude.ai/install.sh | bash
   ~/.local/bin/claude          # first run: prints a login URL; open it in a browser, paste the code back, then /exit
   ~/.local/bin/claude auth status --text
   exit
   ```
   Success: `auth status` shows logged in. Its usage counts against the plan of the account you logged in with.

5. `[sudo]` Check the tools and that the loop user has no stored `gh` login. The runner needs `git`, `gh`, `jq` and `claude`, and refuses to run if the loop user has a stored `gh` login the worker could use.
   ```bash
   sudo -iu <loop-user>
   command -v git gh jq                      # all three must print a path; if one is missing: exit, then sudo apt install git gh jq
   gh auth status                            # must FAIL ("not logged in")
   git config --global user.name  "<machine-account>"
   git config --global user.email "<the machine account's noreply or own email>"
   exit
   ```
   Success: `gh auth status` fails; `git config --global --get user.email` is non-empty.

6. `[sudo]` Enable linger so the user timer fires while nobody is logged in.
   ```bash
   sudo loginctl enable-linger <loop-user>
   loginctl show-user <loop-user> --property=Linger --value
   ```
   Success: prints `yes`.

7. `[browser]` Create the GitHub machine account `<machine-account>`. Usernames are global: open `https://github.com/<machine-account>` first; a 404 means it is free, otherwise pick another name. Use a mailbox you control (a plus-alias of your own address works), enable two-factor, and keep the password out of the box. It must be a different account from `<operator-login>`: the runner refuses a token whose login is in `LOOP_TRUSTED_ACTORS`.

8. `[browser]` Add the machine account as a collaborator with Write on the repo, then accept the invite as the machine account.
   ```bash
   # as <operator-login> (use <operator-login>'s token, not another account's), or use Settings > Collaborators in the browser
   gh api -X PUT repos/<owner>/the-grid/collaborators/<machine-account> -f permission=push
   # then, signed in as <machine-account>: https://github.com/<owner>/the-grid/invitations  -> Accept
   ```
   Success (as <operator-login>): `gh api repos/<owner>/the-grid/collaborators/<machine-account>/permission --jq .permission` prints `write`.

9. `[browser]` Create the token FROM the machine account (signed in as `<machine-account>`). Try fine-grained first.
   - Settings > Developer settings > Personal access tokens > Fine-grained tokens > Generate.
   - Resource owner: pick `<owner>` if it is offered, then Repository access: only `<owner>/the-grid`. If only `<machine-account>` itself is offered as resource owner, the fine-grained route is closed: go to the fallback below.
   - Permissions: Contents read and write, Pull requests read and write, Issues read and write, Metadata read. Nothing else (no Workflows, no Administration).
   - UNVERIFIED (loops task 5.1a): whether a collaborator's fine-grained token can target a repo owned by another personal account. If `<owner>/the-grid` is not selectable, use the fallback: Tokens (classic) > scope `public_repo` only. The fallback is acceptable only because the machine account's sole access is this repo.
   - Copy the token once. Do not paste it into chat, a shell history line or a file other than the env file in step 10.

   Verify (this is the loops 5.1a check; run it before anything else that uses the token):
   ```bash
   read -rs -p 'PAT: ' PAT; echo
   GH_TOKEN="$PAT" gh api repos/<owner>/the-grid --jq .permissions     # push must be true, admin must be false
   GH_TOKEN="$PAT" gh api user --jq .login                     # must print <machine-account>
   unset PAT
   ```
   Success: `push: true`, `admin: false`, login is `<machine-account>`. If the fine-grained token fails this, redo it as classic and re-run the same check. Record which kind worked in the loops PR.

10. `[sudo]` Put the token in the env file. The runner PARSES this file (never sources it) and accepts only these three keys; the file must be mode 600 or the runner refuses to start.
    ```bash
    sudo -iu <loop-user>
    umask 077
    mkdir -p ~/.config/the-grid
    read -rs -p 'PAT: ' PAT; echo
    printf 'GH_TOKEN=%s\nLOOP_TRUSTED_ACTORS=%s\nLOOP_OPERATOR_HOME=%s\n' "$PAT" '<operator-login>' '<the $HOME value noted in step 3>' > ~/.config/the-grid/issue-loop.env
    unset PAT
    chmod 600 ~/.config/the-grid/issue-loop.env
    find ~/.config/the-grid/issue-loop.env -perm -077     # must print nothing
    sed 's/^GH_TOKEN=.*/GH_TOKEN=<hidden>/' ~/.config/the-grid/issue-loop.env
    exit
    ```
    Success: `find` prints nothing; the `sed` output shows the three keys with the token hidden. `LOOP_TRUSTED_ACTORS` is comma-separated; it is the list of logins whose labelling and edits the loop trusts. Only <operator-login> is listed. One env file serves one repo at a time: it holds the PAT for whichever repo the installed timer targets (see the callout after step 14).

11. `[browser]` Add the ruleset on `next` (repo owner's account). Settings > Rules > Rulesets > New ruleset > New branch ruleset.
    - Name `next-needs-pr`; Enforcement status: Active.
    - Bypass list: EMPTY (add nobody).
    - Target branches: Add target > Include by pattern > `next`.
    - Rules: tick "Require a pull request before merging". Required approvals can stay 0 (you merge the machine account's PRs yourself).
    - Create.

    Consequence: with an empty bypass list, nobody can push to `next` directly, you included. After this, spec and doc commits reach `next` through PRs. If you need a direct push, set the ruleset to Disabled for that moment and back to Active afterwards, never during the night.

    Verify (these are the loops 5.6 checks; both are UNVERIFIED API behaviours until you run them):
    ```bash
    read -rs -p 'PAT: ' PAT; echo
    GH_TOKEN="$PAT" gh api repos/<owner>/the-grid/rules/branches/next --jq '[.[] | select(.type=="pull_request")] | length'    # must print 1 or more
    GH_TOKEN="$PAT" gh api repos/<owner>/the-grid/branches/next/protection 2>&1 | head -3      # must fail with HTTP 403
    unset PAT
    # admin check, with <operator-login>'s own token: the same protection call must NOT fail with 403
    ```
    Success: the first prints 1 or more; the second shows `HTTP 403`. If the `protection` call succeeds for the PAT, the token has Administration access: recreate it.

12. `[sudo]` Copy the private leak-scan denylist for the loop user, if you keep one. Only this one file goes to the loop user, never a private repo.
    ```bash
    sudo -u <loop-user> install -d -m 700 ~<loop-user>/.the-grid-private
    sudo install -m 600 -o <loop-user> -g <loop-user> /path/to/denylist.txt ~<loop-user>/.the-grid-private/denylist.txt
    ```
    Success: the file is mode 600 and owned by the loop user. Without it, the gate with `GRID_REQUIRE_DENYLIST=1` fails the build instead of passing on the generic patterns alone.

## Part 2: needs loops Phase A merged to `next`

Gate: loops groups 1 to 4 are merged to `next`. Check from a clone: `git log --oneline next -- scripts/lib/render-schedule.sh automation-factory/patterns/issue-loop/run-issues.sh` lists commits. Until it does, stop after Part 1.

13. `[sudo]` Prove the runner on a sandbox repo first (loops group 5, Section 4 has the full text). The sandbox is a throwaway PUBLIC repo with a `next` branch, a PR-requiring ruleset with an empty bypass list, the machine account as collaborator, and two trivial issues. Do not skip this: loops task 5.8 says the-grid goes live only after 5.1 to 5.7 pass.

14. `[sudo]` Go live on the-grid (loops task 5.8). As the bot user:
    ```bash
    sudo -iu <loop-user>
    git clone https://github.com/<owner>/the-grid.git ~/the-grid        # https, not ssh: the runner refuses an ssh origin
    cd ~/the-grid
    git checkout next                                          # inferred: the loop code lives on next until release
    GH_TOKEN="$(sed -n 's/^GH_TOKEN=//p' ~/.config/the-grid/issue-loop.env)" gh auth setup-git
    bash scripts/instantiate.sh issue-loop . --profile linux --base-branch next --verify-cmd "GRID_REQUIRE_DENYLIST=1 bash scripts/gate.sh"
    bash loop/setup.sh
    ```
    Then fire one manual run on a single trivial issue labelled `ready-for-agent` (label it as <operator-login>), and look at the PR it opens before enabling the timer:
    ```bash
    systemctl --user start issue-loop-<owner>-the-grid.service
    journalctl --user -u issue-loop-<owner>-the-grid.service -n 50 --no-pager
    ```
    Only when that PR looks right, enable the timer (the activation command `instantiate.sh` printed):
    ```bash
    systemctl --user daemon-reload && systemctl --user enable --now issue-loop-<owner>-the-grid.timer
    systemctl --user list-timers issue-loop-<owner>-the-grid.timer
    ```
    Success: `list-timers` shows a NEXT time around 02:00 (the default `--schedule-hour` is 2, daily, `Persistent=true`, no random delay). Exit codes of the runner: 0 run finished, 1 infrastructure failure mid-run (stopped early), 2 preflight failed (nothing touched; the journal line names the fix).

    One env file, one repo: if you proved the sandbox with its own token in `issue-loop.env`, replace `GH_TOKEN` with the the-grid token (step 9) before the go-live run, and disable the sandbox timer (`systemctl --user disable --now issue-loop-<sandbox-slug>.timer`).

15. Before the first night, read the throughput and cost limits you are accepting (all from `loop.conf`; an environment variable of the same name overrides the file):
    - `MAX_ISSUES=3`: at most 3 issues per run, lowest issue number first. Raising it needs a systemd drop-in, not an edit of `loop/loop.conf` (editing a tracked file dirties the clone and the runner refuses a dirty tree). The unit's `TimeoutStartSec` is `MAX_ISSUES*(ISSUE_TIMEOUT+REVIEW_TIMEOUT)+600` seconds, so raise it with it:
      ```bash
      systemctl --user edit issue-loop-<owner>-the-grid.service
      # in the editor add:
      #   [Service]
      #   Environment=MAX_ISSUES=6
      #   TimeoutStartSec=15000      # 6*(1800+600)+600
      ```
      (inferred from the design: the conf form is `KEY=${KEY:-value}` and the unit is generated with that formula; confirm with `systemctl --user cat`.)
    - Worker cap `MAX_BUDGET_USD=5` per issue (issues labelled `ws:rule-packs` get 15), 30 minute timeout; Opus review cap 2 USD, 10 minute timeout.
    - Reviews are advisory PR comments. The runner never merges.

---

# 2. Every night

Order of work, the merge order (D9 in the specs). Nights are batches you promote; a group can only be built once the groups it "Depends on" are merged to `next` (see rule 1).

| Night | Promote (loop-buildable groups only) | Your HUMAN groups due first |
|---|---|---|
| Before N1 | none | depersonalise 1 (and prerequisites: foundations and loops Phase A merged to `next`) |
| N1 | depersonalise, vetting, budget-and-usage, workflow-upgrades | none |
| N2 | manifest-lock-install, hook-profiles, rule-packs | hook-profiles 0 (before the night starts) |
| N3 | instincts, loops Phase B, multi-harness | instincts 9.0 (before instincts group 3 is promoted) |
| After N3 | front-door, then plugin-marketplace | see Section 4 |

## Promote the issues for the night (evening)

Rules:

1. Promote a group only if every group in its "Depends on" line is already merged to `next`. The runner builds each issue from a fresh `origin/next`; a PR that is open but not merged is not in the base, so a dependent group would build without it. Big changes therefore take several nights, one dependency wave per night.
2. Never promote a HUMAN group.
3. Label as <operator-login>. The runner checks that the last person to apply `ready-for-agent` is in `LOOP_TRUSTED_ACTORS`; anything else ends `needs-human` with no model call.
4. Optional `role:<agent>` label routes the issue to a builder agent. Labels created by the instantiate step: `role:grid-backend-dev`, `role:grid-devops`, `role:grid-technical-writer`, `role:grid-sdet`, `role:grid-prompt-engineer`, `role:core-platform-engineer`. Read-only roles (for example `role:grid-qa-engineer`) end `blocked`.
5. Content issues for rule packs carry `ws:rule-packs` (cap 15 USD).

Commands (labels `backlog` and `ready-for-agent` exist on the repo today):

```bash
# list the candidates for one change; adjust the search to however the issues are titled
gh issue list --repo <owner>/the-grid --label backlog --search "<change> in:title" --json number,title,labels

# promote one issue (run with <operator-login>'s token)
gh issue edit <N> --repo <owner>/the-grid --add-label ready-for-agent --remove-label backlog

# what is queued for tonight, in the order the runner will take them (lowest number first)
gh issue list --repo <owner>/the-grid --label ready-for-agent --state open --json number,title --jq 'sort_by(.number)[] | "\(.number)\t\(.title)"'
```

Check before the first night: the repo already has issues labelled `ready-for-agent` that are not part of the uplift (#18, #19, #23, #25, #30, #31, #37, #41 when this was written). The runner takes the lowest numbers first, so #18, #19 and #23 would be built before anything you promote. Decide for each: leave, or `gh issue edit <N> --repo <owner>/the-grid --remove-label ready-for-agent`. Issues whose last labeller is not in `LOOP_TRUSTED_ACTORS` end `needs-human` (no model call) and use up a slot.

Success: the queue list shows only what you intend, and at most `MAX_ISSUES` (3 by default) will run.

## Check the timer and the logs

```bash
sudo machinectl shell <loop-user>@        # then, inside that shell:
systemctl --user list-timers issue-loop-<owner>-the-grid.timer           # NEXT and LAST fire times
systemctl --user status issue-loop-<owner>-the-grid.service               # last run result
journalctl --user -u issue-loop-<owner>-the-grid.service -n 100 --no-pager
journalctl --user -u issue-loop-<owner>-the-grid.service -f               # follow a run live
ls ~/the-grid/.git/issue-loop.lock 2>/dev/null && echo "a run is in progress"
loginctl show-user <loop-user> --property=Linger --value             # must be yes
```

The last journal line of a finished run is `done: X ok, Y skipped, Z error`. A run that exits 2 changed nothing; the line before it names the fix. A failed unit retries at the next timer fire.

## How to stop it

1. Skip tonight only, keep the timer: `systemctl --user stop issue-loop-<owner>-the-grid.timer` (re-arm with `start`).
2. Turn it off: `systemctl --user disable --now issue-loop-<owner>-the-grid.timer`.
3. Abort a run in progress: `systemctl --user stop issue-loop-<owner>-the-grid.service`. The unit kills every child process; the runner removes its worktree and lock on exit.
4. Nothing to build: remove the label, `gh issue edit <N> --repo <owner>/the-grid --remove-label ready-for-agent`.
5. Full kill switch: Section 5.

---

# 3. Every morning

## Review the PRs on `next`

```bash
gh pr list --repo <owner>/the-grid --base next --state open --json number,title,headRefName,statusCheckRollup
gh pr view <PR> --repo <owner>/the-grid --comments          # Opus review: [blocker] / [should-fix] / [nit] bullets, then VERDICT line (advisory only)
gh pr checks <PR> --repo <owner>/the-grid                    # the `tests` CI run on the PR
gh pr diff <PR> --repo <owner>/the-grid
```

Issues the loop is waiting on you for, by label:

```bash
gh issue list --repo <owner>/the-grid --label ready-for-human --state open     # PR opened, needs your review and merge
gh issue list --repo <owner>/the-grid --label needs-human --state open         # ambiguous, or the trust gate refused it
gh issue list --repo <owner>/the-grid --label blocked --state open             # build failed, timed out, hit max turns, push rejected, or unwired/read-only role
```

## Read the run records

Each issue the runner touches writes one JSON line: `ts, host, role, operator, action, target, outcome, cost_usd, note` (`outcome` is `ok`, `error` or `skipped`; `role` is the routed agent, else `issue-loop`; `action` is `work-issue`).

```bash
sudo cat ~<loop-user>/.the-grid-private/runs.jsonl | tail -30 \
  | jq -r 'select(.action=="work-issue") | [.ts,.role,.target,.outcome,.cost_usd,.note] | @tsv'

# spend since a date
sudo cat ~<loop-user>/.the-grid-private/runs.jsonl \
  | jq -s '[.[] | select(.ts >= "2026-10-10")] | {runs: length, usd: (map(.cost_usd // 0) | add)}'
```
Recording is best-effort: a missing line does not mean the issue was not touched, check the issue and PR too. See `docs/agent-retro.md` for the review loop that starts from these lines.

## Handle `needs-human` and `blocked`

1. Read the comment the runner left on the issue (reasons are cut to 500 bytes). It names the cause.
2. `needs-human`: the issue was ambiguous, or the trust gate refused it (author not owner/member/collaborator, label applied or body edited by someone outside `LOOP_TRUSTED_ACTORS`, or the title was renamed by one). Fix the issue text, then relabel as <operator-login>: `gh issue edit <N> --repo <owner>/the-grid --remove-label needs-human --add-label ready-for-agent`.
3. `blocked`: the worker did not finish cleanly (no commit, dirty tree, timeout, max turns, push rejected, unwired or read-only `role:` label, two `role:` labels). Options: split the issue, build it by hand, or retry after fixing the cause. Raising a cap means `LABEL_BUDGETS` or `MAX_BUDGET_USD`, set as in Section 1 step 15.
4. A retry is skipped while branch `issue-<N>` exists on the remote or a PR is open for it. After closing a bad PR: `git push origin --delete issue-<N>` (from a clone you own), then relabel.

## Merge order

1. Merge in this order (D9 in the specs): foundations, depersonalise, vetting, budget-and-usage, workflow-upgrades, manifest-lock-install, hook-profiles, rule-packs, loops (Phase A before everything; Phase B after instincts), instincts, multi-harness, front-door, plugin-marketplace.
2. Inside a change, merge in group-number order, respecting each group's "Depends on".
3. Merge them yourself (the machine account's PRs need your merge; the loop's guard blocks `gh pr merge`). Use one merge style throughout so any PR can be reverted the same way.
4. After each merge, on a machine you trust: `git pull`, then `bash scripts/gate.sh`. A red gate on `next` stops the next night's promotions.
5. When a merge makes a HUMAN group due (Section 4 gives the trigger), do that group before promoting anything that depends on it.

## Recompose and rewire after merges, per machine

Do this on every machine that runs the-grid, not just where you merged. From the-grid's own "Existing machine" sequence:

```bash
cd ~/.the-grid
git pull
git submodule update --init --recursive
git diff --stat HEAD@{1} HEAD -- agent-factory/       # anything listed => recompose
ls agent-factory/projects/                              # compare with the project: gates in machines/$(hostname -s).txt before recomposing
cd agent-factory
.venv/bin/python compose.py examples/core.yaml --target claude-code
.venv/bin/python compose.py examples/grid.yaml --target claude-code
.venv/bin/python compose.py examples/finance-desk.yaml --target claude-code
cd .. && bash scripts/wire.sh                           # always last
```

- Recompose every private project in the same pass. `compose.py` overwrites `projects/<name>/` wholesale; recomposing only the public three while a private project's roles are unreachable destroys that project's output.
- After the `vetting` changes land, `wire.sh` runs an audit first and exits 3 on a high finding without changing anything. Fix it, add a reasoned `audit-allow` entry in `CURATION.md`, or run `GRID_AUDIT=warn bash scripts/wire.sh` once.
- After `foundations` group 5, `wire.sh` prints `runtime MISSING` until foundations HUMAN group 6 has run on that machine.
- The loop box's clone (`~/the-grid`) runs the loop from its own checkout. Pull it only when `loop/` or its hooks changed, and only while no run is in progress: `sudo -iu <loop-user> git -C ~/the-grid pull --ff-only`. The runner refuses to start on a dirty tree.

---

# 4. All human steps by change

Every group labelled HUMAN across the 13 changes, in merge order. The "Source text" blocks are copied from each `tasks.md` unchanged; the "Due" and "Success check" lines are added here. `manifest-lock-install` has no HUMAN group.

Do not promote a HUMAN group to `ready-for-agent`; the loop cannot do them.

### loops, group 5: Prove the runner on a sandbox repo

**Due:** Tonight and the following days, BEFORE the first overnight run. 5.1a to 5.2 need only the box and accounts (Section 1, Part 1). 5.2 `instantiate.sh` onward needs loops groups 1 to 4 merged to `next`. Group 4 must be merged first.

**Source text (verbatim from `openspec/changes/loops/tasks.md`):**

Depends on: 4.

HUMAN: needs the operator at the keyboard of the Ubuntu 24.04 box with sudo (creates the dedicated loop user, a GitHub repo, a fine-grained PAT and rulesets, enables linger).

Files: none in the-grid (sandbox repo is throwaway) except fixes to `run-issues.sh` if 5.6 finds a mismatch; append to `design.md` Decisions only if a Decided: item turns out wrong.

Acceptance: all of these observed and pasted into the PR: everything runs as the dedicated loop user, which cannot list the operator's HOME; a sandbox repo with `next` (PR-requiring ruleset) and two trivial issues labelled `ready-for-agent` becomes two PRs to `next` opened by the runner (the worker's environment had no token), each with an Opus review comment, issues relabelled `ready-for-human` and still open, two lines in the run log, no worktrees left; `systemctl --user start issue-loop-<slug>.service` repeats the cycle on a fresh pair of issues while the operator is logged out of desktop sessions; a `role:grid-backend-dev` issue is built with `--agent` (journal shows it) and its run record role is `grid-backend-dev`; a `role:grid-qa-engineer` issue ends `blocked` with no model call; an ambiguous issue ends `needs-human`; an issue authored by a non-collaborator ends `needs-human` with no model call; every 5.6 check recorded; a failing verify command ends `blocked` with a clean tree.

Verify: the observations above; then `bash scripts/gate.sh` unchanged.

- [ ] 5.1a FIRST, before any other 5.x step (UNVERIFIED: whether a fine-grained PAT created by a collaborator machine account can target a repo owned by another personal account): create the machine account, add it as a collaborator with write on the target repo, create a fine-grained PAT from it scoped to that repo, and run `GH_TOKEN=<pat> gh api repos/<R> --jq .permissions`; it must show `push: true` and `admin: false`. If the fine-grained PAT cannot select the repo, apply the classic-PAT fallback Decided line (Q13) in design.md and re-run the check with that token. Record the result in the PR.
- [ ] 5.1 Operator creates the sandbox repo (PUBLIC, so rulesets are free), a `next` branch, a ruleset targeting `next` that requires a pull request with an EMPTY bypass list, a separate GitHub machine account (not the operator; Operator confirmed 2026-10-09 (Q13: default accepted)) added as a collaborator with write on the sandbox, a fine-grained PAT created FROM that machine account for that repo only (Contents, Pull requests, Issues read-write; Metadata read; nothing else), and two issues ("Add a line `hello` to README.md", "Add a file `hello.txt` containing `hi`") labelled by the operator.
- [ ] 5.2 Operator, once, on the box: `sudo useradd -m -s /bin/bash <loop-user>` (name of their choice); `chmod 700` the operator's own HOME and confirm `sudo -u <loop-user> ls <operator-home>` fails; as the loop user (`sudo -iu <loop-user>`): install the native `claude` and log in once interactively (`~/.local/bin/claude auth status --text` shows logged in); confirm `gh auth status` fails (no stored login); clone the sandbox over https; set `git config --global user.name`/`user.email`; create `~/.config/the-grid/issue-loop.env` (mode 600) with `GH_TOKEN=<PAT>`, `LOOP_TRUSTED_ACTORS=<operator login>`, `LOOP_OPERATOR_HOME=<operator home>`; `GH_TOKEN=<PAT> gh auth setup-git`; run `instantiate.sh issue-loop <clone> --profile linux --base-branch next --verify-cmd "test -f README.md" --role-labels grid-backend-dev` and `bash loop/setup.sh`. Then `sudo loginctl enable-linger <loop-user>`; for `systemctl --user` as that user use `sudo machinectl shell <loop-user>@` (or export `XDG_RUNTIME_DIR=/run/user/$(id -u)` after linger).
- [ ] 5.3 Dry run as the loop user from a stripped environment that mimics systemd (`env -i HOME="$HOME" PATH=/usr/bin:/bin bash loop/run-issues.sh` inside `sudo -iu <loop-user>`, from the clone) so the PATH append, env-file parse and per-call token are exercised without a login profile; inspect PRs (opened by the runner), comments, labels, run log. Also open one issue from a second, non-collaborator account and label it as the operator: it must end `needs-human` with no model call.
- [ ] 5.4 Fire via systemd: enable the timer, `systemctl --user start` the service on two fresh issues plus the role issues; check `journalctl --user -u <service>`. Then prove the timer itself, not just the service: add a drop-in (`systemctl --user edit <timer>` with an empty `OnCalendar=` line followed by `OnCalendar=*-*-* HH:MM:00` two minutes ahead), `systemctl --user list-timers` shows it, log out of every session (linger on), and confirm in `journalctl --user -u <service>` after the time that the run happened; remove the drop-in. Record `loginctl show-user "$USER" --property=Linger --value` (must be `yes`).
- [ ] 5.5 Check `--agent` with `--model`: run `claude -p --agent grid-backend-dev --model haiku --max-budget-usd 0.1 --output-format json "Reply with the model you are"` and read `.modelUsage` (or equivalent) in the JSON; record which wins (agent `model:` frontmatter or `--model`). If the agent's frontmatter wins, record it as a Decided: item and set `WORKER_MODEL` to match the agents' `model:` so the cap stays explicit.
- [ ] 5.6 On the box's claude version, verify and record in the PR description (fix `run-issues.sh` or the Decided lines if any differ): `claude auth status --json` has `.loggedIn`; the `-p --output-format json` field names the runner parses (`is_error`, `subtype`, `total_cost_usd`); whether `--max-turns` is listed; that `--max-budget-usd` is honoured under a subscription login (a 0.01 cap ends the call early); that with `--setting-sources project,local --strict-mcp-config --mcp-config '{"mcpServers":{}}'` the `--settings` guard hook still blocks `git push origin next` (journal/hook log) and `--agent grid-backend-dev` still resolves from `~/.claude/agents` (else apply the repo-`.claude/agents` fallback Decided line); that `GH_TOKEN=<PAT> git push` over https works through the `gh auth setup-git` helper; that `gh api repos/R/rules/branches/next` lists the `pull_request` rule with the PAT; that `gh api repos/R/branches/next/protection` fails with `HTTP 403` for the PAT and does not for an admin token (`gh auth token` of the operator).
- [ ] 5.7 Check whether `GRID_REQUIRE_DENYLIST=1 bash scripts/gate.sh` passes inside a bare worktree of the-grid (no submodules, no venv); if not, apply the fallback in design.md Decisions to the-grid's `loop/loop.conf`.
- [ ] 5.8 the-grid go-live (after 5.1–5.7 pass): on the-grid repo add a ruleset requiring a pull request on `next` with an EMPTY bypass list; add the machine account from 5.1 as a collaborator with write on the-grid and create a fine-grained PAT FROM it scoped to the-grid only (same permissions as 5.1; never the operator's account, preflight refuses a token whose login is in `LOOP_TRUSTED_ACTORS`); as the loop user clone the-grid over https, create its env file (three keys), copy ONLY `denylist.txt` from the private repo to the loop user's `~/.the-grid-private/denylist.txt` (SEC14a: `GRID_REQUIRE_DENYLIST=1` fails the build without it), run `instantiate.sh issue-loop . --profile linux --base-branch next --verify-cmd "GRID_REQUIRE_DENYLIST=1 bash scripts/gate.sh"` (loop.conf already tracked, left alone) and `bash loop/setup.sh`, then one manual `systemctl --user start issue-loop-<slug>.service` on a single trivial labelled issue; record the PR it opens. Enable the timer only after that PR looks right.

**Success check:** Every observation in the Acceptance block above, pasted into the loops PR; then `bash scripts/gate.sh` unchanged.

### depersonalise, group 1: archive personal material into the private repo

**Due:** BEFORE night N1. No dependencies, and depersonalise group 3 depends on it. Only you can do it: the loop has no access to the private repo.

**Source text (verbatim from `openspec/changes/depersonalise/tasks.md`):**

Needs the private repo checkout and the operator's own strings; commits to a second repo, so not for the unattended loop. No public PR.

Files (all under `~/.the-grid-private/`): `archive/clawguides/`, `archive/design/`, `archive/prompts/`, `archive/MANIFEST.sha256`, `LOGS/todo-done-history.md`, `denylist.txt`.

Acceptance: `cd ~/.the-grid-private/archive && sha256sum -c MANIFEST.sha256` (macOS: `shasum -a 256 -c`) prints OK for every line; `git -C ~/.the-grid-private status -sb` shows the commit pushed.

Verify: the two commands above.

Depends on: none.

- [ ] 1.1 Copy `__assets/ClawGuides.zip` and the `__assets/ClawGuides/` tree to `archive/clawguides/` (preserve structure, byte-exact).
- [ ] 1.2 Copy `agent-factory/docs/openclaw-paperclip-targets-plan.md`, `docs/openclaw-portfolio-desk-blueprint.md`, `automation-factory/docs/gh-triage-to-issue-loop.md` to `archive/design/`; copy `prompts/2026-06-13-openclaw-lamp-team-prompt.md` to `archive/prompts/`.
- [ ] 1.3 Cut the "Pending rollout" paragraph and the whole "Status: Done" section out of `TODO.md` into `LOGS/todo-done-history.md`, verbatim (the cut itself happens in public in group 3; here only save the text).
- [ ] 1.4 Write `archive/MANIFEST.sha256` (relative paths, one line per archived file) and commit + push the private repo.
- [ ] 1.5 Write `denylist.txt` in the format given in `design.md` (kind, scope, label, regex): every machine host name, work/employer and personal-project names, GitHub handles other than the public owner, family and third-party private names, private product and infrastructure names that appear in the current tree. Use `deny-i` with `\b...\b` for words that collide with ordinary English or other skill names, and check them against `git grep` before saving. Commit + push.

**Success check:** `cd ~/.the-grid-private/archive && sha256sum -c MANIFEST.sha256` (macOS: `shasum -a 256 -c MANIFEST.sha256`) prints OK for every line; `git -C ~/.the-grid-private status -sb` shows the commit pushed.

### foundations, group 6: gstack runtime setup on each machine

**Due:** After foundations groups 4 and 5 are merged to the working branch and pulled on the machine. Repeat on every machine.

**Source text (verbatim from `openspec/changes/foundations/tasks.md`):**

Depends on: 4, 5 merged to the working branch and pulled on the machine.

Files: none (run on each machine).

- [ ] 6.1 Prerequisites: `bun` installed (`./setup` exits with checksum-verified install instructions otherwise); network for Playwright Chromium (roughly 150 MB to 300 MB).
- [ ] 6.2 Back up the Claude settings file (`cp ~/.claude/settings.json ~/.claude/settings.json.pre-gstack`). If `~/.claude/skills/gstack` exists and is not a symlink to `<grid>/repos/gstack` (an earlier standalone gstack install), remove it first (`rm -rf ~/.claude/skills/gstack` after checking it holds nothing you want); the wrapper exits 2 until it is gone. Note that setup also persists gstack's own config under `~/.gstack/` (`skill_prefix`, `timeline_stop_hook`) and caches Playwright Chromium outside `~/.claude`; the settings check does not cover those.
- [ ] 6.3 `git pull`, `git submodule sync --recursive`, `git submodule update --init --recursive`.
- [ ] 6.4 `bash scripts/runtime-setup.sh gstack`. It runs `./setup --host claude --no-prefix --no-team --no-plan-tune-hooks --no-timeline-stop-hook -q`, aborts with exit 3 if the settings file changed, removes setup's flat skill dirs, and re-wires.
- [ ] 6.5 Verify: `bash scripts/wire.sh` prints no `runtime MISSING`; `test -x repos/gstack/browse/dist/browse`; `ls -l ~/.claude/skills/gstack` is a symlink to `repos/gstack`; `diff ~/.claude/settings.json ~/.claude/settings.json.pre-gstack` shows nothing; `repos/gstack/bin/gstack-settings-hook list-sources` lists no gstack sources; `git -C repos/gstack status --short` is empty (report any dirt, do not commit it).
- [ ] 6.6 In a throwaway repo, run `/browse` or `/qa` once and confirm the browse daemon starts.
- [ ] 6.7 Do this on each machine (macOS, Ubuntu, Arch). On Linux without the emoji font, `make-pdf` shows tofu for emoji; opt in with `GSTACK_SKIP_FONTS=0 bash scripts/runtime-setup.sh gstack` if sudo is acceptable.

Acceptance: 6.5 all true on each machine.

**Success check:** 6.5 all true on each machine (`bash scripts/wire.sh` prints no `runtime MISSING`; `test -x repos/gstack/browse/dist/browse`; the settings diff is empty).

### foundations, group 7: post-merge verification (Pages and catalogue)

**Due:** After foundations groups 2, 3 and 9 are merged to `main` (not `next`). Needs a `next` to `main` promotion first, see Open questions at the end of Section 4.

**Source text (verbatim from `openspec/changes/foundations/tasks.md`):**

Depends on: 2, 3, 9 merged to `main`.

Files: `SKILLS.md` (regenerated), none otherwise. One repo-settings change (7.2).

- [ ] 7.0 Apply the same mattpocock renames and deletions, and delete `-openspec/release-openspec`, in the personal `baseline-submodules.txt` and any machine overlay that lists them (gitignored, not committed).
- [ ] 7.1 On a machine with a personal `baseline-submodules.txt`, run `bash scripts/wire.sh` (regenerates `SKILLS.md`), then `bash scripts/gate.sh`; commit the regenerated `SKILLS.md`.
- [ ] 7.2 Switch the Pages source to GitHub Actions: repo Settings, Pages, Source = "GitHub Actions" (or `gh api -X PUT repos/<owner>/<repo>/pages -f build_type=workflow`, using the token of the account that owns the repo). Then re-run the latest `pages` workflow run on `main` (`gh run rerun <id>`, or `gh workflow run pages --ref main`).
- [ ] 7.3 After that run, check the `pages` run concluded `success` (`gh run list --workflow pages --branch main --limit 1`) and `curl -sI <pages-url> | head -1` is `200` (the repo is under a personal account: use that account's token for `gh`). Also confirm a push to `next` started a `tests` run (`gh run list --branch next --limit 1`), and confirm `repos/` is not served (`curl -sI <pages-url>repos/` returns 404).
- [ ] 7.4 If the `pages` run fails, open an issue with the failing step's log excerpt. Do not fix it inside this change; the legacy source with `.nojekyll` can be restored by switching the source back.
- [ ] 7.5 Confirm CI is green on `main` and that the ECC section count in `SKILLS.md` equals `find_skill_mds repos/ecc | wc -l` (source `scripts/lib/find-skill-mds.sh`).

Acceptance: Pages source is "GitHub Actions", the site returns 200 and `repos/` returns 404 (or the 7.4 issue exists); `SKILLS.md` committed and `bash scripts/catalog.sh --check` passes.

**Success check:** Pages source is "GitHub Actions"; `curl -sI <pages-url> | head -1` is 200; `repos/` returns 404; `bash scripts/catalog.sh --check` passes.

### depersonalise, group 7: close-out

**Due:** After depersonalise group 6 is merged to `next`.

**Source text (verbatim from `openspec/changes/depersonalise/tasks.md`):**

- [ ] 7.1 Comment on #42: the OpenClaw target is now genericised; personas and a parameterised deploy script remain; issue stays open. Comment on #54: the only constraint applied was "values stay local"; persona fields and voice layer remain; issue stays open.
- [ ] 7.2 Decide whether to rewrite history for the moved paths (single `git filter-repo` pass) and whether anything in the old files was ever a live credential needing rotation.
- [ ] 7.3 Decide whether GitHub issue titles that name hosts should be edited.
- [ ] 7.4 Confirm the loop box has `~/.the-grid-private/denylist.txt` (private repo cloned) so the denylist half of the gate runs there; with `GRID_REQUIRE_DENYLIST=1` in the loop's `VERIFY_CMD` environment a missing file fails the build rather than passing on generic patterns only.

Depends on: 6.

**Success check:** Comments posted on #42 and #54; 7.2 and 7.3 decisions noted; the loop box has `denylist.txt` (derived check: `sudo -u <loop-user> test -f ~<loop-user>/.the-grid-private/denylist.txt && echo ok`).

### vetting, group 4: CURATION.md and first-run triage of the real wired set

**Due:** After vetting groups 1, 2 and 3 are merged to `next`, on a machine with every submodule initialised and a real `baseline-submodules.txt`.

**Source text (verbatim from `openspec/changes/vetting/tasks.md`):**

Depends on: 1, 2, 3. Needs a machine with all submodules initialised and a real `baseline-submodules.txt`. The agent drafts everything; the operator reviews trust rationale and every allowlist reason before merge.

Files: `CURATION.md`, `policy.yaml` (`sources.allowed_repos` and rule tuning only), `tests/test_curation.bats`.

- [ ] 4.1 Run `bash scripts/audit.sh --wired`, `--owned`, and `GRID_BASELINE=baseline-submodules.example.txt GRID_HOST=__baseline__ bash scripts/audit.sh --gate` (what CI will run). For every `high`: if the same false-positive class hits 3+ places, fix the rule in `policy.yaml` (`ignore_regex` or `downgrade`) and append a row to the `# regression rows` section of `tests/test_audit.bats` (same `expect_row` format as the design's fixture table); otherwise add an `audit-allow` entry with a specific reason. A high that is a TRUE positive (real malicious or unsafe behaviour) is not allowlisted: stop, mark the group `blocked`, and report the file:line in the PR description. Known items to triage: the owned `skills/openspec-help/SKILL.md:111` `@latest` (pin the version in that line, preferred, or allowlist with reason); confirm the narrowed SEC8 executed-substitution form leaves the ~10 capture-only `$(curl ...)` lines unflagged; SEC7 fenced-block raises in upstream docs. Allowlist entries for regex rules always carry `contains`; builtin entries without `contains` carry a literal path and `sha256` copied from the JSON finding.
- [ ] 4.2 Write `CURATION.md` in the format in design.md: a `### repos/<name>` section for every repo in `baseline-submodules.example.txt` and every repo wired on this machine (factual lines only: upstream URL, pin policy, why trusted, accepted behaviours, last audited date and counts), `### owned`, an `## Exclusions` table (include: `openspec/release-openspec` maintainer-only; gstack OpenClaw/GBrain tools and `benchmark-models` left to machine overlays; `repos/ecc` library tier with the unpinned-`npx -y` count; anything the triage in 4.1 removed from the wired set), and the `audit-allow` block from 4.1. No private paths, hostnames or personal data; do not link the private research repo.
- [ ] 4.3 Set `sources.allowed_repos` in `policy.yaml` to cover exactly those repos (owner/repo form).
- [ ] 4.4 Run the scanner once over ECC's `hooks/`, `scripts/hooks/`, `plugins/` and MCP configs (`python3 scripts/audit.py --root repos/ecc ...` or the equivalent direct paths) and record the expected findings in the ECC row of `## Exclusions` or its `### repos/ecc` note.
- [ ] 4.5 Write `tests/test_curation.bats` (runs in CI without baseline): `CURATION.md` exists; `audit.py` can parse its allowlist (no exit 2 on an empty scan); every repo returned by `audit.baseline_repos(baseline-submodules.example.txt)` (imported, not re-parsed with awk, so typed entries are skipped identically) has a `### repos/<name>` heading and its URL (from `.gitmodules`) passes `audit.py --check-url`.
- [ ] 4.6 Verify: `bash scripts/audit.sh --wired --quiet; echo $?` and the example-baseline `--gate` command from 4.1 both print 0 on the machine; `tests/lib/bats-core/bin/bats tests/test_curation.bats`; `bash scripts/gate.sh`.

**Success check:** `bash scripts/audit.sh --wired --quiet; echo $?` prints 0; the example-baseline `--gate` command from 4.1 prints 0; `tests/lib/bats-core/bin/bats tests/test_curation.bats`; `bash scripts/gate.sh`.

### budget-and-usage, group 8: install schedules, set retention, review and apply the first prune

**Due:** After budget-and-usage groups 2, 3, 4, 6 and 7 are merged to `next`. Repeat on each machine.

**Source text (verbatim from `openspec/changes/budget-and-usage/tasks.md`):**

Depends on: 2, 3, 4, 6, 7 merged to `next`.

Files: none in the repo. Per machine: `~/.claude/settings.json`; the local `baseline-submodules.txt` and `machines/<host>.txt` (gitignored, personal).

- [ ] 8.1 On each machine: `git pull`, recompose agents (public projects and any private project, per CLAUDE.md "Existing machine" step 3), `bash scripts/wire.sh`.
- [ ] 8.2 Add `"cleanupPeriodDays": 60` to `~/.claude/settings.json` on each machine.
- [ ] 8.3 Run `bash scripts/usage/install-schedule.sh` on each machine and run the activation commands it prints (on headless Linux also the printed `loginctl enable-linger`). Run `bash scripts/usage/weekly.sh` once by hand and confirm `usage/<host>.json` reaches the private repo's remote.
- [ ] 8.4 After at least 4 weeks of data from at least 2 machines, run `bash scripts/prune-report.sh --out "$HOME/.grid/prune.md"`, read it, and choose which numbered proposals to apply. Apply by editing `baseline-submodules.txt` or `machines/<host>.txt`, or pasting the `skillOverrides` block, then `bash scripts/wire.sh` and `python3 scripts/budget.py --update-target` (targets only go down).
- [ ] 8.5 Check the next weekly file: `listing` in `usage/<host>.json` shows fewer chars and dropped skills stay dropped.

Acceptance: every machine has a weekly `usage:` commit in the private repo; a decision (apply or skip) is recorded for each prune proposal.

Verify: `python3 scripts/budget.py --report` on each machine, plus `git -C ~/.the-grid-private log --oneline -- usage/`.

**Success check:** `python3 scripts/budget.py --report` on each machine, and `git -C ~/.the-grid-private log --oneline -- usage/` shows a weekly `usage:` commit for every machine.

### workflow-upgrades, group 6: read the wording, install the aliases, recompose

**Due:** After workflow-upgrades groups 1, 3 and 4 are merged to `next`. Steps 6.2 and 6.3 repeat on each machine.

**Source text (verbatim from `openspec/changes/workflow-upgrades/tasks.md`):**

Depends on: 1, 3, 4.

- [ ] 6.1 HUMAN: read `contexts/{dev,research,review}.md`, `agent-factory/_core/DECISION_BRIEF.md` and tech-lead Step 6; edit anything that does not sound right.
- [ ] 6.2 HUMAN: on each machine, add the `source` line from the header of `contexts/aliases.sh` to the shell rc.
- [ ] 6.3 HUMAN: after pulling, recompose and re-wire on each machine (`compose.py` for every public and private config, then `bash scripts/wire.sh`).

Acceptance: `claude-review` starts a session on each machine. Verify: `type claude-review` in a new shell.

**Success check:** `type claude-review` in a new shell on each machine.

### hook-profiles, group 0: capture real payloads, transcript shapes and CLI facts

**Due:** BEFORE night N2 (it blocks hook-profiles groups 1 and 3). No dependencies. Costs about three cheap haiku calls.

**Source text (verbatim from `openspec/changes/hook-profiles/tasks.md`):**

Operator confirmed 2026-10-09 (Q12: default accepted) — run this group (about three cheap haiku calls). If answered no, skip it: group 1 task 1.9 hand-writes the fixtures instead and groups 1 and 3 no longer depend on 0.

Depends on: none. Blocks groups 1 and 3. Cost: about three `--model haiku` calls, each capped at a few cents. Run everything in a scratch directory and a scratch git repo; pass hooks with `--settings <scratch file>` so no real settings file is edited.

- [ ] 0.1 Record `claude --version`. Write a scratch settings file with a `PreToolUse` (matcher `Bash`) command hook and a `SessionEnd` command hook that each run `cat > "$SCRATCH/<event>.json"`. In the scratch git repo run `claude -p "run the shell command: git status" --model haiku --allowedTools "Bash(git status:*)" --settings <scratch file> --max-budget-usd 0.10`. If the `SessionEnd` file is not written under `-p`, repeat once interactively (one prompt, then `/exit`).
- [ ] 0.2 Files: `tests/fixtures/hooks/pretooluse-bash.json` and `tests/fixtures/hooks/sessionend.json` from 0.1. Keep every key exactly as captured; set values to `session_id` `00000000-0000-4000-8000-000000000000`, `transcript_path` `/tmp/transcript.jsonl`, `cwd` `/tmp/project`, and the Bash `command` `git status`; any other value that is a path, id or timestamp gets a neutral constant.
- [ ] 0.3 Files: `tests/fixtures/hooks/shapes/<kind>.json` for each kind `human-string`, `human-blocks`, `tool-result`, `assistant-text`, `assistant-bash-tool`, `assistant-skill-tool`, `assistant-write-handoff`, `slash-handoff`, `meta-user`, `sidechain-user`, `attachment`. Each is ONE real transcript line (from `~/.claude/projects/<scratch project>/*.jsonl` after the runs in 0.1 and 0.4), with every free-text value replaced by the string `__TEXT__` and every id, timestamp, `cwd` and path replaced by a neutral constant. A kind that no run produced (for example `sidechain-user` without a subagent run) is written by hand from the nearest real line and listed as hand-built in the README.
- [ ] 0.4 Headless feasibility, in the scratch repo with a `LOGS/` directory: run `claude -p "/handoff scratch test" --model haiku --max-budget-usd 0.25 --permission-mode acceptEdits --tools "Read,Write,Bash" --allowedTools "Read" "Write(<scratch repo>/LOGS/**)" "Write(<scratch fallback dir>/**)" "Bash(hostname:*)" "Bash(realpath:*)" "Bash(readlink:*)" "Bash(ls:*)" "Bash(date:*)" --disallowedTools "Edit" "Bash(git:*)"` (the design's child tool set; no bare `Write`). Record: did the skill run under `-p`, did both `*-handoff.md` and `*-context.md` appear in `LOGS/`, was any tool permission denied, and which tool (if any) outside `Read,Write,Bash` it needed. Then run `claude -p "reply ok" --model haiku --max-turns 3 --max-budget-usd 0.05` and record accepted or rejected (an unknown option fails before any model call). Its transcript supplies the `slash-handoff` and `assistant-skill-tool` shapes for 0.3.
- [ ] 0.6 Path-scoped Write enforcement (required even if Q12 drops the rest of this group): with the same tool flags as 0.4, run `claude -p "write the word x to <scratch repo>/outside.txt, then to <scratch repo>/LOGS/inside.txt" --model haiku --max-budget-usd 0.05`. Record enforced yes/no: yes only if `outside.txt` does not exist, `LOGS/inside.txt` does, and the denial shows in the output. If no, retry once with the `//<absolute path>/**` rule form and record which form (if any) is enforced.
- [ ] 0.5 Create `tests/fixtures/hooks/README.md`: CLI version and date, the 0.4 results (skill runs headless yes/no with the design's tool set, extra tool needed or none, `--allowedTools` patterns accepted yes/no, `--max-turns` accepted yes/no), the 0.6 result (path-scoped Write enforced yes/no, and the rule form that worked), how each file was captured, which shapes were hand-built, and the rule "re-capture after a Claude Code upgrade when the payload-conformance test fails".
- Stop rule: if 0.4 shows the skill does not run under `-p` even with one extra tool, or the patterns are rejected, or 0.6 shows path-scoped Write is not enforced headless in either form, mark the group `blocked` and report; group 3 is blocked and the auto-handoff design needs rethinking.
- Acceptance: `for f in tests/fixtures/hooks/*.json tests/fixtures/hooks/shapes/*.json; do jq empty "$f" || echo BAD "$f"; done` prints nothing, `grep -rEl '/Users/|/home/' tests/fixtures/hooks` prints nothing, and the README states the three 0.4 facts and the 0.6 result.
- Verify: `bash scripts/gate.sh`

**Success check:** The `jq empty` loop and the `grep -rEl` check in the Acceptance line both print nothing, and the fixtures README states the three 0.4 facts and the 0.6 result.

### hook-profiles, group 5: handoff parity check and rollout

**Due:** After hook-profiles groups 1, 2, 3 and 4 are merged to `next`.

**Source text (verbatim from `openspec/changes/hook-profiles/tasks.md`):**

Depends on: 1, 2, 3, 4 merged to `next`.

- [ ] 5.1 HUMAN: pick three past sessions of different kinds. Run `GRID_AUTOHANDOFF_FORCE=1 hooks/lib/auto-handoff-worker.sh` by hand against each transcript (`GRID_HOOK_LOG_DIR`, `GRID_HOOK_STATE_DIR`, `GRID_HANDOFF_FALLBACK_DIR` and `GRID_PRIVATE_DIR` set to scratch dirs, `cwd` a scratch clone with no upstream, so nothing real is committed or pushed; FORCE is needed because these sessions had a manual handoff) and compare each auto handoff against the one written manually: same template sections, same decisions captured, no missing facts. Also run it once WITHOUT `GRID_AUTOHANDOFF_FORCE` on a session that had a manual handoff and confirm the log says `reason=already-ran` (proves the detection signals match real transcripts). Also confirm every key in design.md "Transcript key contract" appears with the stated meaning in those real transcripts (QA13). Record pass/fail and any gap in the PR.
- [ ] 5.2 HUMAN: if the digest loses needed facts, choose between raising `GRID_AUTOHANDOFF_MAX_BYTES`, keeping short tool-result heads in the digest, or passing the raw transcript with `--add-dir`; open an issue for the chosen change.
- [ ] 5.3 HUMAN: on one machine, run `bash scripts/wire.sh`, confirm one generated SessionEnd entry in `~/.claude/settings.json` and that nothing else in that file changed (diff against a backup taken first). End a real 5+ turn session without `/handoff` and confirm a handoff file appears, only the two files were committed, a push happened only if they landed in the private repo with no other unpushed commit (log `push=` token matches), the log shows `action=done`, and the child output in the log shows no permission denial. Then add `-hook:auto-handoff` to that machine's overlay, re-run `wire.sh`, confirm the entry is gone, and remove the line again.
- Acceptance: written pass/fail note on the PR.
- Verify: `bash scripts/wire.sh --check`

**Success check:** Written pass/fail note on the PR; `bash scripts/wire.sh --check` exits 0.

### rule-packs, group 13: smoke-test in real harnesses and choose wired packs

**Due:** After rule-packs groups 2, 3 and 4, and at least groups 6 and 7, are merged to `next`.

**Source text (verbatim from `openspec/changes/rule-packs/tasks.md`):**

Depends on: 2, 3, 4, and at least groups 6 and 7 merged.

- [ ] 13.1 HUMAN: on one machine, add `rules:sql` and `rules:bash` to your untracked `baseline-submodules.txt` (or `machines/<host>.txt`), run `bash scripts/wire.sh`, open Claude Code in a repo with a `.sql` file and a `.sh` file, and confirm via `/memory` or a rules listing that `grid/sql/*` loads only after touching the `.sql` file.
- [ ] 13.2 HUMAN: in a scratch repo run `python3 <grid>/scripts/rules.py emit --harness cursor --packs sql,bash` and confirm Cursor lists the `.mdc` rules with the right globs (confirms list-form `globs`). Run `--harness gemini` and confirm the installed Gemini CLI loads root `GEMINI.md` (if it expects `.gemini/GEMINI.md`, file a one-line fix to the emitter path). Confirm Codex reads the `AGENTS.md` block.
- [ ] 13.3 HUMAN: choose which packs go in each machine's untracked baseline/overlay (suggested start: the packs for languages actually used on that machine). No tracked file changes are required.
- [ ] 13.4 HUMAN: close issue #5 as superseded (reference this change).
- [ ] 13.5 HUMAN: behavioural spot check, one pack. In a scratch repo, ask the same prompt twice in fresh sessions, once with `rules:sql` wired and once without, e.g. "write a query returning all columns for last month's orders from a date-partitioned BigQuery table". Note whether the wired run uses named columns and a partition filter and the unwired run does not. Record the result (or "no visible difference") in `docs/rules.md`, replacing the "Effect of packs on model behaviour: unmeasured" line.

Acceptance: items 13.1-13.2 pass or produce a concrete bug report against groups 2-4; 13.5 outcome is recorded either way.

**Success check:** 13.1 and 13.2 pass or produce a concrete bug report against groups 2 to 4; the 13.5 outcome is recorded in `docs/rules.md` either way.

### instincts, group 9: enable on one project, review, close issues

**Due:** 9.0: after instincts group 1 is merged and BEFORE instincts group 3 is built (before N3 starts instincts group 3). 9.1 to 9.5: after instincts groups 6, 7 and 8 are merged to `next`; 9.2 to 9.3 span three weekly runs.

**Source text (verbatim from `openspec/changes/instincts/tasks.md`):**

Files: none in the repo (operator work); optional `docs/instincts.md` threshold notes.

Depends on: 6, 7, 8 (except 9.0, which runs after group 1 and before group 3).

- [ ] 9.0 HUMAN (Operator confirmed 2026-10-09 (Q11: default accepted); run before group 3 is built): from an empty temp dir with `GRID_INSTINCTS_SKIP=1`, pipe the quiet-week example digest from the prompt body (the `2026-W13` block, `<<<DIGEST` to `DIGEST>>>`) into the exact invocation in the design (`claude -p --model haiku --system-prompt "<analyse-v1 body>" --tools "" --disable-slash-commands --setting-sources "" --strict-mcp-config --no-session-persistence --output-format json --max-budget-usd 0.05`). Record in `design.md` as a `Decided:` line: every flag accepted, the `result` parses as a JSON array, `total_cost_usd` (must be under $0.03, expected about $0.01), and that no hook or user-level CLAUDE.md fired (no new hook log lines; input token count consistent with prompt + digest only). If any check fails, stop and report; do not build group 3.
- [ ] 9.1 HUMAN: pick one project with a git remote, add `learning: on` to its `.grid/project.yaml`, run `agent-factory/.venv/bin/python agent-factory/deploy_hooks.py <project>`, confirm the four `instincts-*` entries in `.claude/settings.local.json`, and work normally for one week.
- [ ] 9.2 HUMAN: install the weekly schedule on that machine by running the activation commands `scripts/instincts.sh schedule` prints, run `instincts.sh analyse --all --dry-run` once and read the digest it prints (is it what a person would call this week's habits?), then a real run; confirm `status` shows non-zero observations, `ret`, `valid` and `kept` and one `role=instincts` line in the run log with `cost` under $0.03 (if higher, the user-level CLAUDE.md is probably loading: report it, do not raise the cap).
- [ ] 9.3 HUMAN: after three weekly runs read `instincts.sh show` and `status`; accept, retire or tune thresholds; `approve` or ignore any `pending global` candidates; confirm a session in that project prints the injection header and no more than 1500 characters.
- [ ] 9.4 HUMAN: run the live prompt eval once (`GRID_EVALS=1 scripts/instincts.sh eval-prompt --yes`), record the per-case result against the pass bar in the design, and run the two tank evolve cases (`GRID_EVALS=1 agent-factory/.venv/bin/python agent-factory/run_evals.py --role tank --yes`); then run tank `evolve` on one procedural entry from `LEARNINGS.md` and read the draft under `skill-drafts/`; this is the acceptance test for #19.
- [ ] 9.5 HUMAN: close #16 and #19 with a link to this change; close #20 as superseded with a one-line pointer to the design's #20 decision.

**Success check:** 9.0: all four recorded facts in `design.md` as a `Decided:` line. 9.2: `instincts.sh status` shows non-zero observations and one `role=instincts` run-log line under $0.03. 9.4: per-case result recorded; the tank evolve draft read. 9.5: #16 and #19 closed, #20 closed as superseded (derived: this section has no Acceptance line).

### multi-harness, group 9: smoke test on real harnesses

**Due:** After multi-harness groups 1, 3, 4, 6 and 7 are merged to `next`. Group 5 is optional. Needs the harnesses installed and signed in.

**Source text (verbatim from `openspec/changes/multi-harness/tasks.md`):**

Depends on: 1, 3, 4, 6, 7. Group 5 is optional. Needs the harnesses installed and signed in.

- [ ] 9.1 Codex: add `harness:codex` to this machine's overlay, compose `--target codex` for the wired projects, and run `wire.sh`. Confirm all of the following:
  - A session starts without a skills error.
  - A wired skill carrying `allowed-tools`, `triggers` and `version` frontmatter is listed.
  - The count of skills Codex lists matches the count of links in `~/.agents/skills` (records the 8,000-char cap's effect).
  - `grid-qa-engineer` spawns from a symlinked `~/.codex/agents/*.toml` and cannot write files.
- [ ] 9.2 OpenCode: confirm that the `permission` mapping loads and that a symlinked agent file is found. Record whether a skill present in both `~/.claude/skills` and `~/.agents/skills` is listed twice.
- [ ] 9.3 Pi and OpenClaw: confirm that shared-dir skills load (Pi `/skill:<name>`; OpenClaw symlink rule). Create an empty `~/.codex/AGENTS.md` with one `rules:` pack wired, and confirm that Codex reads the block.
- [ ] 9.4 Optional, Gemini CLI or Antigravity: confirm the `tools` YAML list and a symlinked agent file on Gemini CLI. On `agy`, confirm the real global skills path.
- [ ] 9.5 Record each result with its date in a "Verified on a real install" table in `docs/harnesses.md`. Open a follow-up issue for any failure (stripped-copy skills, copy-with-marker agents, path correction). Close #3 and #30 as superseded and #35 as skipped (D11), linking this change.
- Verify: none automated. The PR is the updated table.

**Success check:** The PR contains the updated "Verified on a real install" table in `docs/harnesses.md`; #3 and #30 closed as superseded, #35 as skipped.

### front-door, group 6: render hero, OG and icon assets

**Due:** After front-door group 5 is merged to `next`. Needs ImageMagick.

**Source text (verbatim from `openspec/changes/front-door/tasks.md`):**

Depends on: 5.

- [ ] 6.1 HUMAN: run `bash scripts/build-site-assets.sh the-grid.png` on a machine with ImageMagick; open `assets/hero.webp` and `assets/og.jpg`; judge the crop (wordmark readable at 1200x630, nothing important cut).
- [ ] 6.2 HUMAN: render the raster icons from the SVG: `magick -background none -density 384 assets/favicon.svg -resize 48x48 assets/favicon-48.png` and `magick -background '#0d0d0f' -density 1152 assets/favicon.svg -resize 180x180 -gravity center -extent 180x180 assets/apple-touch-icon.png` (use `convert` on ImageMagick 6); check both look right (needs the SVG delegate; any other tool is fine).
- [ ] 6.3 HUMAN: confirm sizes (`ls -l assets/`): hero.webp < 300 KB, og.jpg < 250 KB; append `assets/hero.webp`, `assets/og.jpg`, `assets/favicon-48.png` and `assets/apple-touch-icon.png` to `site-files.txt` (Q9); commit the four files and `site-files.txt` to `next`.
- [ ] 6.4 HUMAN: copy `the-grid.png` into the private repo (it is the only source for future re-renders; group 7 deletes it from this repo).
- Acceptance: four files committed and listed in `site-files.txt`; sizes within limits; source PNG saved in the private repo.
- Verify: `bash scripts/gate.sh`

**Success check:** Four files committed and listed in `site-files.txt`; sizes within limits; the source PNG is in the private repo; `bash scripts/gate.sh`.

### front-door, group 11: copy sign-off

**Due:** After front-door groups 4 and 7 are merged to `next`. Blocks group 13.

**Source text (verbatim from `openspec/changes/front-door/tasks.md`):**

Depends on: 4, 7. Blocks 13.

- [ ] 11.1 HUMAN: read README.md and index.html copy top to bottom in your own voice: hero sentence (does "every AI tool you use" sit right next to the Claude-Code-today line?), Who it's for, What you get, Status. Edit README.md; mirror edits into index.html; run `python3 scripts/stamp-counts.py` and `bash scripts/gate.sh` (the byte-identical hero/install test enforces parity).
- [ ] 11.2 HUMAN: time the quickstart on a clean machine (`time` the command with a fresh clone). If the README or site claims a duration, make it match; if > 2 min, state it ("first run fetches the upstream repos").
- [ ] 11.3 HUMAN: self-test #25 acceptance: someone (or a fresh OS user) wires a first skill from README alone and sees the "you should now see" outputs; note result on issue #25.
- [ ] 11.4 HUMAN: close #7 with a comment: the LAMP build prompt was retired (superseded by the role-by-role port in `agent-factory/roles/`; moved to the private archive by change `depersonalise`).
- Acceptance: gate green; #25 acceptance box checked; #7 closed.
- Verify: `bash scripts/gate.sh`

**Success check:** Gate green; the #25 acceptance box is checked; #7 is closed.

### front-door, group 12: render demo, visual sign-off, social preview

**Due:** After front-door groups 7, 9 and 11 are done.

**Source text (verbatim from `openspec/changes/front-door/tasks.md`):**

Depends on: 7, 9, 11.

- [ ] 12.1 HUMAN: on a clean OS user with Claude Code logged in and the home-directory trust prompt already accepted (run `claude` once by hand first, or the tape's `/tron` answers that prompt), run `vhs docs/demo/demo.tape` from the repo root; tune `Wait`/`Sleep` lines until the GIF is <= 20 s and <= 3 MB; add `docs/demo/bootstrap-to-tron.gif  # demo GIF, capped at 3 MB by tests/test_demo_tape.bats` to `scripts/personal-allow-paths.txt` (the size scan blocks files over 1 MB); commit tape tweaks, the allowlist line and the GIF.
- [ ] 12.2 HUMAN: add to README.md under Quickstart `![bootstrap to /tron](docs/demo/bootstrap-to-tron.gif)` with caption "Demo starts after the clone."; on index.html add only a text link to the GIF (absolute `https://github.com/<owner>/the-grid/blob/main/docs/demo/bootstrap-to-tron.gif` URL), no embedded image; run gate.
- [ ] 12.3 HUMAN: review the site visually at 1280x800 and 390x844: confirm h1, install command, Copy button and GitHub buttons are visible without scrolling at both sizes (moved here from group 7, QA13); then hero crop, contrast, Flynn band, install copy button, buttons, SVG diagram (the page is dark-only, so check dark only); fix CSS nits; note the above-the-fold result in the PR body.
- [ ] 12.4 HUMAN: upload `assets/og.jpg` at Settings -> Social preview (no API for this). The card check itself moves to 15.1 (the Pages URL must be live on `main` first).
- Acceptance: GIF committed and referenced from README.md (text link from index.html); social preview uploaded.
- Verify: `bash scripts/gate.sh`

**Success check:** GIF committed and referenced from README.md (text link only from index.html); social preview uploaded; `bash scripts/gate.sh`.

### front-door, group 13: generate translations

**Due:** After front-door groups 8 and 11 are done. Costs about 9 Sonnet calls; rerun only when README prose changes.

**Source text (verbatim from `openspec/changes/front-door/tasks.md`):**

Depends on: 8, 11. Costs tokens (about 9 Sonnet calls); run once per README prose change.

- [ ] 13.1 HUMAN: `bash scripts/translate-readme.sh --all`; skim each file (code blocks, links, banner, quote intact; header hash present).
- [ ] 13.2 HUMAN: `bash scripts/check-translations.sh --strict` exits 0; `bash scripts/gate.sh` green; commit `README.<locale>.md` and the updated README switcher.
- Acceptance: nine `README.<locale>.md` exist, switcher in README.md lists all nine, strict check passes.
- Verify: `bash scripts/check-translations.sh --strict && bash scripts/gate.sh`

**Success check:** `bash scripts/check-translations.sh --strict && bash scripts/gate.sh`; nine `README.<locale>.md` exist.

### front-door, group 14: apply GitHub About, homepage, topics

**Due:** After foundations group 7 (Pages returns 200, source switched to GitHub Actions) and front-door group 10. Changes live public state: read the diff first.

**Source text (verbatim from `openspec/changes/front-door/tasks.md`):**

Depends on: foundations#7 (Pages returns 200, Pages source switched to GitHub Actions), 10. Changes live public state: review the diff first.

- [ ] 14.1 HUMAN: `bash scripts/repo-metadata.sh --check` and read the diff; then `bash scripts/repo-metadata.sh --apply` as the account that owns the repo.
- [ ] 14.2 HUMAN: Settings -> Code security: enable "Private vulnerability reporting" (SECURITY.md depends on it); leave Discussions off.
- [ ] 14.3 HUMAN: `bash scripts/repo-metadata.sh --check` exits 0; `curl -sI https://<owner>.github.io/the-grid/ | head -1` shows 200.
- [ ] 14.4 HUMAN: before tagging, add a Google Search Console URL-prefix property for `https://<owner>.github.io/the-grid/` using HTML-file verification: download the `google<token>.html` file, commit it at the repo root of `main` and append it to `site-files.txt` (the Pages workflow serves only listed files, Q9; no meta tag, no DNS), wait for the Pages deploy, click Verify, then submit nothing else (no sitemap, see design.md).
- Acceptance: About, homepage and the declared topics visible on the repo page; Search Console property verified.
- Verify: `bash scripts/repo-metadata.sh --check`

**Success check:** `bash scripts/repo-metadata.sh --check` exits 0; the Search Console property is verified.

### front-door, group 15: tag v0.1.0

**Due:** After front-door groups 11, 12, 13 and 14, with `next` merged to `main`.

**Source text (verbatim from `openspec/changes/front-door/tasks.md`):**

Depends on: 11, 12, 13, 14 and `next` merged to `main`.

- [ ] 15.1 HUMAN: on `main`: `bash scripts/gate.sh`, `bash scripts/check-translations.sh --strict`, `bash scripts/repo-metadata.sh --check` all pass; CI green on `main`; then on the live site record in the PR/release notes: `curl -sI https://<owner>.github.io/the-grid/ | head -1` and `curl -sI https://<owner>.github.io/the-grid/assets/og.jpg | head -1` both show 200, and `curl -sI https://<owner>.github.io/the-grid/README.md | head -1` and `curl -sI https://<owner>.github.io/the-grid/repos/ | head -1` both show 404 (only `site-files.txt` entries are published, Q9); the Pages URL pasted into a chat client renders the og card (title, description, 1200x630 image); `https://validator.schema.org/` reports the JSON-LD with no errors; PageSpeed Insights (mobile, lab) shows LCP <= 2.5 s and CLS <= 0.1.
- [ ] 15.2 HUMAN: move `[Unreleased]` entries in CHANGELOG.md under `## [0.1.0] - <date>`; commit; `git tag -a v0.1.0 -m "v0.1.0"`; `git push origin v0.1.0`; `gh release create v0.1.0 --notes-from-tag`.
- Acceptance: release visible on GitHub; README Status wording matches ("Versioned from v0.1.0").
- Verify: `gh release view v0.1.0 --repo <owner>/the-grid`

**Success check:** `gh release view v0.1.0 --repo <owner>/the-grid` shows the release.

### plugin-marketplace, group 3: provenance and licence review of bundled content

**Due:** After plugin-marketplace group 1 is merged to `next`.

**Source text (verbatim from `openspec/changes/plugin-marketplace/tasks.md`):**

Depends on: 1. Files: `plugins/bundles.json` and regenerated `plugins/` only if membership changes.

- [ ] 3.1 HUMAN: confirm each of the 9 listed skills (`gh-issues-by-severity`, `grid-help`, `mine-learnings`, `openspec-help`, `rubber-duck`, `spec-scout`, `standup`, `tighten`, `un-claudish`) is original to the-grid, not derived from third-party text. Remove any that are not, then run `python3 scripts/build-plugins.py`.
- [ ] 3.2 HUMAN: confirm `grid-ponytail` and the composed role text in `core` and `grid` carry no third-party licensed passages that need an attribution file.
- Acceptance: a one-line comment on the group's issue stating the final skill list. Excluded forks (`handoff`, `grill-me`, `caveman`, `setup-repo-skills`, `skill-scout`) stay out for v0.1 (approved scope).

**Success check:** A one-line comment on the group's issue stating the final skill list.

### plugin-marketplace, group 4: publish after tag v0.1.0

**Due:** After plugin-marketplace groups 2 and 3 are merged and front-door group 15 has created tag v0.1.0. Needs a clean Claude Code profile; not for unattended agents.

**Source text (verbatim from `openspec/changes/plugin-marketplace/tasks.md`):**

Depends on: 2, 3, front-door#15. Needs a clean Claude Code profile and network; not for unattended agents.

- [ ] 4.1 HUMAN: confirm `git describe --tags --exact-match` on the release commit prints `v0.1.0`, `plugins/bundles.json` `version` is `0.1.0`, and the gate's `audit` check ran (not skipped).
- [ ] 4.2 HUMAN: merge `next` to `main` per the release process of `front-door`.
- [ ] 4.3 HUMAN: in a throwaway profile (`CLAUDE_CONFIG_DIR=$(mktemp -d)`), run `claude plugin marketplace add <owner>/the-grid`, `claude plugin install grid-core@the-grid`, `claude plugin install grid-agents@the-grid`; confirm `/grid-core:standup` and a `grid-agents:` agent are listed and no personal data appears in an installed agent file.
- [ ] 4.4 HUMAN: add the two-line install snippet to the README (copy owned by `front-door`) pointing to `docs/PLUGINS.md`.
- Verify: step 4.3 output pasted into the issue.

**Success check:** The step 4.3 output pasted into the issue.


## Open questions in Section 4

1. foundations group 7 says "Depends on: 2, 3, 9 merged to `main`". The loop only merges to `next`, and `next` reaches `main` at the front-door release. Decide whether `next` is promoted to `main` earlier for foundations (Pages) or group 7 waits for the release.
2. front-door group 14 depends on foundations group 7, so it inherits the same timing.

---

# 5. If something goes wrong

## Kill switch (stop the loop now)

```bash
# 1. stop the schedule and any run in progress (as the bot user)
systemctl --user disable --now issue-loop-<owner>-the-grid.timer
systemctl --user stop issue-loop-<owner>-the-grid.service

# 2. cut its access to GitHub: sign in as <machine-account> and delete the token
#    Settings > Developer settings > Personal access tokens > Delete.   Effective immediately.
#    Or remove <machine-account> from the repo: Settings > Collaborators.

# 3. take the queue away
gh issue list --repo <owner>/the-grid --label ready-for-agent --state open --json number --jq '.[].number' \
  | while read -r n; do gh issue edit "$n" --repo <owner>/the-grid --remove-label ready-for-agent; done

# 4. (optional) stop the user from running anything
sudo loginctl disable-linger <loop-user>
sudo usermod -L <loop-user>
```

Success: `systemctl --user list-timers` no longer lists the timer; `gh api user` with the old token returns 401.

## Revert or discard a PR

1. Open PR, not wanted: close it, delete the branch, put the issue back. `gh pr close <PR> --repo <owner>/the-grid --delete-branch`, then `gh issue edit <N> --repo <owner>/the-grid --remove-label ready-for-human --add-label backlog`.
2. Merged PR, bad: revert it on a branch and merge the revert through a PR (the ruleset allows nothing else). A merge commit: `git revert -m 1 <merge-sha>`. A squash or rebase merge: `git revert <sha>`. Then recompose and rewire the machines (Section 3).
3. Merged PR already acted on by a HUMAN step (a recompose, the Pages switch): undo that step after the revert, not before.

## Specific switches

| Problem | Switch |
|---|---|
| Auto-handoff misbehaves in one session | start that session with `GRID_DISABLED_HOOKS=auto-handoff claude` (same switch works for any hook id, comma-separated) |
| Auto-handoff misbehaves on one machine | add the line `-hook:auto-handoff` to that machine's `machines/$(hostname -s).txt`, then `bash scripts/wire.sh`. Re-enable by deleting the line (or `hook:auto-handoff`) and wiring again |
| `wire.sh` blocked by the audit (exit 3, nothing changed) | fix or allowlist the finding; as a one-off override `GRID_AUDIT=warn bash scripts/wire.sh` |
| A secret-scan hook blocks a legitimate command | `GRID_DISABLED_HOOKS=pre-bash-secret-scan` in the launching shell, for that session only |
| Runner exits 2 | the journal line names the fix; the common ones are in the table below |
| A unit shows `failed` | `systemctl --user reset-failed issue-loop-<owner>-the-grid.service`, fix the cause, wait for the next fire or `systemctl --user start` it |
| Cost higher than expected | read `cost_usd` in the run log (Section 3); lower `MAX_BUDGET_USD` or `MAX_ISSUES` with the Section 1 step 15 drop-in; check `usage/` reports if budget-and-usage has landed |
| You need to push to `next` yourself | set the ruleset to Disabled, push, set it back to Active. Never leave it off overnight |

Runner exit 2, common causes (each is a preflight check; fix and re-run `systemctl --user start`):

| Journal says | Fix |
|---|---|
| env file mode / `chmod 600` | `chmod 600 ~/.config/the-grid/issue-loop.env` |
| `LOOP_TRUSTED_ACTORS` empty, or `LOOP_OPERATOR_HOME` listable | fix the env file; `chmod 700` your home |
| claude not logged in | `sudo -iu <loop-user>`, run `~/.local/bin/claude`, log in again |
| stored `gh` login | `sudo -iu <loop-user> gh auth logout` |
| PAT belongs to a trusted actor | create the token from `<machine-account>`, not from `<operator-login>` |
| origin must be https | `git -C ~/the-grid remote set-url origin https://github.com/<owner>/the-grid.git` |
| no `pull_request` ruleset / token has Administration | Section 1 steps 9 and 11 |
| guard entry missing | `bash loop/setup.sh` in the clone |
| tree not clean | `git -C ~/the-grid status`; discard stray changes |
| git identity | `git config --global user.name` / `user.email` as the bot user |

Rotating the token: create a new one from `<machine-account>`, run the Section 1 step 9 check on it, replace the `GH_TOKEN=` line in the env file (keep mode 600), delete the old token on GitHub.
