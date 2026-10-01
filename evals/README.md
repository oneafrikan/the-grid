# evals — golden cases for grid roles

A case pins one scenario to one role and checks the reply with plain regexes, so a change
to a role prompt, the schema or a model shows up as a before/after pass rate. The
tests in `tests/` check the tooling; these check how a role behaves.

```bash
agent-factory/.venv/bin/python agent-factory/run_evals.py --validate   # case files only; runs in the gate (tests/test_eval_cases.bats)
agent-factory/.venv/bin/python agent-factory/run_evals.py --list       # cases and their baseline
agent-factory/.venv/bin/python agent-factory/run_evals.py --dry-run    # plan + worst-case spend, no model call
GRID_EVALS=1 agent-factory/.venv/bin/python agent-factory/run_evals.py --yes   # real runs: costs money
```

- **Opt-in and capped.** Real runs need `GRID_EVALS=1` and `--yes`; each run is capped
  (`--budget`, default $0.25) and the plan prints the worst-case total first. Never run from the gate.
- **Tools are off.** A case can only talk; it cannot act on anything.
- **What ships is what is tested.** The role is rendered by `deploy.py --profile lean`, on the role's own model.
- **Isolated.** No user settings, hooks or MCP servers, and an empty working directory. (`--bare` is not used: it refuses the OAuth login.)
- **Results** go to `evals/results/*.jsonl` (git-ignored): one line per run with the full reply, cost and any error. An error (for example "Not logged in") is never counted as a failed case.
- **A run is not a verdict.** Replies are sampled (3 runs by default); a case that passes sometimes is reported as FLIPPING.

## Writing a case

`evals/cases/<role>/<name>.yaml`; the fields are documented at the top of `agent-factory/run_evals.py`.
Keep the scenario free of hints: a case that names the right answer, or spells out what is
missing, measures reading comprehension, not the role's rules.
