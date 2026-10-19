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
agent-factory/.venv/bin/python agent-factory/run_evals.py --changed origin/main...HEAD --dry-run   # look first
GRID_EVALS=1 agent-factory/.venv/bin/python agent-factory/run_evals.py --changed origin/main...HEAD --yes
```

- **Callers should run `--changed origin/main...HEAD --dry-run` first**: it prints the selection and the worst-case spend without a model call.
- **Selection.** `git diff --name-only RANGE` in `--repo` (default: this repo) maps each changed file to roles; a bad range is `E_RANGE`, exit 2.
  - `agent-factory/roles/<role>/**` and `evals/cases/<role>/**` select `<role>`.
  - Everything else goes through `evals/touchfiles.yaml`: first matching rule wins per file, `paths` are `fnmatch` patterns (`*` also crosses `/`), `roles` is `all`, `orchestrators` or a list.
  - A rule may carry `eval: <name>` instead of `roles` (today only `instincts`): its files select no role, and `--changed` prints that eval's own command (`instincts eval selected: run GRID_EVALS=1 scripts/instincts.sh eval-prompt --yes`) instead of running anything. That eval has its own runner and spend cap.
  - Today that map is: `_core/DECISION_BRIEF.md` selects the orchestrators; `compose.py`, `deploy.py`, `stacks/*` and `examples/*` select every role. Other `_core/` files and `models.yaml` are not in the eval prompt, so they select nothing. Add a rule if one starts to.
  - Selected roles are intersected with the roles that have cases (and with `--role` / `--case`). Roles with no cases are listed on the `changed:` line, not an error. No match prints `no eval-relevant changes` and exits 0.
- **Cap.** `--max-total USD` (default 5.00) applies to every plan, not only `--changed`: if the plan's worst case (the figure on the `plan:` line) is higher, the run exits 2 before any spend, even with `--dry-run`. An unfiltered run over every case is over the default cap, so narrow with `--role` or `--case`, or raise `--max-total`.
- `--validate` also checks `evals/touchfiles.yaml` (`E_CASE: touchfiles.yaml: ...`).

## Instincts prompt cases (`evals/instincts/`)

The analyser prompt of the `instincts` feature has its own seventeen labelled cases, `evals/instincts/c01-*.json` to `c17-*.json`, outside `evals/cases/` because `run_evals.py` is role-shaped and does not fit them. `scripts/instincts.sh eval-prompt --validate` is free and runs in the gate (canned good and bad replies through the shipping validator, plus a check of the prompt file). `GRID_EVALS=1 scripts/instincts.sh eval-prompt --yes [--runs N] [--budget USD] [--max-total USD] [--case NAME]` is the paid, opt-in live run (defaults 3 runs, $0.05 per call; at most 10 runs, $1.00 per call and $5.00 worst case per invocation; it prints the worst-case spend first and appends one line per run to `${GRID_STATE_DIR:-$HOME/.grid}/instincts/eval-results.jsonl`). Case format and pass bar: `openspec/changes/instincts/design.md` (Labelled prompt cases).
