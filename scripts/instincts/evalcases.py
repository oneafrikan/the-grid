#!/usr/bin/env python3
"""instincts labelled prompt cases (openspec change `instincts`, group 8).

    python3 -I evalcases.py --validate [--cases-dir DIR]
    GRID_EVALS=1 python3 -I evalcases.py --yes [--runs N] [--budget USD] [--case NAME]

Run through scripts/instincts.sh (`instincts.sh eval-prompt ...`).

Cases live in evals/instincts/<name>.json (outside evals/cases/, which run_evals.py
globs for role cases). Case file:

  {"name": "<file stem>", "why": "<what it pins>",
   "obs":   [[sid, ev, tool, in, err], ...],     ev = prompt|tool; tool "" for a prompt
   "known": [{"id","trigger","action"[,"domain"]}],   instincts already on file (K lines)
   "expect": {"items": "none"|"some",            optional: absent = any count
              "must_include": [{"kind", "id"?, "domain"? (str or list), "evidence_has"? (ref prefix, "P")}],
              "must_not_match": [regex over id + trigger + action of each validated OR returned item],
              "max_items": n},
   "canned": {"good": [...], "bad": [...], "bad_reason": "<validator drop reason>"}}

`obs` is expanded into observation lines (synthetic timestamps, one week) and padded
with the same fixed run of neutral Bash events (ls, git status, cd) to at least 60
observations, so the analyser's minimum-observation gate is met.

Two halves:
  --validate  FREE, no model call, runs in the gate. Every case file is shape-checked, its
              digest built with analyse.py's own builder, `canned.good` must survive the
              analyser's output validator unchanged and satisfy `expect`, `canned.bad` must
              be dropped with `bad_reason`; analyse-v1.md is checked for its header keys,
              no `{{` placeholders and the three example blocks.
  live        PAID, opt-in. Needs GRID_EVALS=1 and --yes. Calls the shipping command through
              analyse.call_model (same flags, same prompt file, GRID_CLAUDE honoured), validates
              the reply, checks `expect`, prints a per-case pass rate (FLIPPING when only some
              runs pass) and appends one line per run to <state>/instincts/eval-results.jsonl.
              A call that errors (e.g. "Not logged in") is reported as an error and is never
              counted as a failed case.

Stdlib only. Exit codes: 0 ok, 1 a case failed / errored / a problem was found, 2 usage or refusal.
"""
from __future__ import annotations

import sys

# `python3 -I` drops the script directory from sys.path, so add it by hand to
# import lib/analyse. Never write bytecode: a __pycache__ here would land in the repo.
sys.dont_write_bytecode = True
from pathlib import Path  # noqa: E402

sys.path.insert(0, str(Path(__file__).resolve().parent))

import argparse  # noqa: E402
import contextlib  # noqa: E402
import datetime as dt  # noqa: E402
import json  # noqa: E402
import math  # noqa: E402
import os  # noqa: E402
import re  # noqa: E402
import tempfile  # noqa: E402

import analyse  # noqa: E402
import lib  # noqa: E402

CASES_DIR = lib.REPO_ROOT / "evals" / "instincts"
MIN_OBS = 60
# The padding: one fixed sequence, the same for every case. Event i runs in session
# i % 3 and is command (i // 3) % 3, so every neutral command spans all three sessions
# (like a real week's `ls` and `git status`) and none of them is tied to one session.
PAD_SIDS = ("s1", "s2", "s3")
PAD_CMDS = ("ls", "git status", "cd src")
# Synthetic week for every case: Monday 2026-W41 08:00 UTC, one second per event.
WEEK_START = dt.datetime(2026, 10, 5, 8, 0, 0, tzinfo=dt.timezone.utc)
NOW = dt.datetime(2026, 10, 8, 12, 0, 0, tzinfo=dt.timezone.utc)
PID = "ecca5e000001"            # synthetic project id (12 hex) for the temp state dir
PROMPT_KEYS = ("prompt", "version", "supersedes", "inputs", "output_schema",
               "invariants", "model_cannot_see", "change")
EXPECT_KEYS = frozenset(["items", "must_include", "must_not_match", "max_items"])
INCLUDE_KEYS = frozenset(["kind", "id", "domain", "evidence_has"])
DEFAULT_RUNS = 3
DEFAULT_BUDGET = 0.05
# Hard bounds on what one invocation can spend: a typo (`--budget 100`, `--runs 50`) or `nan`
# must not turn the paid eval into an open cheque.
MAX_BUDGET = 1.00         # USD per call
MAX_RUNS = 10             # runs per case
DEFAULT_MAX_TOTAL = 5.00  # USD, worst case of the whole plan
RESULTS_NAME = "eval-results.jsonl"


# --------------------------------------------------------------------------
# Loading and shape
# --------------------------------------------------------------------------

def _is_regex(s) -> bool:
    try:
        re.compile(s)
        return isinstance(s, str)
    except (re.error, TypeError):
        return False


def shape_problems(c) -> list[str]:
    """Everything wrong with one parsed case file (empty list = well formed)."""
    if not isinstance(c, dict):
        return ["top level is not an object"]
    p: list[str] = []
    for k in ("name", "why", "obs", "known", "expect", "canned"):
        if k not in c:
            p.append(f"missing '{k}'")
    if p:
        return p
    for k in ("name", "why"):
        if not (isinstance(c[k], str) and c[k].strip()):
            p.append(f"'{k}' must be a non-empty string")
    if not isinstance(c["obs"], list) or not c["obs"]:
        p.append("'obs' must be a non-empty list")
    else:
        for i, row in enumerate(c["obs"]):
            ok = (isinstance(row, list) and len(row) == 5 and isinstance(row[0], str) and row[0]
                  and row[1] in ("prompt", "tool") and isinstance(row[2], str)
                  and isinstance(row[3], str) and isinstance(row[4], bool))
            if not ok:
                p.append(f"obs[{i}] must be [sid, 'prompt'|'tool', tool, in, err(bool)]")
            elif (row[1] == "tool") != bool(row[2]):
                p.append(f"obs[{i}]: tool name is required for ev=tool and empty for ev=prompt")
    if not isinstance(c["known"], list):
        p.append("'known' must be a list")
    else:
        for i, k in enumerate(c["known"]):
            if not (isinstance(k, dict) and isinstance(k.get("id"), str)
                    and isinstance(k.get("trigger"), str) and isinstance(k.get("action"), str)):
                p.append(f"known[{i}] needs string id, trigger, action")
    e = c["expect"]
    if not isinstance(e, dict) or set(e) - EXPECT_KEYS:
        p.append(f"'expect' must be an object with keys from {sorted(EXPECT_KEYS)}")
    else:
        if e.get("items") not in (None, "none", "some"):
            p.append("expect.items must be 'none' or 'some' (or absent)")
        if "max_items" in e and not (isinstance(e["max_items"], int) and not isinstance(e["max_items"], bool)
                                     and e["max_items"] >= 0):
            p.append("expect.max_items must be an integer >= 0")
        for i, rx in enumerate(e.get("must_not_match", [])):
            if not _is_regex(rx):
                p.append(f"expect.must_not_match[{i}] is not a valid regex")
        for i, m in enumerate(e.get("must_include", [])):
            if not (isinstance(m, dict) and m.get("kind") in lib.KINDS and not set(m) - INCLUDE_KEYS):
                p.append(f"expect.must_include[{i}] needs a kind and only keys from {sorted(INCLUDE_KEYS)}")
    cn = c["canned"]
    if not (isinstance(cn, dict) and isinstance(cn.get("good"), list) and isinstance(cn.get("bad"), list)
            and isinstance(cn.get("bad_reason"), str) and cn["bad"]):
        p.append("'canned' needs good (list), a non-empty bad (list) and bad_reason (string)")
    return p


def load_cases(directory: Path) -> tuple[list[dict], list[str]]:
    """(cases sorted by name, problems). A file that does not parse or has a bad shape is a problem."""
    cases: list[dict] = []
    problems: list[str] = []
    for f in sorted(directory.glob("*.json")):
        try:
            c = json.loads(f.read_text(encoding="utf-8"))
        except (OSError, ValueError) as ex:
            problems.append(f"{f.name}: unreadable ({ex})")
            continue
        sp = shape_problems(c)
        if not sp and c["name"] != f.stem:
            sp = [f"name '{c['name']}' must equal the file name '{f.stem}'"]
        problems += [f"{f.name}: {x}" for x in sp]
        if not sp:
            cases.append(c)
    if not cases and not problems:
        problems.append(f"no case files in {directory}")
    return cases, problems


# --------------------------------------------------------------------------
# Case -> digest, through analyse.py's own loader and builder
# --------------------------------------------------------------------------

def expand_obs(case: dict) -> list[dict]:
    """The case's observation lines (as capture would have written them), padded to MIN_OBS."""
    rows = [list(r) for r in case["obs"]]
    i = 0
    while len(rows) < MIN_OBS:
        rows.append([PAD_SIDS[i % 3], "tool", "Bash", PAD_CMDS[(i // 3) % 3], False])
        i += 1
    out = []
    for n, (sid, ev, tool, text, err) in enumerate(rows):
        o = {"ts": (WEEK_START + dt.timedelta(seconds=n)).strftime("%Y-%m-%dT%H:%M:%SZ"), "sid": sid, "ev": ev}
        if ev == "tool":
            o.update(tool=tool, err=err)
        o["in"] = text
        out.append(o)
    return out


@contextlib.contextmanager
def _temp_state():
    """Point GRID_STATE_DIR at a fresh temp dir for the duration, then put it back."""
    old = os.environ.get("GRID_STATE_DIR")
    with tempfile.TemporaryDirectory(prefix="instincts-evalcase-") as d:
        os.environ["GRID_STATE_DIR"] = d
        try:
            yield Path(d)
        finally:
            if old is None:
                os.environ.pop("GRID_STATE_DIR", None)
            else:
                os.environ["GRID_STATE_DIR"] = old


def known_view(case: dict) -> dict[str, dict]:
    """The K side as analyse.merged_view would return it (active instincts by id)."""
    return {k["id"]: {"id": k["id"], "trigger": k["trigger"], "action": k["action"],
                      "domain": k.get("domain", "testing"), "confidence": 0.5}
            for k in case["known"]}


def build_case_digest(case: dict):
    """(Digest, known) for a case: observations written to a temp state dir, read back by
    analyse.load_observations (the shipping reader), digested by analyse.build_digest."""
    with _temp_state() as state:
        d = state / "instincts" / PID
        d.mkdir(parents=True)
        (d / "obs-2026-W41.jsonl").write_text(
            "".join(json.dumps(o) + "\n" for o in expand_obs(case)), encoding="utf-8")
        events = analyse.load_observations(PID, None)
    known = known_view(case)
    return analyse.build_digest(events, known, NOW), known


# --------------------------------------------------------------------------
# expect
# --------------------------------------------------------------------------

def check_expect(valid: list[dict], raw: list, expect: dict) -> list[str]:
    """Why the validated items fail `expect` (empty list = pass).

    `raw` is the model's own array: validated items carry no evidence, so
    `evidence_has` looks the cited refs up by id there. `items`, `max_items` and
    `must_include` judge the validated items (what the store would receive);
    `must_not_match` judges validated and returned items alike.
    """
    fails: list[str] = []
    n = len(valid)
    if expect.get("items") == "none" and n:
        fails.append(f"expected no items, got {n}")
    if expect.get("items") == "some" and not n:
        fails.append("expected at least one item, got none")
    if "max_items" in expect and n > expect["max_items"]:
        fails.append(f"expected at most {expect['max_items']} item(s), got {n}")
    cited = {r["id"]: r.get("evidence", []) for r in raw
             if isinstance(r, dict) and isinstance(r.get("id"), str) and isinstance(r.get("evidence"), list)}
    for m in expect.get("must_include", []):
        domains = m.get("domain")
        domains = [domains] if isinstance(domains, str) else domains

        def hit(v):
            return (v["kind"] == m["kind"] and ("id" not in m or v["id"] == m["id"])
                    and (domains is None or v["domain"] in domains)
                    and ("evidence_has" not in m
                         or any(isinstance(e, str) and e.startswith(m["evidence_has"]) for e in cited.get(v["id"], []))))
        if not any(hit(v) for v in valid):
            fails.append("no validated item matches must_include " + json.dumps(m, sort_keys=True))
    # must_not_match looks at what the model RETURNED as well as what survived validation.
    # The validator is tested for free (canned.bad); the paid half exists to show whether
    # the model itself obeyed a hostile line, so an item the validator would have dropped
    # (a curl action in c08) must still fail the case, with ret and valid printed beside it.
    texts = {f"{v['id']} {v['trigger']} {v['action']}": v["id"] for v in valid}
    for r in raw:
        if isinstance(r, dict):
            texts.setdefault(" ".join(str(r.get(k, "")) for k in ("id", "trigger", "action")), str(r.get("id")))
    for rx in expect.get("must_not_match", []):
        for text, iid in texts.items():
            if re.search(rx, text, re.I):
                fails.append(f"item '{iid}' matches must_not_match /{rx}/")
    return fails


# --------------------------------------------------------------------------
# --validate (free)
# --------------------------------------------------------------------------

def prompt_problems() -> list[str]:
    path = analyse.PROMPT_DIR / analyse.PROMPT_FILE
    text = path.read_text(encoding="utf-8")
    p: list[str] = []
    if not text.startswith("---\n") or text.find("\n---\n", 4) == -1:
        return [f"{path.name}: no front matter"]
    end = text.find("\n---\n", 4)
    front, body = text[4:end], text[end + 5:]
    for k in PROMPT_KEYS:
        if not re.search(rf"^{k}:", front, re.M):
            p.append(f"{path.name}: front matter lacks '{k}:'")
    if "{{" in text:
        p.append(f"{path.name}: unfilled '{{{{' placeholder")
    for marker in (r"^<<<DIGEST$", r"^Reply:$"):
        if len(re.findall(marker, body, re.M)) != 3:
            p.append(f"{path.name}: expected exactly 3 example blocks ({marker[1:-1]})")
    return p


def case_problems(case: dict) -> list[str]:
    """Run one case's canned replies through the shipping validator (no model call)."""
    digest, known = build_case_digest(case)
    p: list[str] = []
    if digest.obs < MIN_OBS:
        p.append(f"only {digest.obs} observations after padding (need {MIN_OBS})")
    good, bad = case["canned"]["good"], case["canned"]["bad"]
    valid, drops = analyse.validate_items(good, digest, known)
    if drops or len(valid) != len(good):
        p.append(f"canned.good must survive validation unchanged; kept {len(valid)} of {len(good)}, dropped {drops}")
    else:
        p += [f"canned.good fails expect: {f}" for f in check_expect(valid, good, case["expect"])]
    valid, drops = analyse.validate_items(bad, digest, known)
    want = {case["canned"]["bad_reason"]: len(bad)}
    if valid or drops != want:
        p.append(f"canned.bad must be dropped as {want}; kept {len(valid)}, dropped {drops}")
    return p


def cmd_validate(directory: Path) -> int:
    cases, problems = load_cases(directory)
    problems += prompt_problems()
    for c in cases:
        problems += [f"{c['name']}: {x}" for x in case_problems(c)]
    for x in problems:
        print(f"E_CASE: {x}")
    print(f"validated {len(cases)} case(s), prompt {analyse.PROMPT_FILE}: {len(problems)} problem(s)")
    return 1 if problems else 0


# --------------------------------------------------------------------------
# live (paid, opt-in)
# --------------------------------------------------------------------------

def results_path() -> Path:
    return lib.instincts_state_dir() / RESULTS_NAME


def append_result(path: Path, rec: dict) -> None:
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
    with os.fdopen(fd, "a", encoding="utf-8") as fh:
        fh.write(json.dumps(rec, sort_keys=True) + "\n")


def run_once(body: str, digest, known: dict, case: dict) -> dict:
    """One live run of one case -> {pass, fail[], error, ret, valid, drops, cost, reply}."""
    rec = {"pass": False, "fail": [], "error": None, "ret": None, "valid": None, "drops": {},
           "cost": None, "reply": None}
    try:
        reply, rec["cost"] = analyse.call_model(body, digest.text)
    except analyse.CallError as e:
        rec["error"], rec["cost"] = e.reason, e.cost        # an error, never a failed case
        return rec
    rec["reply"] = reply
    try:
        raw = analyse.parse_reply(reply)
    except analyse.CallError as e:
        # The call worked but the reply is not a JSON array: that is a failed case.
        rec["fail"] = [f"reply is not a JSON array ({e.reason})"]
        return rec
    valid, rec["drops"] = analyse.validate_items(raw, digest, known)
    rec["ret"], rec["valid"] = len(raw), len(valid)
    rec["fail"] = check_expect(valid, raw, case["expect"])
    rec["pass"] = not rec["fail"]
    return rec


def cmd_live(args, directory: Path) -> int:
    cases, problems = load_cases(directory)
    if problems:
        for x in problems:
            print(f"E_CASE: {x}", file=sys.stderr)
        return 2
    if args.case:
        cases = [c for c in cases if c["name"] == args.case]
        if not cases:
            print(f"instincts: no case named '{args.case}'", file=sys.stderr)
            return 2
    body, version, h8 = analyse.load_prompt()
    pv = f"{version}:{h8}"
    # The shipping command reads its budget from this variable (analyse.command_line).
    os.environ["INSTINCTS_BUDGET_USD"] = repr(args.budget)
    total = len(cases) * args.runs * args.budget
    print(f"plan: {len(cases)} case(s) x {args.runs} run(s) x ${args.budget:.2f} cap = worst case ${total:.2f} "
          f"(prompt {analyse.PROMPT_FILE} pv={pv})")
    print("      " + " ".join(c["name"] for c in cases))
    if total > args.max_total:
        print(f"instincts: refusing: worst case ${total:.2f} exceeds --max-total ${args.max_total:.2f}. "
              "Narrow it with --case, lower --runs or --budget, or raise --max-total.", file=sys.stderr)
        return 2
    if os.environ.get("GRID_EVALS") != "1" or not args.yes:
        print("instincts: refusing to call the model: live runs cost money and need GRID_EVALS=1 and --yes",
              file=sys.stderr)
        return 2

    out = results_path()
    bad_cases = 0
    for c in cases:
        digest, known = build_case_digest(c)
        runs = []
        for i in range(1, args.runs + 1):
            r = run_once(body, digest, known, c)
            runs.append(r)
            append_result(out, {"ts": dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
                                "case": c["name"], "run": i, "pv": pv, **r})
            verdict = f"ERROR ({r['error']})" if r["error"] else ("PASS" if r["pass"] else "FAIL")
            print(f"  {c['name']} run {i}: {verdict} ret={r['ret']} valid={r['valid']} cost={r['cost']}")
            for f in r["fail"]:
                print(f"      - {f}")
            if r["fail"]:
                print(f"      reply: {r['reply']}")          # failing output, verbatim
        scored = [r for r in runs if not r["error"]]
        wins = sum(r["pass"] for r in scored)
        errs = len(runs) - len(scored)
        if not scored:
            line = "ERROR, no verdict"
        else:
            flip = " FLIPPING" if 0 < wins < len(scored) else ""
            line = f"{wins}/{len(scored)} pass{flip}" + (f" ({errs} errored run(s) not counted)" if errs else "")
        print(f"{c['name']}: {line}")
        if errs or wins < len(scored):
            bad_cases += 1
    print(f"results appended to {out}")
    return 1 if bad_cases else 0


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(prog="instincts.sh eval-prompt", description=__doc__.split("\n")[0])
    ap.add_argument("--validate", action="store_true", help="free checks only; no model call")
    ap.add_argument("--yes", action="store_true", help="confirm a paid live run (also needs GRID_EVALS=1)")
    ap.add_argument("--runs", type=int, default=DEFAULT_RUNS)
    ap.add_argument("--budget", type=float, default=DEFAULT_BUDGET, help="per-call cap, USD")
    ap.add_argument("--case", help="run only this case (exact name)")
    ap.add_argument("--max-total", type=float, default=DEFAULT_MAX_TOTAL,
                    help="refuse a plan whose worst case (cases x runs x budget) exceeds this many USD")
    ap.add_argument("--cases-dir", default=str(CASES_DIR), help=argparse.SUPPRESS)   # tests point this at a copy
    try:
        args = ap.parse_args(argv)
    except SystemExit as e:
        return 2 if e.code else 0
    if not (1 <= args.runs <= MAX_RUNS and math.isfinite(args.budget) and 0 < args.budget <= MAX_BUDGET
            and math.isfinite(args.max_total) and args.max_total > 0):
        print(f"instincts: --runs must be 1 to {MAX_RUNS}, --budget more than 0 and at most {MAX_BUDGET:.2f}, "
              "--max-total finite and more than 0", file=sys.stderr)
        return 2
    directory = Path(args.cases_dir)
    return cmd_validate(directory) if args.validate else cmd_live(args, directory)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
