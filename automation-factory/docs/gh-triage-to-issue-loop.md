# gh-triage to issue-loop

How an issue becomes a pull request with no human in the middle until review. Two roles and one label; neither keeps state the other reads.

| Role | Does | Never does |
|---|---|---|
| `gh-triage` (a cron agent, `agent-factory/roles/gh-triage/SKILL.md`) | classifies each issue, applies labels, writes the Agent Brief | implements anything |
| `issue-loop` (`automation-factory/patterns/issue-loop/`) | picks a labelled issue, works it in a worktree, verifies it, opens a PR | classifies issues, merges |

## The join is a label

- gh-triage ends an actionable issue with `ready-for-agent`, or `ready-for-human` when it must not be automated.
- The loop starts by listing open issues that carry `ready-for-agent`, lowest number first. Nothing else connects the two.
- The loop removes `ready-for-agent` whenever it finishes with an issue, whatever the outcome, so a refused issue cannot starve the queue.

## The handoff is the Agent Brief

gh-triage posts one comment headed `## Agent Brief`: category, severity, summary, current and desired behaviour, key interfaces, acceptance criteria, out of scope.

- The loop reads the latest Agent Brief written by the repo owner, a member or a collaborator, plus the issue body. Other comments are not given to the worker.
- The loop does not classify. It does not re-derive severity or scope; it implements against the acceptance criteria and stops with `needs-human` when the brief is ambiguous.
- Keep the roles separate: if the brief is wrong, fix gh-triage, not the loop.

## Safety gates

- gh-triage owns the severity gate: `severity:critical` and `severity:high` always become `ready-for-human`.
- The loop reads labels once more as defence in depth. An issue that carries `ready-for-agent` together with `severity:critical` or `severity:high` is relabelled `ready-for-human` without a worktree or a model call.
- The loop only opens pull requests. A human merges. The merge boundary is branch protection on the base branch, not the loop.

## Label schema

| Dimension | Values | Set by |
|---|---|---|
| Category | `bug`, `enhancement` | gh-triage |
| Severity | `severity:critical`, `severity:high`, `severity:medium`, `severity:low` | gh-triage |
| State | `needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix` | gh-triage |
| Loop outcome | `ready-for-human` (PR opened), `needs-human` (a decision is needed), `blocked` (could not land it) | issue-loop |
| Role | `agent:<name>`, for example `agent:grid-backend-dev` | the operator |

## The round trip

```
issue filed (needs-triage)
  -> gh-triage: labels + Agent Brief          (ready-for-agent)
  -> issue-loop: worktree, worker, verify     (the runner runs VERIFY_CMD itself)
  -> pull request opened, issue relabelled    (ready-for-human, issue stays open)
  -> human reviews and merges
```

## Where to go next

- How the loop runs, its config and its known gaps: [`patterns/issue-loop/README.md`](../patterns/issue-loop/README.md).
- Cut it into a repo: `bash scripts/instantiate.sh issue-loop <repo> --profile work --verify-cmd "<your gate>"`, then start the first run by hand with `bash loop/run-issue.sh`.
- Issues can live in a different repo from the code: set `ISSUE_REPO` in `loop/loop.conf`.
