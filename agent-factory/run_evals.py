#!/usr/bin/env python3
"""run_evals.py — golden cases for grid roles: does a role behave the way its rules say?

Why this exists: the grid's tests (tests/*.bats) check the tooling, never a role's
behaviour. Every change to a role prompt, the schema or a model is otherwise blind.
A case pins one scenario to one role and checks the reply with plain regexes, so a
change shows up as a before/after pass rate. Not an LLM judge; not a CI gate.

Usage:
    run_evals.py --validate                  # check every case file; no model call (this runs in the gate)
    run_evals.py --list                      # list cases and their baseline expectation
    run_evals.py --dry-run                   # show the plan and the worst-case spend; no model call
    GRID_EVALS=1 run_evals.py --yes          # run for real (costs money)
    options: --role R  --case NAME  --runs N  --budget USD  --cases-dir D  --results-dir D

A case (evals/cases/<role>/<name>.yaml):
    role:          the grid role under test (must exist)
    finding:       the eval finding it came from, e.g. "#2"
    expect_today:  pass | fail | unknown   (the baseline: what we expect BEFORE the fix)
    prompt:        the scenario, sent as the user message
    must_match:    [regex, ...]   every one must match the reply (multiline, case-insensitive)
    must_not_match:[regex, ...]   none may match                        (optional)
    runs:          N              repeats per case, default 3           (optional)

How a run works: the role is rendered by the REAL pipeline (deploy.py --profile lean into
a temp dir), so the system prompt is exactly what ships. The model is the role's own
model. Tools are switched OFF, so a case can only talk and can never act on anything.
Results go to evals/results/*.jsonl (git-ignored) with pass rate and flip rate.
"""
import argparse
import json
import os
import re
import subprocess
import sys
import tempfile
import time
from pathlib import Path

import yaml

HERE = Path(__file__).resolve().parent            # agent-factory/
sys.path.insert(0, str(HERE))
import compose  # noqa: E402  (role lookup + model resolution, same code the deploy uses)

REPO = HERE.parent
CASES_DIR = REPO / "evals" / "cases"
RESULTS_DIR = REPO / "evals" / "results"
EXPECT = {"pass", "fail", "unknown"}
REQUIRED = ("role", "finding", "expect_today", "prompt", "must_match")
DEFAULT_RUNS = 3
DEFAULT_BUDGET = 0.25    # USD cap per single run; the plan prints runs x this as the worst case


def load_cases(cases_dir: Path) -> list[dict]:
    """Every *.yaml under cases_dir/<role>/, with its file path attached."""
    cases = []
    for path in sorted(cases_dir.glob("*/*.yaml")):
        try:
            case = yaml.safe_load(path.read_text(encoding="utf-8"))
        except yaml.YAMLError as exc:
            case = {"_yaml_error": str(exc)}
        case = case if isinstance(case, dict) else {"_yaml_error": "not a mapping"}
        case["_path"] = path
        case["name"] = path.stem
        cases.append(case)
    return cases


def validate(case: dict) -> list[str]:
    """Problems with one case file; empty list means it is well formed."""
    where = f"{case['_path'].parent.name}/{case['_path'].name}"
    if "_yaml_error" in case:
        return [f"{where}: {case['_yaml_error']}"]
    errs = [f"{where}: missing '{k}'" for k in REQUIRED if k not in case]
    if errs:
        return errs
    if case["_path"].parent.name != case["role"]:
        errs.append(f"{where}: role {case['role']!r} does not match its directory")
    if not compose.role_dir(case["role"]).is_dir():
        errs.append(f"{where}: unknown role {case['role']!r}")
    if not re.fullmatch(r"#\d+", str(case["finding"])):
        errs.append(f"{where}: finding {case['finding']!r} must look like '#2'")
    if case["expect_today"] not in EXPECT:
        errs.append(f"{where}: expect_today must be one of {sorted(EXPECT)}")
    if not isinstance(case["prompt"], str) or not case["prompt"].strip():
        errs.append(f"{where}: prompt must be non-empty text")
    for key in ("must_match", "must_not_match"):
        pats = case.get(key, [])
        if not isinstance(pats, list) or (key == "must_match" and not pats):
            errs.append(f"{where}: {key} must be a list" + (" with at least one regex" if key == "must_match" else ""))
            continue
        for pat in pats:
            try:
                re.compile(pat)
            except (re.error, TypeError) as exc:
                errs.append(f"{where}: bad regex in {key}: {pat!r} ({exc})")
    if "runs" in case and not (isinstance(case["runs"], int) and case["runs"] >= 1):
        errs.append(f"{where}: runs must be an integer >= 1")
    return errs


def system_prompt(role: str, cache: dict) -> tuple[str, str]:
    """(system prompt, model) for a role, rendered by the real lean deploy. Cached per role."""
    if role in cache:
        return cache[role]
    with tempfile.TemporaryDirectory() as tmp:
        subprocess.run([sys.executable, str(HERE / "deploy.py"), tmp, "--roles", role, "--profile", "lean"],
                       check=True, capture_output=True, text=True)
        # specialists deploy as subagents, orchestrators as skills; exactly one of these exists
        files = list(Path(tmp, ".claude").glob(f"agents/grid-{role}.md")) + \
            list(Path(tmp, ".claude").glob(f"skills/grid-{role}/SKILL.md"))
        if len(files) != 1:
            raise RuntimeError(f"expected one deployed file for {role}, found {len(files)}")
        text = files[0].read_text(encoding="utf-8")
    body = re.sub(r"\A---\n.*?\n---\n", "", text, count=1, flags=re.S)   # drop the frontmatter
    model = compose.resolve_model({"role": role})
    cache[role] = (body, model)
    return cache[role]


def ask(claude: str, body: str, model: str, prompt: str, budget: float) -> dict:
    """One headless, tool-less run. The prompt goes in on stdin (the --tools flag is variadic
    and would swallow a positional prompt). Isolation: no settings/hooks (--setting-sources ""),
    no MCP servers (--strict-mcp-config), and an empty working directory so no project
    CLAUDE.md is found. (--bare would isolate harder but refuses the OAuth login.)
    Returns the parsed JSON result, or {'error': ...} for any failure, including an
    is_error reply such as "Not logged in" -- an error is never counted as a failed case."""
    cmd = [claude, "-p", "--output-format", "json", "--system-prompt", body,
           "--model", model, "--tools", "", "--disable-slash-commands",
           "--setting-sources", "", "--strict-mcp-config",
           "--no-session-persistence", "--max-budget-usd", str(budget)]
    with tempfile.TemporaryDirectory() as cwd:
        proc = subprocess.run(cmd, input=prompt, capture_output=True, text=True, timeout=300, cwd=cwd)
    try:
        res = json.loads(proc.stdout)
    except json.JSONDecodeError:
        return {"error": f"exit {proc.returncode}: {(proc.stderr or proc.stdout)[:300]}"}
    if res.get("is_error") or "result" not in res:
        res["error"] = str(res.get("result") or res.get("terminal_reason") or "unknown error")[:300]
    return res


def check(case: dict, reply: str) -> bool:
    """Every must_match matches and no must_not_match does (multiline, case-insensitive)."""
    flags = re.M | re.I
    return all(re.search(p, reply, flags) for p in case["must_match"]) and \
        not any(re.search(p, reply, flags) for p in case.get("must_not_match", []))


def main() -> int:
    ap = argparse.ArgumentParser(description="Golden cases for grid roles.")
    ap.add_argument("--validate", action="store_true", help="check case files only; no model call")
    ap.add_argument("--list", action="store_true", help="list cases and baselines")
    ap.add_argument("--dry-run", action="store_true", help="show the plan and worst-case spend; no model call")
    ap.add_argument("--yes", action="store_true", help="confirm that real runs may spend money")
    ap.add_argument("--role"), ap.add_argument("--case")
    ap.add_argument("--runs", type=int, help="override runs per case")
    ap.add_argument("--budget", type=float, default=DEFAULT_BUDGET, help="USD cap per run")
    ap.add_argument("--cases-dir", type=Path, default=CASES_DIR)
    ap.add_argument("--results-dir", type=Path, default=RESULTS_DIR)
    args = ap.parse_args()

    cases = load_cases(args.cases_dir)
    problems = [e for c in cases for e in validate(c)]
    if args.validate or problems:
        for p in problems:
            print(f"E_CASE: {p}", file=sys.stderr)
        print(f"{len(cases)} case(s), {len(problems)} problem(s)")
        return 1 if problems else 0

    cases = [c for c in cases if (not args.role or c["role"] == args.role) and (not args.case or c["name"] == args.case)]
    if args.list:
        for c in cases:
            print(f"{c['role']:<18} {c['name']:<28} finding {c['finding']:<4} baseline: {c['expect_today']}")
        return 0

    plan = [(c, args.runs or c.get("runs", DEFAULT_RUNS)) for c in cases]
    total = sum(n for _, n in plan)
    print(f"plan: {len(plan)} case(s), {total} run(s); worst case ${total * args.budget:.2f} (cap ${args.budget:.2f}/run)")
    if args.dry_run:
        return 0
    if os.environ.get("GRID_EVALS") != "1":
        print("refusing: real runs cost money. Set GRID_EVALS=1 to allow them.", file=sys.stderr)
        return 2
    if not args.yes:
        print("refusing: pass --yes to confirm the spend shown above.", file=sys.stderr)
        return 2

    claude = os.environ.get("GRID_CLAUDE", "claude")     # tests point this at a stub
    args.results_dir.mkdir(parents=True, exist_ok=True)
    out = args.results_dir / (time.strftime("%Y%m%dT%H%M%SZ", time.gmtime()) + ".jsonl")
    cache: dict = {}
    spent = 0.0
    with out.open("w", encoding="utf-8") as fh:
        for case, n in plan:
            body, model = system_prompt(case["role"], cache)
            wins = errs = 0
            for i in range(1, n + 1):
                res = ask(claude, body, model, case["prompt"], args.budget)
                reply = str(res.get("result", ""))
                ok = "error" not in res and check(case, reply)
                wins += ok
                errs += "error" in res
                cost = float(res.get("total_cost_usd") or 0)
                spent += cost
                fh.write(json.dumps({"ts": time.time(), "role": case["role"], "case": case["name"], "run": i,
                                     "model": model, "passed": ok, "cost_usd": cost,
                                     "error": res.get("error"), "reply": reply}) + "\n")
            flip = " FLIPPING" if 0 < wins < n else ""
            err = f"  ({errs} ERROR run(s), not counted as case failures: see results)" if errs else ""
            print(f"{case['role']}/{case['name']}: {wins}/{n} pass{flip}{err}  (baseline expected: {case['expect_today']})")
    print(f"spent ${spent:.2f}; results: {out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
