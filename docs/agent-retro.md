# Agent retro — review how a role behaved, then change the guidance that caused it

A short, repeatable loop for improving the roles from evidence instead of impressions
(notice, inspect, change, check). Run it weekly, or any time a role does something you
did not expect. It needs a run record (`scripts/run-record.sh`) or a transcript to start from.

## 1. Notice — say what happened, in plain words
One sentence, the way you would say it to a colleague: "gh-triage labelled the live repo
without a preview." Not "the model hallucinated".

## 2. Inspect — find the run
- Unattended roles: find the line in the run log (`${GRID_RUN_LOG:-~/.grid/runs.jsonl}`).
  `python3 -c "import json,sys; [print(l.rstrip()) for l in open(sys.argv[1]) if json.loads(l)['role']=='gh-triage']" ~/.grid/runs.jsonl`
- Interactive roles: the Claude Code transcript for that session.
- Note: which role acted, and who started the run (the record keeps both).

## 3. Trace — find the line that caused it
Open the role's files (`agent-factory/roles/<role>/AGENTS.md`, `SOUL.md`, `SKILL.md`) and find the
rule that allowed it, or the missing rule. Most failures are a rule that says too little,
or says the wrong thing, not a model fault. Quote the line.

## 4. Change — edit the shared guidance, in a PR
One change, one reason, in the role's own words. Review it like code. Do not fix it only in
your own session: the next person gets the same role.

## 5. Check — same case, plus fresh ones
- Add a case under `evals/cases/<role>/` that reproduces the problem (if none exists) and run it
  before the change (baseline) and after: `GRID_EVALS=1 agent-factory/.venv/bin/python agent-factory/run_evals.py --yes --role <role>`.
- Add one fresh case the change should not affect, to catch a side effect.
- Compare the pass rate, flip rate and cost before and after. Keep the change only if the evidence supports it.

## 6. Record
Add the outcome (what changed, before and after pass rate) to the PR description. If the
role keeps a MEMORY.md, note the lesson there.
