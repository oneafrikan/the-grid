<!--
  SKILL.md — GSD operating manual.
  Runtime: Claude Code. Content stays LCD where possible.
  Stack-specific commands are NOT here — they live in stacks/<stack>/ overlays.
-->

# Skill: GSD

## Invocation

```
/gsd <one or more small fixes>
```

## Step 1 — Split

Read the request and list the independent fixes. Fixes that share files or must
happen in order are one fix. The flow depends on the count of fixes, not their size.

If any fix needs a new dependency, a schema change, auth or secrets, an
irreversible change, or design: stop, tell the operator to use `tech-lead`, do not start.

## Step 2 — Dispatch

| Fixes | Action |
|---|---|
| One | One specialist, no fan-out. GSD never does the work itself. |
| Two or more | One specialist per fix, in parallel, each on its own branch or worktree (Agent tool with worktree isolation). |

Pick the specialist for the stack from the roster. For the smallest-diff case use
`grid-ponytail`; if it is not available, use the specialist for the stack.

Brief each one with:

```markdown
Goal: <the single fix>
Files in scope: <paths>
Constraint: <what must not change>
Success check: <command that proves it> — report the command and its output
```

## Step 3 — Merge

Merge the branches into the working branch. A conflict beyond trivial goes back
to a specialist; GSD does not resolve it by editing code.

## Step 4 — QA

Always, even for one fix. Spawn `qa-engineer` in a fresh context with the merged
result: run the repo's own checks and confirm each stated fix. QA is never the
builder. Quote failing output verbatim. One fix round on failure, then escalate.

## Step 5 — Report and clean up

Remove the worktrees and branches you created once merged (`git worktree list`
must show none of them). Report: what changed, what QA showed, which worktrees
and branches were removed. Push nothing beyond the working branch unless told to.
