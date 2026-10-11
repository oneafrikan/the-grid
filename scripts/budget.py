#!/usr/bin/env python3
"""budget.py - measure the skill/agent LISTING budget and gate regressions.

Claude Code lists every skill name but shares ONE description budget (~1% of
context) across all of them and silently drops the least-used descriptions when
it overflows. This script measures how many characters the-grid puts into that
listing, and fails the commit gate when the number grows past a committed target
(a ratchet: targets only go down in normal work).

Entry cost model (a stable proxy, not the exact undocumented line format):

    listing_text = whitespace-collapsed description [+ " " + when_to_use],
                   cut to truncate_at (1536); "" when the frontmatter has
                   disable-model-invocation: true (not listed at all)
    entry_chars  = len(name) + len(listing_text) + 4       # "- name: desc\\n"

Two scopes:
  owned     skills/*/SKILL.md + agent-factory/roles/*/role.yaml (_retired
            skipped). Public and deterministic, so enforced everywhere (CI too).
  baseline  the skills the BASELINE manifest wires (no machine overlay), found
            by scripts/lib/baseline_wired.py. Only measurable on a machine that
            has baseline-submodules.txt and initialised submodules; elsewhere it
            is skipped and --check exits 3 instead of 0 (the gate counts that
            as a pass with a notice).

Usage (python3 scripts/budget.py ...):
  --report         default: totals per scope, longest entries, count over limit
  --check          exit 1 on any regression/limit breach (each failure prints the
                   offending path), 3 if only the baseline scope was skipped, else 0
  --update-target  rewrite the totals in docs/budget-target.json to the current
                   measurement; refuses to RAISE a number without --allow-raise
  --json           machine-readable output, sorted keys
Environment: GRID_DIR (repo root; default: parent of scripts/), GRID_BASELINE
(baseline manifest, passed through to wire.sh).

Stdlib only. --check also enforces the sections/ integrity rule for split
SKILL.md bodies (every sections/*.md indexed from SKILL.md, every index line
resolves, no section over SECTION_MAX_BYTES).
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys

# Importing baseline_wired must not leave a __pycache__ in the repo.
sys.dont_write_bytecode = True
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "lib"))
from baseline_wired import baseline_wired  # noqa: E402  (path set up just above)

TARGET_REL = os.path.join("docs", "budget-target.json")
DEFAULT_TRUNCATE = 1536
ENTRY_OVERHEAD = 4          # "- " before and ": " ... "\n" after, approximate
SECTION_MAX_BYTES = 6000    # per skills/<name>/sections/*.md (design.md, "Sections")
# An index line in SKILL.md: "- sections/<file>: read when ..."
SECTION_REF_RE = re.compile(r"^- sections/([A-Za-z0-9._-]+):", re.M)

# Skeleton used when docs/budget-target.json does not exist yet.
DEFAULT_TARGET = {
    "schema": 1,
    "truncate_at": DEFAULT_TRUNCATE,
    "per_entry_max_chars": 0,
    "owned": {
        "skills_max_chars": 0,
        "orchestrator_roles_max_chars": 0,
        "agent_roles_max_chars": 0,
        "skill_body_max_bytes": 0,
    },
    "baseline": {"skills_max_chars": 0},
}

# (scope, target key, measurement key) for the totals the ratchet covers.
TOTALS = [
    ("owned", "skills_max_chars", "skills"),
    ("owned", "orchestrator_roles_max_chars", "orchestrator_roles"),
    ("owned", "agent_roles_max_chars", "agent_roles"),
    ("baseline", "skills_max_chars", "skills"),
]


# --------------------------------------------------------------------------
# Frontmatter / role.yaml scalar reader (stdlib; handles only what we need)
# --------------------------------------------------------------------------
# A real YAML parser is not in the stdlib, and the repo's other tiny parser
# rejects block scalars, which owned descriptions use. So: read TOP-LEVEL
# `key: value` pairs, where value is a plain, 'single' or "double" quoted
# scalar, a folded (>, >-) or literal (|, |-) block. Everything is returned
# whitespace-collapsed, with a flag saying whether it is "single line".

KEY_RE = re.compile(r"^([A-Za-z_][\w-]*):(?:[ \t]+(.*))?$")


def _collapse(text: str) -> str:
    return " ".join(text.split())


def _quoted(text: str, quote: str) -> str:
    """Return the contents of a quoted scalar that starts at text[0]."""
    out, i = [], 1
    while i < len(text):
        ch = text[i]
        if quote == "'" and ch == "'":
            if text[i + 1:i + 2] == "'":      # '' is an escaped single quote
                out.append("'"); i += 2; continue
            break
        if quote == '"' and ch == "\\" and i + 1 < len(text):
            nxt = text[i + 1]                 # \" and \\ matter; \n is just a space here
            out.append({"n": " ", "t": " "}.get(nxt, nxt)); i += 2; continue
        if quote == '"' and ch == '"':
            break
        out.append(ch); i += 1
    return "".join(out)


def _scalar(rest: str, cont: list):
    """(value, single_line) for one key's inline text plus its continuation lines."""
    rest = rest.strip()
    body = [ln for ln in cont if ln.strip()]
    if rest[:1] in (">", "|"):                    # block scalar (indicator, optional comment)
        literal = rest[0] == "|"
        # A literal block keeps its line breaks, so >1 non-empty line is multi-line.
        return _collapse(" ".join(body)), not (literal and len(body) > 1)
    full = " ".join([rest] + [ln.strip() for ln in body])
    if rest[:1] in ("'", '"'):
        return _collapse(_quoted(full, rest[0])), True
    # Plain scalar: " #..." starts a comment; continuation lines fold to one line.
    parts = [re.sub(r"\s+#.*$", "", p) for p in [rest] + [ln.strip() for ln in body]]
    return _collapse(" ".join(parts)), True


def parse_top_level(lines: list) -> dict:
    """{key: (value, single_line)} for every top-level `key:` in `lines`."""
    out, i = {}, 0
    while i < len(lines):
        m = KEY_RE.match(lines[i])
        i += 1
        if not m:
            continue
        key, rest = m.group(1), m.group(2) or ""
        cont = []
        # Continuation = blank or indented lines directly after the key.
        while i < len(lines) and (not lines[i].strip() or lines[i][0] in " \t"):
            cont.append(lines[i]); i += 1
        out[key] = _scalar(rest, cont)
    return out


def read_frontmatter(path: str) -> dict:
    """Parsed top-level keys of a SKILL.md's `---` frontmatter ({} if none)."""
    with open(path, encoding="utf-8") as fh:
        lines = fh.read().splitlines()
    if not lines or lines[0].strip() != "---":
        return {}
    end = next((i for i in range(1, len(lines)) if lines[i].strip() == "---"), len(lines))
    return parse_top_level(lines[1:end])


def read_yaml(path: str) -> dict:
    with open(path, encoding="utf-8") as fh:
        return parse_top_level(fh.read().splitlines())


# --------------------------------------------------------------------------
# Measurement
# --------------------------------------------------------------------------
def make_entry(name, path, desc, single_line, wtu, disabled, truncate_at):
    """One listing entry. `path` is repo-relative (printed in failures)."""
    if disabled:
        listing = ""                         # description never reaches context
    else:
        listing = desc + (" " + wtu if wtu else "")
        listing = listing[:truncate_at]
    return {
        "name": name,
        "path": path,
        "listing_chars": len(listing),
        "chars": len(name) + len(listing) + ENTRY_OVERHEAD,
        "single_line": single_line,
        "disabled": disabled,
    }


def skill_entry(name, skill_md, rel, truncate_at):
    fm = read_frontmatter(skill_md)
    desc, single = fm.get("description", ("", True))
    wtu = fm.get("when_to_use", ("", True))[0]
    disabled = fm.get("disable-model-invocation", ("", True))[0].lower() == "true"
    e = make_entry(name, rel, desc, single, wtu, disabled, truncate_at)
    e["body_bytes"] = os.path.getsize(skill_md)
    return e


def total(entries):
    return {"count": len(entries), "chars": sum(e["chars"] for e in entries)}


def measure(grid, truncate_at):
    """Measure both scopes. `baseline` is None when it cannot be measured here."""
    entries = {"skills": [], "orchestrator_roles": [], "agent_roles": []}

    # owned skills: skills/<name>/SKILL.md
    sdir = os.path.join(grid, "skills")
    for name in sorted(os.listdir(sdir)) if os.path.isdir(sdir) else []:
        md = os.path.join(sdir, name, "SKILL.md")
        if os.path.isfile(md):
            entries["skills"].append(
                skill_entry(name, md, os.path.join("skills", name, "SKILL.md"), truncate_at))

    # owned roles: measured from role.yaml source, never from composed output or
    # private roles, so the number is the same on every machine.
    rdir = os.path.join(grid, "agent-factory", "roles")
    for name in sorted(os.listdir(rdir)) if os.path.isdir(rdir) else []:
        ry = os.path.join(rdir, name, "role.yaml")
        if name == "_retired" or not os.path.isfile(ry):
            continue
        meta = read_yaml(ry)
        if "description" in meta:
            desc, single = meta["description"]
        else:  # legacy formula: "<title>. <summary>"
            title = meta.get("title", (name, True))[0]
            desc, single = f"{title}. {meta.get('summary', ('', True))[0]}", True
        orch = meta.get("orchestrator", ("", True))[0].lower() == "true"
        e = make_entry(name, os.path.join("agent-factory", "roles", name, "role.yaml"),
                       desc, single, "", False, truncate_at)
        entries["orchestrator_roles" if orch else "agent_roles"].append(e)

    # baseline: skills the baseline manifest wires (None = not measurable here)
    wired = baseline_wired(grid)
    base = None
    if wired is not None:
        base = []
        for w in wired:
            if w["kind"] != "skill":
                continue                      # agents are a different listing
            md = os.path.join(w["source_dir"], "SKILL.md")
            if os.path.isfile(md):
                base.append(skill_entry(w["name"], md, os.path.relpath(md, grid), truncate_at))
        base.sort(key=lambda e: e["name"])

    return entries, base


def summarise(entries, base):
    """The JSON-able measurement: totals plus every entry (sorted, deterministic)."""
    out = {"owned": {k: total(v) for k, v in entries.items()},
           "baseline": {"skipped": True} if base is None
           else {"skills": total(base)},
           "entries": {k: v for k, v in entries.items()}}
    if base is not None:
        out["entries"]["baseline_skills"] = base
    return out


# --------------------------------------------------------------------------
# Target file, check, update
# --------------------------------------------------------------------------
def load_target(grid):
    path = os.path.join(grid, TARGET_REL)
    try:
        with open(path, encoding="utf-8") as fh:
            return json.load(fh)
    except FileNotFoundError:
        return None
    except ValueError as exc:
        sys.exit(f"budget: {TARGET_REL} is not valid JSON: {exc}")


def current_numbers(summary):
    """{(scope, target key): measured value} for the ratcheted totals."""
    nums = {}
    for scope, tkey, mkey in TOTALS:
        if scope == "owned":
            nums[(scope, tkey)] = summary["owned"][mkey]["chars"]
        elif "skipped" not in summary["baseline"]:
            nums[(scope, tkey)] = summary["baseline"][mkey]["chars"]
    return nums


def check_sections(grid, rel_skill_md):
    """Sections integrity for one owned skill; failure strings (each names a path)."""
    skill_rel = os.path.dirname(rel_skill_md)
    sdir = os.path.join(grid, skill_rel, "sections")
    with open(os.path.join(grid, rel_skill_md), encoding="utf-8") as fh:
        refs = set(SECTION_REF_RE.findall(fh.read()))
    on_disk = set()
    if os.path.isdir(sdir):
        on_disk = {f for f in os.listdir(sdir)
                   if f.endswith(".md") and os.path.isfile(os.path.join(sdir, f))}
    fails = []
    for f in sorted(on_disk - refs):
        fails.append(f"{skill_rel}/sections/{f}: not listed in SKILL.md "
                     f"(add a '- sections/{f}: read when ...' line)")
    for f in sorted(refs - on_disk):
        fails.append(f"{rel_skill_md}: lists sections/{f} but the file does not exist")
    for f in sorted(on_disk):
        size = os.path.getsize(os.path.join(sdir, f))
        if size > SECTION_MAX_BYTES:
            fails.append(f"{skill_rel}/sections/{f}: section is {size} bytes "
                         f"(max {SECTION_MAX_BYTES})")
    return fails


def run_checks(summary, target, grid=None):
    """List of failure strings (each names the offending path or target key)."""
    if target is None:
        return [f"{TARGET_REL}: missing - create it with: "
                "python3 scripts/budget.py --update-target --allow-raise"]
    fails = []
    # 1. totals vs. the ratchet
    for (scope, tkey), measured in sorted(current_numbers(summary).items()):
        limit = target.get(scope, {}).get(tkey)
        if limit is None:
            fails.append(f"{TARGET_REL}: no {scope}.{tkey} (measured {measured})")
        elif measured > limit:
            fails.append(f"{scope}.{tkey}: {measured} chars > target {limit} "
                         f"(shrink descriptions, or review + --update-target --allow-raise)")
    # 2. per-entry limits on owned entries (skills and role descriptions)
    per_entry = target.get("per_entry_max_chars")
    for group in ("skills", "orchestrator_roles", "agent_roles"):
        for e in summary["entries"][group]:
            if e["disabled"]:
                continue                       # not listed, so no listing limit
            if not e["single_line"]:
                fails.append(f"{e['path']}: description spans more than one line")
            if per_entry is not None and e["listing_chars"] > per_entry:
                fails.append(f"{e['path']}: description is {e['listing_chars']} chars "
                             f"(max {per_entry})")
    # 3. SKILL.md body size
    body_max = target.get("owned", {}).get("skill_body_max_bytes")
    if body_max is not None:
        for e in summary["entries"]["skills"]:
            if e["body_bytes"] > body_max:
                fails.append(f"{e['path']}: SKILL.md is {e['body_bytes']} bytes (max {body_max})")
    # 4. sections/ integrity for every owned skill
    if grid is not None:
        for e in summary["entries"]["skills"]:
            fails.extend(check_sections(grid, e["path"]))
    return fails


def update_target(grid, summary, target, allow_raise):
    """Rewrite totals to the current measurement. Returns (exit code, messages)."""
    data = json.loads(json.dumps(target if target is not None else DEFAULT_TARGET))
    msgs, raises = [], []
    for (scope, tkey), measured in sorted(current_numbers(summary).items()):
        old = data.setdefault(scope, {}).get(tkey, 0)
        if measured > old and not allow_raise:
            raises.append(f"{scope}.{tkey}: {old} -> {measured}")
        elif measured != old:
            data[scope][tkey] = measured
            msgs.append(f"{scope}.{tkey}: {old} -> {measured}")
    if "skipped" in summary["baseline"]:
        msgs.append("baseline.skills_max_chars left unchanged (baseline not measurable here)")
    if raises:
        # All-or-nothing: never write a partly updated file.
        return 1, ["refusing to RAISE a target without --allow-raise:"] + \
            ["  " + r for r in raises]
    path = os.path.join(grid, TARGET_REL)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(json.dumps(data, indent=2, ensure_ascii=False) + "\n")
    return 0, msgs or ["targets already match the measurement"]


# --------------------------------------------------------------------------
# Output
# --------------------------------------------------------------------------
def print_report(summary, target):
    lim = lambda scope, key: (target or {}).get(scope, {}).get(key, "-")  # noqa: E731
    print("owned (skills/ + agent-factory/roles/)")
    for _, tkey, mkey in [t for t in TOTALS if t[0] == "owned"]:
        t = summary["owned"][mkey]
        print(f"  {mkey:<20} {t['count']:>4} entries {t['chars']:>7} chars   "
              f"target {lim('owned', tkey)}")
    b = summary["baseline"]
    if "skipped" in b:
        print("baseline: SKIPPED (needs baseline-submodules.txt and initialised submodules)")
    else:
        print(f"baseline  {'skills':<20} {b['skills']['count']:>4} entries "
              f"{b['skills']['chars']:>7} chars   target {lim('baseline', 'skills_max_chars')}")
    owned = [e for g in ("skills", "orchestrator_roles", "agent_roles")
             for e in summary["entries"][g] if not e["disabled"]]
    per_entry = (target or {}).get("per_entry_max_chars")
    over = [e for e in owned if per_entry and e["listing_chars"] > per_entry]
    print(f"owned entries over per_entry_max_chars ({per_entry}): {len(over)}")
    print("longest owned entries:")
    for e in sorted(owned, key=lambda e: (-e["listing_chars"], e["path"]))[:15]:
        print(f"  {e['listing_chars']:>5}  {e['path']}")


def main():
    ap = argparse.ArgumentParser(description="Measure and gate the skill listing budget.")
    mode = ap.add_mutually_exclusive_group()
    mode.add_argument("--report", action="store_true", help="print totals (default)")
    mode.add_argument("--check", action="store_true", help="fail on regression")
    mode.add_argument("--update-target", action="store_true", help="rewrite totals in the target file")
    ap.add_argument("--allow-raise", action="store_true", help="let --update-target raise a number")
    ap.add_argument("--json", action="store_true", help="machine-readable output")
    args = ap.parse_args()

    grid = os.path.realpath(os.environ.get("GRID_DIR") or os.path.join(HERE, ".."))
    target = load_target(grid)
    truncate_at = (target or {}).get("truncate_at", DEFAULT_TRUNCATE)
    try:
        entries, base = measure(grid, truncate_at)
    except RuntimeError as exc:
        print(f"budget: {exc}", file=sys.stderr)
        return 2
    summary = summarise(entries, base)

    if args.update_target:
        code, msgs = update_target(grid, summary, target, args.allow_raise)
        print("\n".join(msgs), file=sys.stderr if code else sys.stdout)
        return code

    if args.check:
        fails = run_checks(summary, target, grid)
        if args.json:
            print(json.dumps(dict(summary, failures=fails), indent=2, sort_keys=True))
        else:
            for f in fails:
                print(f"budget: FAIL {f}")
            if not fails:
                print("budget: OK (owned totals within docs/budget-target.json)")
        if fails:
            return 1
        if base is None:
            print("budget: baseline scope skipped (no baseline file or uninitialised "
                  "submodules); owned scope OK", file=sys.stderr)
            return 3
        return 0

    if args.json:
        print(json.dumps(summary, indent=2, sort_keys=True))
    else:
        print_report(summary, target)
    return 0


if __name__ == "__main__":
    sys.exit(main())
