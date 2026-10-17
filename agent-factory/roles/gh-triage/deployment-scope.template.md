<!--
  deployment-scope.template.md — the per-machine scope contract for gh-triage.

  The composed gh-triage agent is deployment-agnostic: it knows HOW to triage but
  not WHAT. Each machine that runs the agent provides ONE filled-in copy of this
  file (in that machine's own infra repo, NOT in the-grid — the-grid is shared
  across machines, so machine-specific scope must not live here).

  The machine's cron prompt passes the absolute path of its filled-in scope file
  to the agent via `-p`. The agent reads it in Step 0 (see roles/gh-triage/SKILL.md)
  and triages ONLY what it lists.

  This template is the single canonical copy of the contract — there is no second
  hardcoded deployment. Copy it, fill the values, commit it to the owning repo.

  Each install keeps its own deployments table in its own infra repo.
-->

# gh-triage deployment scope — <machine>

org: <github-owner>

## Repos in scope

Triage ONLY these repos. The agent injects the matching row into its severity
classification prompt, so the live-system column must be accurate.

| Repo | Live system | Severity ceiling | Notes |
|---|---|---|---|
| <repo> | <what it backs in production> | critical / high / medium / low | <e.g. "config source of truth"> |

## Slack ingestion

Set `enabled: false` to skip Slack entirely (the agent skips Step 1). Only fill
`channel` / `messages-file` / `last-run-file` / `file-issues-in` when `enabled: true`.
The agent has no Slack tool: `messages-file` is a .md file the deployment keeps filled
with the channel's messages, and `last-run-file` is a .md file holding the timestamp of
the last message processed (the agent rewrites it after each run).

enabled: false
# channel: <#name> (<CHANNEL_ID>)
# messages-file: <absolute path to a .md file of the channel's messages>
# last-run-file: <absolute path to a .md file holding the last-processed timestamp>
# file-issues-in: <rule — e.g. "the repo whose live system the message concerns; default <repo>">
