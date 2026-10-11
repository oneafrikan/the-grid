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

## Running only what a change touched (`--changed`)

```bash
agent-factory/.venv/bin/python agent-factory/run_evals.py --changed origin/next...HEAD --dry-run   # look first
GRID_EVALS=1 agent-factory/.venv/bin/python agent-factory/run_evals.py --changed origin/next...HEAD --yes
```

- **Callers should run `--changed origin/next...HEAD --dry-run` first**: it prints the selection and the worst-case spend without a model call.
- **Selection.** `git diff --name-only RANGE` in `--repo` (default: this repo) maps each changed file to roles; a bad range is `E_RANGE`, exit 2.
  - `agent-factory/roles/<role>/**` and `evals/cases/<role>/**` select `<role>`.
  - Everything else goes through `evals/touchfiles.yaml`: first matching rule wins per file, `paths` are `fnmatch` patterns (`*` also crosses `/`), `roles` is `all`, `orchestrators` or a list.
  - Today that map is: `_core/DECISION_BRIEF.md` selects the orchestrators; `compose.py`, `deploy.py`, `stacks/*` and `examples/*` select every role. Other `_core/` files and `models.yaml` are not in the eval prompt, so they select nothing. Add a rule if one starts to.
  - Selected roles are intersected with the roles that have cases (and with `--role` / `--case`). Roles with no cases are listed on the `changed:` line, not an error. No match prints `no eval-relevant changes` and exits 0.
- **Cap.** `--max-total USD` (default 5.00): if the plan's worst case (the figure on the `plan:` line) is higher, `--changed` exits 2 before any spend, even with `--dry-run`. Narrow with `--role` or raise `--max-total`.
- `--validate` also checks `evals/touchfiles.yaml` (`E_CASE: touchfiles.yaml: ...`).
