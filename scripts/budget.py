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
                   measurement; refuses to RAISE a number without --allow-raise,
                   and while any owned file cannot be measured faithfully
  --json           machine-readable output, sorted keys
Environment: GRID_DIR (repo root; default: parent of scripts/), GRID_BASELINE
(baseline manifest, passed through to wire.sh).

Fail closed: a SKILL.md or role.yaml this reader cannot measure faithfully (UTF-8 BOM,
invalid UTF-8, quoted top-level key, indented `---` in the frontmatter, duplicate key, no
description, a line-break character other than \\n such as U+2028) fails --check by path and reason instead of counting 0 characters. For
baseline (upstream) skills the same problems are only warned on stderr.

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
# A top-level key written in quotes is valid YAML that KEY_RE would skip, so the entry would
# measure 0 characters while the gate printed OK (R20.sec.F8). It is reported, not skipped.
QUOTED_KEY_RE = re.compile(r"""^["'][A-Za-z_][\w-]*["']\s*:""")
BOM = "\ufeff"
NO_FRONTMATTER = "no `---` frontmatter block at the top of the file"
# str.splitlines() also breaks on these; YAML 1.2 readers keep U+0085/U+2028/U+2029 inside the
# line and none of the others is a YAML break at all (a bare CR is, to some readers). A reader
# that breaks where another does not sees a different key set, so `description: short<sep>...`
# was under-counted (NF-055 VF2). Lines are cut on \n only (CRLF tolerated) and any of these
# in the text that is read is a named problem, the stance scripts/lib/fmshape.py takes
# (its _BAD_CHAR class carries the same characters; tabs stay legal here as indentation).
LINE_BREAK_RE = re.compile("[\r\x0b\x0c\x1c-\x1e\x85\u2028\u2029]")


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


def _strip_comment(part: str) -> str:
    """`part` without a trailing ` #...` comment; same result as re.sub(r"\\s+#.*$", "", part).

    The regex was quadratic on a long whitespace run (a 1 MB run took over 100 s: every
    start inside the run re-scans it looking for a `#`). A `#` starts a comment only when
    whitespace precedes it, so find the first such `#` with str.find (linear) and drop the
    whitespace in front of it. A `#` at index 0, or glued to a word (`a#b`), is not one.
    """
    i = part.find("#")
    while i != -1:
        if i > 0 and part[i - 1].isspace():           # str.isspace == the regex's \s
            return part[:i].rstrip()
        i = part.find("#", i + 1)
    return part


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
    parts = [_strip_comment(p) for p in [rest] + [ln.strip() for ln in body]]
    return _collapse(" ".join(parts)), True


def split_lines(text: str) -> list:
    """Lines of `text` cut on \\n alone; one trailing \\r per line (CRLF) is dropped."""
    return [ln[:-1] if ln.endswith("\r") else ln for ln in text.split("\n")]


def line_break_problems(lines: list) -> list:
    """A named problem when `lines` hold a character that some reader treats as a line break
    and this one does not (see LINE_BREAK_RE); empty when they are clean."""
    found = sorted({m.group() for ln in lines for m in LINE_BREAK_RE.finditer(ln)})
    if not found:
        return []
    names = ", ".join(f"U+{ord(c):04X}" for c in found)
    return [f"a line-break character other than \\n ({names}) in the text that is read: readers "
            "disagree on where the line ends, so the description may be under-counted; remove it"]


def parse_top_level(lines: list):
    """({key: (value, single_line)}, problems) for every top-level `key:` in `lines`.

    `problems` lists what this reader cannot measure faithfully (quoted key, duplicate
    key); the caller reports them, so a form it mishandles fails the gate instead of
    silently measuring 0 characters."""
    out, problems, i = {}, [], 0
    while i < len(lines):
        m = KEY_RE.match(lines[i])
        if QUOTED_KEY_RE.match(lines[i]):
            problems.append(f"top-level key is quoted ({lines[i].split(':')[0].strip()}): "
                            "the budget reader only understands bare keys; write it unquoted")
        i += 1
        if not m:
            continue
        key, rest = m.group(1), m.group(2) or ""
        if key in out:
            problems.append(f"duplicate top-level key {key!r} (parsers disagree on which one wins)")
        cont = []
        # Continuation = blank or indented lines directly after the key.
        while i < len(lines) and (not lines[i].strip() or lines[i][0] in " \t"):
            cont.append(lines[i]); i += 1
        out[key] = _scalar(rest, cont)
    return out, problems


def read_text(path: str):
    """(text or None, problems). Strict UTF-8: a file that is not valid UTF-8 is a named
    problem, never a traceback. A leading BOM is stripped (so the entry is still measured
    as the author meant it) and reported, because a reader that does not strip it sees no
    frontmatter at all."""
    with open(path, "rb") as fh:
        raw = fh.read()
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError as exc:
        return None, [f"not valid UTF-8 (byte {exc.start}): the description cannot be measured"]
    if text.startswith(BOM):
        return text[1:], ["begins with a UTF-8 BOM before the first line (a reader that does "
                          "not strip it sees no frontmatter); remove the BOM"]
    return text, []


def read_frontmatter(path: str):
    """({key: (value, single_line)}, problems) for a SKILL.md's `---` frontmatter.

    The block ends at the first COLUMN-0 `---`, as in YAML. An indented `---` before it
    (inside a block scalar) is content to YAML but ended the block for older readers, so
    it is reported; the text after it is still measured."""
    text, problems = read_text(path)
    if text is None:
        return {}, problems
    lines = split_lines(text)
    if lines[0].rstrip(" \t") != "---":
        return {}, problems + [NO_FRONTMATTER]
    end = next((i for i in range(1, len(lines)) if lines[i].rstrip(" \t") == "---"), len(lines))
    # The closing fence line is included in the scan. A separator glued to a fence is not a
    # fence here (the fence test strips only spaces and tabs): after the OPENING `---` the
    # file already failed above as having no frontmatter; after the CLOSING one `end` runs to
    # the last line, so the region holds the separator and is named below (alongside the
    # missing-fence problem). Both are tested (tests/test_budget.bats, NF-060 VG2).
    problems += line_break_problems(lines[:end + 1])
    if end == len(lines):
        # skill_frontmatter.py and catalog.sh read an unclosed fence as NO frontmatter; the rest
        # of the file is still measured (a conservative count), but the disagreement is named.
        problems.append("the frontmatter has no closing `---` fence (other readers see no "
                        "frontmatter at all); add the closing fence")
    if any(ln.strip() == "---" for ln in lines[1:end]):
        problems.append("an indented `---` inside the frontmatter: some readers end the "
                        "block there; rewrite the text so no line is only `---`")
    fm, more = parse_top_level(lines[1:end])
    return fm, problems + more


def read_yaml(path: str):
    """({key: (value, single_line)}, problems) for a role.yaml."""
    text, problems = read_text(path)
    if text is None:
        return {}, problems
    lines = split_lines(text)
    meta, more = parse_top_level(lines)
    return meta, problems + line_break_problems(lines) + more


# --------------------------------------------------------------------------
# Measurement
# --------------------------------------------------------------------------
def make_entry(name, path, desc, single_line, wtu, disabled, truncate_at, problems=()):
    """One listing entry. `path` is repo-relative (printed in failures). `problems` are
    what the reader could not measure faithfully; --check fails on them for owned entries
    and only warns for baseline (upstream) ones."""
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
        "problems": list(problems),
    }


def skill_entry(name, skill_md, rel, truncate_at):
    fm, problems = read_frontmatter(skill_md)
    desc, single = fm.get("description", ("", True))
    wtu = fm.get("when_to_use", ("", True))[0]
    disabled = fm.get("disable-model-invocation", ("", True))[0].lower() == "true"
    # A skill that is never listed (disable-model-invocation) has no description to
    # under-count, so it may omit the key. An unreadable file or missing block already
    # has its own problem above.
    if "description" not in fm and not disabled and not any(
            p == NO_FRONTMATTER or p.startswith("not valid UTF-8") for p in problems):
        problems = problems + ["no description key (the entry would be measured as 0 characters)"]
    e = make_entry(name, rel, desc, single, wtu, disabled, truncate_at, problems)
    e["body_bytes"] = os.path.getsize(skill_md)
    return e


def dangling(path):
    """True for a symlink whose target is missing: os.path.isfile() calls that False too, so
    the entry used to be skipped without a word (NF-055 VF6)."""
    return os.path.islink(path) and not os.path.exists(path)


def dangling_entry(name, rel, truncate_at):
    """An owned entry for a dangling SKILL.md / role.yaml symlink: nothing to measure, so only
    the problem (which fails --check by path) and a zero body."""
    e = make_entry(name, rel, "", True, "", False, truncate_at,
                   ["dangling symlink (its target does not exist), so nothing can be measured"])
    e["body_bytes"] = 0
    e["unreadable"] = True
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
        rel = os.path.join("skills", name, "SKILL.md")
        if dangling(md):
            entries["skills"].append(dangling_entry(name, rel, truncate_at))
        elif os.path.isfile(md):
            entries["skills"].append(skill_entry(name, md, rel, truncate_at))

    # owned roles: measured from role.yaml source, never from composed output or
    # private roles, so the number is the same on every machine.
    rdir = os.path.join(grid, "agent-factory", "roles")
    for name in sorted(os.listdir(rdir)) if os.path.isdir(rdir) else []:
        ry = os.path.join(rdir, name, "role.yaml")
        if name == "_retired":
            continue
        if dangling(ry):
            entries["agent_roles"].append(dangling_entry(
                name, os.path.join("agent-factory", "roles", name, "role.yaml"), truncate_at))
            continue
        if not os.path.isfile(ry):
            continue
        meta, problems = read_yaml(ry)
        if "description" in meta:
            desc, single = meta["description"]
        else:  # fallback formula: "<title>. <summary>", still measured so a total exists
            title = meta.get("title", (name, True))[0]
            desc, single = f"{title}. {meta.get('summary', ('', True))[0]}", True
            # compose.py builds the composed listing text with its own description
            # functions (agent-factory/compose.py subagent_description), which differ from
            # this fallback. budget.py is stdlib-only and runs without the agent-factory
            # venv, so it cannot call them: it requires description: instead.
            if not any(p.startswith("not valid UTF-8") for p in problems):
                problems = problems + [f"role {name} has no description; the composed "
                                       "listing text differs from the measured fallback"]
        orch = meta.get("orchestrator", ("", True))[0].lower() == "true"
        # Accepted small under-count: the entry name here is the bare role dir, while the
        # composed agent is named "<slug>-<role>", so len(name) is a few characters short.
        e = make_entry(name, os.path.join("agent-factory", "roles", name, "role.yaml"),
                       desc, single, "", False, truncate_at, problems)
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
            data = json.load(fh)
    except FileNotFoundError:
        return None
    except ValueError as exc:       # bad JSON and invalid UTF-8 (UnicodeDecodeError) alike
        sys.exit(f"budget: {TARGET_REL} is not valid JSON: {exc}")
    except RecursionError:          # nesting thousands deep: json raises this, not ValueError
        sys.exit(f"budget: {TARGET_REL} is nested too deeply to read")
    # Every later step does target.get(...), so a list, string or number would end in a
    # traceback; a mistyped limit would crash a comparison. Say which, once, here.
    if not isinstance(data, dict):
        sys.exit(f"budget: {TARGET_REL} must be a JSON object")
    for section in ("owned", "baseline"):
        if section in data and not isinstance(data[section], dict):
            sys.exit(f"budget: {TARGET_REL}: {section} must be a JSON object")
    numbers = [("truncate_at", data.get("truncate_at")),
               ("per_entry_max_chars", data.get("per_entry_max_chars"))]
    for section in ("owned", "baseline"):
        numbers += [(f"{section}.{k}", v) for k, v in data.get(section, {}).items()
                    if k.endswith(("_chars", "_bytes"))]
    for key, val in numbers:
        # null is allowed here: run_checks reports a missing limit by name. bool is an int
        # subclass in Python, so it is refused explicitly.
        if val is not None and (isinstance(val, bool) or not isinstance(val, int)):
            sys.exit(f"budget: {TARGET_REL}: {key} must be an integer (or null), got {val!r}")
    return data


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
    # errors="replace": invalid UTF-8 is already a named failure from the frontmatter read.
    with open(os.path.join(grid, rel_skill_md), encoding="utf-8", errors="replace") as fh:
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
    # 0. the target must be complete: a limit that is missing or null used to switch its own
    #    check off silently, and `schema` was never read. Fail closed (R20.qa.F7).
    if target.get("schema") != 1:
        fails.append(f"{TARGET_REL}: schema is {target.get('schema')!r}, this checker reads schema 1")
    if target.get("per_entry_max_chars") is None:
        fails.append(f"{TARGET_REL}: no per_entry_max_chars (the per-entry limit would be skipped)")
    if target.get("owned", {}).get("skill_body_max_bytes") is None:
        fails.append(f"{TARGET_REL}: no owned.skill_body_max_bytes (the SKILL.md size limit would be skipped)")
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
            # forms the reader cannot measure faithfully fail closed (owned files are ours
            # to fix; baseline ones only warn, see baseline_warnings)
            for problem in e["problems"]:
                fails.append(f"{e['path']}: {problem}")
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
            if not e.get("unreadable"):         # a dangling SKILL.md has no index to check
                fails.extend(check_sections(grid, e["path"]))
    return fails


def baseline_warnings(summary):
    """Problems in baseline (upstream) skills: warned, never failed, because upstream files
    cannot be edited here and a hard failure would be unfixable."""
    return [f"{e['path']}: {p}" for e in summary["entries"].get("baseline_skills", [])
            for p in e["problems"]]


def update_target(grid, summary, target, allow_raise):
    """Rewrite totals to the current measurement. Returns (exit code, messages)."""
    # A ratchet written from a file the reader cannot measure faithfully records an
    # under-count (--check would fail on the next run anyway): refuse, naming each one.
    unmeasurable = [f"  {e['path']}: {p}" for g in ("skills", "orchestrator_roles", "agent_roles")
                    for e in summary["entries"][g] for p in e["problems"]]
    if unmeasurable:
        return 1, ["refusing to write a target while owned files cannot be measured "
                   "(fix them first; see --check):"] + unmeasurable
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
            for w in baseline_warnings(summary):
                print(f"budget: WARN {w}", file=sys.stderr)
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
