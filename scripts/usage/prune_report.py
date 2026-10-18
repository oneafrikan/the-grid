#!/usr/bin/env python3
"""prune_report.py - propose what to drop from the always-wired baseline, from usage.

    python3 scripts/usage/prune_report.py [--window-days 90] [--rare 2]
            [--min-days 14] [--usage-dir D] [--out FILE] [--json]
    (normally via scripts/prune-report.sh)

READ-ONLY: it writes stdout (or --out) and nothing else. It never edits the
baseline, settings.json or any skill; it only prints what the operator could
apply ("apply 2, skip 3").

Inputs
  * baseline_wired()      the skills the baseline wires (name, source repo)
  * aggregate()           usage summed over every host (see aggregate.py)
  * docs/prune-keep.txt   names never to propose (front-door skills)
  * baseline file         to tell whole-repo entries from per-skill ones
  * agent-factory/examples/*.yaml   slug -> project, for the agent overlay hint

It deliberately never reads `tokens` or `hooks` from the aggregate: those are for
cost analysis, not for pruning decisions.

The report is for the OPERATOR to read. Do not feed it to an agent that can apply
proposals on its own: names in it come from host files pulled from the private repo
(filtered to a safe shape and escaped here, but still data from outside this checkout).

Per baseline skill:  uses = Skill-tool calls + slash invocations of that name,
all hosts, inside the window.  state = never (0) | rare (1..--rare) | used.

Proposals
  A  demote a repo     whole-repo baseline entry where >= 90% of its wired skills
                       are never/rare (saving = entry chars of the dropped skills)
  B  name-only a skill any other never/rare skill (saving = its listing chars);
                       all B items are also printed as one skillOverrides block
  C  unused agents     wired agents with zero uses (no saving figure)
Numbered 1..N: A and B by chars saved (largest first), then C.

Enough history means --min-days (default 14) ACTIVE days: distinct days that hold data
across all hosts. A calendar span is not enough (two days 40 days apart is not history).
A skill whose name was first seen wired after the window started (the host files'
`wired_first_seen`) is "newly wired": never proposed, counted in the evidence.

Exit 0 always, including "no baseline on this machine" and "insufficient history".
Stdlib only.
"""
from __future__ import annotations

import sys

# Never leave __pycache__ behind: the run must change no file in the repo.
sys.dont_write_bytecode = True

import argparse
import glob
import json
import os
import re

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)                              # aggregate.py
sys.path.insert(0, os.path.join(HERE, ".."))          # budget.py, lib/baseline_wired.py
sys.path.insert(0, os.path.join(HERE, "..", "lib"))

import aggregate as agg                               # noqa: E402
import budget                                         # noqa: E402  (entry sizes)
from baseline_wired import baseline_wired             # noqa: E402

HARNESS = "claude-code"       # baseline_wired() describes Claude Code's listing
DEMOTE_PCT = 90               # >= this share never/rare -> propose demoting the repo
CAVEATS = [
    "Only Skill-tool calls and slash invocations are visible; a model reading a "
    "SKILL.md directly is not counted.",
    "Slash and Skill events can double-count one use; this only matters for `rare`.",
    "Names are as stored: a private skill name appears here if a host used it.",
]


def read_names(path):
    """One name per line, `#` comments and blanks ignored; [] if the file is absent."""
    try:
        with open(path, encoding="utf-8") as fh:
            lines = fh.read().splitlines()
    except OSError:
        return []
    names = (ln.split("#", 1)[0].strip() for ln in lines)
    return [n for n in names if n]


def whole_repo_entries(baseline_path):
    """Repos the baseline wires WHOLE (a bare `repo` line, not `repo/skill`,
    `project:x` or a `-subtraction`)."""
    plain, subtracted = set(), set()
    for entry in read_names(baseline_path):
        if entry.startswith("-"):
            subtracted.add(entry[1:])
        elif "/" not in entry and not entry.startswith("project:"):
            plain.add(entry)
    return plain - subtracted


def agent_projects(grid):
    """[(slug, project)] from agent-factory/examples/*.yaml, longest slug first so
    the most specific match wins (only top-level `slug:` / `project:` are read)."""
    out = []
    for path in sorted(glob.glob(os.path.join(grid, "agent-factory", "examples", "*.yaml"))):
        slug = project = None
        with open(path, encoding="utf-8") as fh:
            for line in fh:
                m = re.match(r"^(slug|project):\s*([A-Za-z0-9._-]+)\s*(#.*)?$", line)
                if m and m.group(1) == "slug":
                    slug = m.group(2)
                elif m:
                    project = m.group(2)
        if slug and project:
            out.append((slug, project))
    return sorted(out, key=lambda sp: -len(sp[0]))


def build(grid, usage_dir, window_days, rare, min_days):
    """The whole report as a dict (rendered to markdown or dumped as JSON)."""
    rep = {"window_days": window_days, "rare": rare, "min_days": min_days}
    wired = baseline_wired(grid)
    if wired is None:
        rep["status"] = "no-baseline"
        return rep

    a = agg.aggregate(usage_dir, window_days)
    h = a.get(HARNESS) or {"skills": {}, "agents": {}, "slash": {}, "hosts": 0,
                           "first_day": None, "last_day": None, "coverage_days": 0,
                           "rejected_days": 0, "active_days": 0, "window_start": "",
                           "wired_first_seen": {"skills": {}, "agents": {}},
                           "wired": {"skills": [], "agents": []}}
    rep.update(hosts=h["hosts"], first_day=h["first_day"], last_day=h["last_day"],
               coverage_days=h["coverage_days"], rejected_days=h["rejected_days"],
               active_days=h["active_days"], ignored=a["ignored"])

    keep = set(read_names(os.path.join(grid, "docs", "prune-keep.txt")))

    # Candidate skills with their state and sizes.
    skills = []
    for w in wired:
        if w["kind"] != "skill":
            continue
        md = os.path.join(w["source_dir"], "SKILL.md")
        if not os.path.isfile(md):
            continue
        size = budget.skill_entry(w["name"], md, md, budget.DEFAULT_TRUNCATE)
        uses = h["skills"].get(w["name"], 0) + h["slash"].get(w["name"], 0)
        state = "never" if uses == 0 else "rare" if uses <= rare else "used"
        # Wired after the window began: too new to call unused. A name no host ever
        # recorded a first-seen day for (an older host file) counts as old.
        first = h["wired_first_seen"]["skills"].get(w["name"])
        new = bool(first and h["window_start"] and first > h["window_start"])
        skills.append({"name": w["name"], "repo": w["repo"], "uses": uses,
                       "state": state, "entry_chars": size["chars"],
                       "listing_chars": size["listing_chars"], "new": new})
    skills.sort(key=lambda s: s["name"])
    rep["newly_wired"] = sum(1 for s in skills if s["new"] and s["state"] != "used")
    rep["counts"] = {st: sum(1 for s in skills if s["state"] == st)
                     for st in ("used", "rare", "never")}

    # Not enough history: say so and stop (no proposals at all).
    rep["insufficient"] = h["active_days"] < min_days
    rep["proposals"] = []
    if rep["insufficient"]:
        rep["status"] = "insufficient-history"
        return rep
    rep["status"] = "ok"

    # A newly wired skill is never "unused": it protects its repo from demotion too.
    unused = lambda s: s["state"] in ("never", "rare") and not s["new"]   # noqa: E731
    proposals = []

    # A. Demote a whole-repo baseline entry that is >= 90% unused.
    baseline = os.environ.get("GRID_BASELINE") or os.path.join(grid, "baseline-submodules.txt")
    demoted = set()
    for repo in sorted(whole_repo_entries(baseline) & {s["repo"] for s in skills}):
        mine = [s for s in skills if s["repo"] == repo]
        # A repo holding a keep-listed skill is never demoted (the keeper would go
        # with it), and then none of its names can appear in a proposal line here.
        if any(s["name"] in keep for s in mine):
            continue
        dead = [s for s in mine if unused(s)]
        if len(dead) * 100 < DEMOTE_PCT * len(mine):
            continue
        demoted.add(repo)
        proposals.append({"kind": "A", "name": repo, "saved_chars": sum(s["entry_chars"] for s in dead),
                          "dropped": [s["name"] for s in dead],
                          "keep_per_skill": [s["name"] for s in mine if not unused(s)]})

    # B. name-only every other never/rare skill (nothing to save when its
    # description is never listed, e.g. disable-model-invocation, so skip those).
    for s in skills:
        if unused(s) and s["repo"] not in demoted and s["name"] not in keep \
                and s["listing_chars"] > 0:
            proposals.append({"kind": "B", "name": s["name"], "state": s["state"],
                              "uses": s["uses"], "saved_chars": s["listing_chars"]})

    # Largest saving first; ties by name so the output is deterministic.
    proposals.sort(key=lambda p: (-p["saved_chars"], p["name"]))

    # C. Wired agents with no use in the window, with an overlay hint if the
    # agent name starts with a known composed project's `<slug>-`.
    projects = agent_projects(grid)
    for name in h["wired"]["agents"]:
        if h["agents"].get(name, 0) or name in keep:
            continue
        hint = next((f"-project:{proj}" for slug, proj in projects
                     if name.startswith(slug + "-")), None)
        proposals.append({"kind": "C", "name": name, "saved_chars": None, "overlay": hint})

    for i, p in enumerate(proposals, 1):
        p["n"] = i
    rep["proposals"] = proposals
    rep["skillOverrides"] = {p["name"]: "name-only" for p in proposals if p["kind"] == "B"}
    return rep


_PLAIN = re.compile(r"[A-Za-z0-9-][A-Za-z0-9._:@+-]*\Z", re.ASCII)


def _q(name):
    """A name for the markdown. A well-formed name is printed as is; anything else (a
    control character, a backtick, a newline that could start a forged numbered line) is
    printed JSON-escaped, with the backtick escaped too."""
    name = str(name)
    if _PLAIN.match(name):
        return name
    return json.dumps(name).replace("`", "\\u0060")


def render(rep):
    """Markdown for the report dict."""
    if rep["status"] == "no-baseline":
        return "no baseline on this machine\n"
    L = ["# Prune report", "",
         f"Window: {rep['window_days']} days ending {rep['last_day'] or 'n/a'}; "
         f"rare = 1..{rep['rare']} uses; baseline skills: "
         f"{rep['counts']['used']} used, {rep['counts']['rare']} rare, "
         f"{rep['counts']['never']} never", ""]
    if rep["insufficient"]:
        L += [f"insufficient history: {rep['active_days']} active days of "
              f"{rep['min_days']} required. No proposals.", ""]
    else:
        ps = rep["proposals"]
        L += [f"## Proposals ({len(ps)}: A {sum(p['kind'] == 'A' for p in ps)}, "
              f"B {sum(p['kind'] == 'B' for p in ps)}, C {sum(p['kind'] == 'C' for p in ps)})", "",
              'Reply e.g. "apply 2, skip 3".', ""]
        for p in ps:
            if p["kind"] == "A":
                keepers = ", ".join(_q(k) for k in p["keep_per_skill"]) or "none"
                L.append(f"{p['n']}. A: demote repo `{_q(p['name'])}` to library, saves "
                         f"~{p['saved_chars']} chars. Drops: {', '.join(_q(d) for d in p['dropped'])}. "
                         f"Or replace the line with per-skill entries for the used ones: {keepers}.")
            elif p["kind"] == "B":
                L.append(f"{p['n']}. B: name-only `{_q(p['name'])}` ({p['state']}, {p['uses']} uses), "
                         f"saves ~{p['saved_chars']} chars.")
            else:
                hint = f" Overlay: `{_q(p['overlay'])}`." if p["overlay"] else ""
                L.append(f"{p['n']}. C: agent `{_q(p['name'])}` never used.{hint}")
        if not ps:
            L.append("Nothing to propose.")
        L.append("")
        if rep["skillOverrides"]:
            L += ["## skillOverrides (all B items, ready to paste)", "", "```json",
                  json.dumps({"skillOverrides": rep["skillOverrides"]}, indent=2, sort_keys=True),
                  "```", ""]
    L += ["## Evidence", "",
          f"- Hosts reporting: {rep['hosts']}",
          f"- Active days (days holding data): {rep['active_days']}",
          f"- Day coverage: {rep['coverage_days']} days "
          f"({rep['first_day'] or 'n/a'} to {rep['last_day'] or 'n/a'})"]
    if rep.get("newly_wired"):
        L.append(f"- {rep['newly_wired']} newly wired skills not assessed (wired after the window began)")
    if rep["ignored"]:
        # File names come from a pulled repo: json.dumps keeps a newline in a name from
        # starting a forged line of the report.
        names = ", ".join(json.dumps(n).replace("`", "\\u0060") for n in rep["ignored"])
        L.append(f"- Ignored usage files (unparseable or unknown schema): {names}")
    if rep.get("rejected_days"):
        L.append(f"- Caveat: {rep['rejected_days']} stored day key(s) were ignored: outside 2024-01-01..tomorrow (UTC) "
                 f"or not a date.")
    L += [f"- Caveat: {c}" for c in CAVEATS]
    return "\n".join(L) + "\n"


def main():
    ap = argparse.ArgumentParser(description="Propose baseline pruning from usage data (read-only).")
    ap.add_argument("--window-days", type=int, default=90)
    ap.add_argument("--rare", type=int, default=2)
    ap.add_argument("--min-days", type=int, default=14,
                    help="active days (days holding data, all hosts) required before proposing anything")
    ap.add_argument("--usage-dir", default=None)
    ap.add_argument("--out", default=None, help="write here instead of stdout")
    ap.add_argument("--json", action="store_true", help="machine-readable output")
    args = ap.parse_args()

    grid = os.path.realpath(os.environ.get("GRID_DIR") or os.path.join(HERE, "..", ".."))
    usage_dir = args.usage_dir or os.path.join(
        os.environ.get("GRID_PRIVATE_DIR") or os.path.join(os.path.expanduser("~"), ".the-grid-private"),
        "usage")
    try:
        rep = build(grid, usage_dir, args.window_days, args.rare, args.min_days)
    except RuntimeError as exc:           # wire.sh failed while measuring
        print(f"prune-report: {exc}", file=sys.stderr)
        return 2
    text = (json.dumps(rep, indent=2, sort_keys=True) + "\n") if args.json else render(rep)
    if args.out:
        with open(args.out, "w", encoding="utf-8") as fh:
            fh.write(text)
    else:
        sys.stdout.write(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
