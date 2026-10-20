# Superseded by `issue-loop-v2`

This change is replaced by [`openspec/changes/issue-loop-v2/`](../issue-loop-v2/). Do not implement from it, and **do not archive it**: its four `issue-loop-*` capability specs would conflict with the `loop-*` specs of `issue-loop-v2`.

| `loops` capability | Fate |
|---|---|
| `issue-loop-runner`, `issue-loop-pr-mode`, `issue-loop-hooks`, `issue-loop-scheduling` | replaced by `loop-runner`, `loop-hooks`, `loop-config-and-seed`, `loop-waker`, `loop-migration` |
| `karpathy-loop`, `cli-agent-cron` (the unbuilt Phase B, tasks 6 to 8) | **deferred**, not deleted. They were to be built by the loop; the loop is rebuilt first. Recorded in `TODO.md` |

The unchecked proof tasks (5.1a to 5.8) are replaced in effect by the proof tasks of `issue-loop-v2` (groups 8, 10 and 12). Nothing in this folder was deleted.
