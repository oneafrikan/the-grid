#!/usr/bin/env python3
"""stamp-counts.py - keep the numbers in README / landing page generated, never typed.

Usage:
  python3 scripts/stamp-counts.py           # rewrite every <!--count:NAME-->VALUE<!--/count-->
  python3 scripts/stamp-counts.py --check   # write nothing; exit 1 naming each drifted file

Files scanned (relative to GRID_DIR, default: the repo root, the parent of scripts/):
  README.md, README.*.md, index.html

Values come from two places, so there is no data file to drift:
  - the committed SKILLS.md headline line (catalog.sh writes it, catalog.sh --check guards it)
  - the number of "- role:" lines across agent-factory/examples/*.yaml

NAMEs: indexed, wired, root_owned, upstream_wired, library, roles.

Exit codes:
  0  stamped / already current / no file holds a marker (nothing to do)
  1  --check only: at least one file is stale
  2  an unknown NAME, or a missing/unparsable SKILLS.md headline (or no team yaml) while a marker exists

Stdlib only and valid on Python 3.8 (macOS system python). Every file is opened with
encoding="utf-8": the headline holds an em dash and callers pin LC_ALL=C.
"""
import glob
import os
import re
import sys

# Marker: valid inline in Markdown and in HTML (an HTML comment renders as nothing in both).
# Non-greedy, single line: a stray unterminated opener cannot swallow the rest of the file.
MARKER = re.compile(r"<!--count:([^>]*?)-->(.*?)<!--/count-->")

# SKILLS.md headline, as written by catalog.sh's printf, e.g.
#   **232 skills indexed** — 132 wired live (14 root-owned + 118 from allowlisted repos), 100 in library
# Groups in order: indexed, wired, root_owned, upstream_wired, library. The em dash is written as
# — so this source stays ASCII. Any change to the catalog.sh wording must change this too;
# tests/test_stamp_counts.bats runs the real SKILLS.md through it to catch that.
HEADLINE = re.compile(
    r"^\*\*(\d+) skills indexed\*\* — (\d+) wired live "
    r"\((\d+) root-owned \+ (\d+) from allowlisted repos\), (\d+) in library",
    re.MULTILINE,
)
HEADLINE_KEYS = ("indexed", "wired", "root_owned", "upstream_wired", "library")

# A team role line in a compose config, e.g. "  - role: researcher" (same as grep '^[[:space:]]*- role:').
ROLE_LINE = re.compile(r"^[ \t]*- role:", re.MULTILINE)

ALL_NAMES = HEADLINE_KEYS + ("roles",)


def read(path):
    # newline="" keeps CRLF/LF exactly as found, so an untouched file stays byte-identical.
    with open(path, encoding="utf-8", newline="") as fh:
        return fh.read()


def target_files(grid_dir):
    """README.md, README.*.md and index.html that exist under grid_dir, sorted."""
    names = ["README.md"] + sorted(
        os.path.basename(p) for p in glob.glob(os.path.join(grid_dir, "README.*.md"))
    ) + ["index.html"]
    return [os.path.join(grid_dir, n) for n in names if os.path.isfile(os.path.join(grid_dir, n))]


def load_values(grid_dir):
    """Return {NAME: int}; raise ValueError with a reason when a source is missing/unparsable."""
    skills = os.path.join(grid_dir, "SKILLS.md")
    if not os.path.isfile(skills):
        raise ValueError("SKILLS.md not found in %s" % grid_dir)
    match = HEADLINE.search(read(skills))
    if not match:
        raise ValueError("SKILLS.md headline not recognised (expected '**N skills indexed** - ...')")
    values = dict(zip(HEADLINE_KEYS, (int(g) for g in match.groups())))

    configs = sorted(glob.glob(os.path.join(grid_dir, "agent-factory", "examples", "*.yaml")))
    if not configs:
        raise ValueError("no agent-factory/examples/*.yaml to count roles from")
    values["roles"] = sum(len(ROLE_LINE.findall(read(p))) for p in configs)
    return values


def main(argv):
    check = False
    for arg in argv:
        if arg == "--check":
            check = True
        elif arg in ("-h", "--help"):
            print(__doc__)
            return 0
        else:
            print("stamp-counts: unknown option: %s" % arg, file=sys.stderr)
            return 2

    grid_dir = os.environ.get("GRID_DIR") or os.path.dirname(
        os.path.dirname(os.path.abspath(__file__))
    )

    # Read every target once; remember which hold markers.
    texts = {}
    for path in target_files(grid_dir):
        text = read(path)
        if MARKER.search(text):
            texts[path] = text
    if not texts:
        return 0  # no markers anywhere: nothing to derive, nothing to fail on

    # An unknown NAME is a typo in a doc; fail before touching any file.
    bad = False
    for path, text in texts.items():
        for name, _ in MARKER.findall(text):
            if name not in ALL_NAMES:
                print("stamp-counts: %s: unknown count name '%s'" % (os.path.relpath(path, grid_dir), name),
                      file=sys.stderr)
                bad = True
    if bad:
        return 2

    try:
        values = load_values(grid_dir)
    except ValueError as err:
        print("stamp-counts: %s" % err, file=sys.stderr)
        return 2

    stale = []
    for path, text in texts.items():
        new = MARKER.sub(lambda m: "<!--count:%s-->%d<!--/count-->" % (m.group(1), values[m.group(1)]), text)
        if new == text:
            continue
        rel = os.path.relpath(path, grid_dir)
        stale.append(rel)
        if not check:
            with open(path, "w", encoding="utf-8", newline="") as fh:
                fh.write(new)
            print("stamp-counts: updated %s" % rel)

    if check and stale:
        for rel in stale:
            print("stamp-counts: %s is stale - run: python3 scripts/stamp-counts.py" % rel, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
