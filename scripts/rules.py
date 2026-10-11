#!/usr/bin/env python3
"""rules.py - lint and list the-grid's rule packs (rules/<pack>/).

A rule pack is a directory of short, path-scoped directive files that Claude Code
loads only when a matching file is read or edited. This script enforces the pack
format so packs stay small, scoped and free of house opinions. The format and the
reasons for each check are in rules/README.md and
openspec/changes/rule-packs/design.md.

Usage (python3 scripts/rules.py ...):
  lint [--root DIR] [--check-urls]
        Check every pack. One line per finding, `E_CODE path: message`; exit 1 if
        any finding, 0 if clean (an absent or empty rules/ is clean). Writes nothing.
        --check-urls also HEADs every https URL in each pack README's Sources
        table (needs network; the gate and the tests never pass it).
  list [--root DIR]
        Print `pack  tier  files  bytes  summary` for every pack, sorted by pack
        name in C locale (code point order), so the output is stable across runs.

Finding codes (stable): E_FRONTMATTER E_PATHS E_TITLE E_STYLE E_FILE_SIZE
E_PACK_SIZE E_OPINION E_PACK_META E_SOURCES E_ATTRIBUTION E_NAME E_URL.

Environment: GRID_DIR (repo root; default: parent of scripts/). --root wins over it.

Python 3 stdlib only, 3.8-compatible (macOS system Python), so it runs on any
machine without the agent-factory venv. No PyYAML: the frontmatter and pack.yaml
formats are tiny, so both are read by strict hand-written parsers.
"""
from __future__ import annotations

import argparse
import os
import re
import sys

# Never leave a __pycache__ behind (this file is run, not imported, but be safe).
sys.dont_write_bytecode = True

HERE = os.path.dirname(os.path.abspath(__file__))

# --- limits (design.md "Lint checks"; ceilings, not targets) -----------------------
FILE_MAX_BYTES = 4096    # one rule file: a file read pulls in every matching file
PACK_MAX_BYTES = 9216    # all rule files of one pack
BULLET_MAX_CHARS = 240   # one bullet, continuation lines included
FENCE_MAX_LINES = 10     # lines of content inside one fenced block
MAX_BRACE_GROUPS = 2     # {a,b} groups per glob

NAME_RE = re.compile(r"^[a-z0-9]+(-[a-z0-9]+)*$")        # kebab-case, lowercase
TITLE_RE = re.compile(r"^# \S")
HEADING_RE = re.compile(r"^#{2,3} \S")                    # ## and ### only
PATH_LINE_RE = re.compile(r'^  - "([^"]+)"$')             # one frontmatter glob
PACK_KEYS = ("summary", "tier", "adapted_from")           # the only pack.yaml keys
ATTRIBUTION_LINE = "Adapted from affaan-m/ECC (MIT)"
URL_RE = re.compile(r"https://[^\s|)>\]]+")


class Findings(object):
    """Collects `E_CODE path: message` findings in a stable order."""

    def __init__(self):
        self.items = []

    def add(self, code, path, msg):
        self.items.append((code, path, msg))

    def lines(self):
        return ["%s %s: %s" % (c, p, m) for c, p, m in self.items]


# --- frontmatter -------------------------------------------------------------------
def parse_frontmatter(lines):
    """Strict parse of the leading `---` block.

    Returns (globs, body_start, problem). `problem` is None when the block is
    well-formed. The only accepted shape is `paths:` followed by zero or more
    `  - "<glob>"` lines; anything else is malformed. `globs` may be empty (the
    caller reports that as E_PATHS, a different code from a malformed block).
    """
    if not lines or lines[0] != "---":
        return [], 0, "missing frontmatter (file must start with a --- line)"
    try:
        end = lines.index("---", 1)
    except ValueError:
        return [], 0, "frontmatter is not closed by a --- line"
    block = lines[1:end]
    if not block or block[0] != "paths:":
        return [], end + 1, "frontmatter must be exactly a `paths:` list (no other key)"
    globs = []
    for i, line in enumerate(block[1:], start=3):
        m = PATH_LINE_RE.match(line)
        if not m:
            return [], end + 1, 'frontmatter line %d is not `  - "<glob>"`' % i
        globs.append(m.group(1))
    return globs, end + 1, None


def check_glob(glob):
    """Return a list of problems with one paths glob (empty list = fine)."""
    problems = []
    if glob.startswith("/"):
        problems.append("absolute glob %r" % glob)
    if ".." in glob:
        problems.append("glob %r contains .." % glob)
    # Effectively always-on: the last path segment is nothing but wildcard/brace/dot
    # characters (rejects *, **, **/*, **/*.*, **/**), so it would match every file.
    last = glob.split("/")[-1]
    if not re.sub(r"[*?\[\]{},.]", "", last):
        problems.append("glob %r matches effectively every file" % glob)
    # Brace limits: no nesting, no empty alternative, at most MAX_BRACE_GROUPS groups.
    depth, groups, cur, unbalanced = 0, 0, "", False
    for ch in glob:
        if ch == "{":
            if depth:
                problems.append("glob %r has nested braces" % glob)
                break
            depth, groups, cur = 1, groups + 1, ""
        elif ch == "}":
            if not depth:
                unbalanced = True
                break
            depth = 0
            if any(a == "" for a in cur.split(",")):
                problems.append("glob %r has an empty brace alternative" % glob)
        elif depth:
            cur += ch
    if unbalanced or depth:
        problems.append("glob %r has unbalanced braces" % glob)
    if groups > MAX_BRACE_GROUPS:
        problems.append("glob %r has more than %d brace groups" % (glob, MAX_BRACE_GROUPS))
    return problems


# --- body style --------------------------------------------------------------------
def check_style(lines, start):
    """Check the body (after the title) line shapes. Yields (lineno, message).

    Allowed: blank lines, `##`/`###` headings, bullets (`- `), bullet continuation
    lines (two leading spaces), and fenced code blocks of at most FENCE_MAX_LINES
    lines. Rules are short directives: no prose paragraphs, block quotes, second
    `# ` headings or cross-reference lines.
    """
    in_fence = False
    fence_open_line = 0
    fence_len = 0
    bullet_open = False      # previous non-blank line belongs to a bullet
    bullet_start = 0
    bullet_text = []
    out = []

    def close_bullet():
        # Bullet length = its first line plus continuation lines (stripped, joined by
        # one space), counted including the leading "- ".
        if bullet_text:
            n = len(" ".join(bullet_text))
            if n > BULLET_MAX_CHARS:
                out.append((bullet_start, "bullet is %d characters (max %d)" % (n, BULLET_MAX_CHARS)))

    for no in range(start, len(lines)):
        line = lines[no]
        lineno = no + 1
        if in_fence:
            if line.startswith("```"):
                in_fence = False
                if fence_len > FENCE_MAX_LINES:
                    out.append((fence_open_line, "fenced block is %d lines (max %d)" % (fence_len, FENCE_MAX_LINES)))
            else:
                fence_len += 1
            continue
        if line.startswith("```"):
            close_bullet()
            bullet_open, bullet_text = False, []
            in_fence, fence_open_line, fence_len = True, lineno, 0
        elif line.strip() == "":
            close_bullet()
            bullet_open, bullet_text = False, []
        elif line.startswith("- "):
            close_bullet()
            bullet_open, bullet_start, bullet_text = True, lineno, [line.strip()]
        elif line.startswith("  ") and bullet_open:
            bullet_text.append(line.strip())
        elif HEADING_RE.match(line):
            close_bullet()
            bullet_open, bullet_text = False, []
        elif line.startswith("# "):
            out.append((lineno, "second `# ` heading (only one title allowed)"))
        else:
            out.append((lineno, "line is not a heading, bullet, bullet continuation or fenced block: %r" % line[:60]))
            close_bullet()
            bullet_open, bullet_text = False, []
    close_bullet()
    if in_fence:
        out.append((fence_open_line, "unclosed fenced block"))
    return out


# --- pack.yaml / README / notices readers -------------------------------------------
def read_pack_yaml(path):
    """Strict flat `key: value` reader. Returns (dict, [problems])."""
    data, problems = {}, []
    try:
        with open(path, encoding="utf-8") as fh:
            raw = fh.read().split("\n")
    except OSError:
        return data, ["pack.yaml is missing"]
    for i, line in enumerate(raw, start=1):
        text = line.strip()
        if not text or text.startswith("#"):
            continue
        # Strip a trailing comment ("  # ...") from the value.
        text = re.split(r"\s+#", text, maxsplit=1)[0]
        m = re.match(r"^([a-z_]+):\s*(.*)$", text)
        if not m:
            problems.append("line %d is not `key: value`" % i)
            continue
        key, val = m.group(1), m.group(2).strip()
        if key not in PACK_KEYS:
            problems.append("line %d: unknown key %r (allowed: %s)" % (i, key, ", ".join(PACK_KEYS)))
        elif key in data:
            problems.append("line %d: duplicate key %r" % (i, key))
        else:
            data[key] = val
    return data, problems


def sources_rows(readme_lines):
    """Map rule-file basename -> list of https URLs from the README table rows."""
    rows = {}
    for line in readme_lines:
        if not line.startswith("|"):
            continue
        cells = [c.strip().strip("`") for c in line.strip().strip("|").split("|")]
        if cells:
            rows.setdefault(cells[0], []).extend(URL_RE.findall(line))
    return rows


def notices_adapted_packs(path):
    """Pack names listed under `Adapted packs` in THIRD_PARTY_NOTICES.txt."""
    names, active = set(), False
    try:
        with open(path, encoding="utf-8") as fh:
            lines = fh.read().split("\n")
    except OSError:
        return names
    for line in lines:
        text = line.strip()
        if text == "Adapted packs":
            active = True
            continue
        if not active or not text or text.startswith("#") or set(text) == {"-"}:
            continue
        names.add(text[2:].strip() if text.startswith("- ") else text)
    return names


def load_denylist(path):
    """Compile rules/denylist.txt (one regex per line, # comments). Returns (list, [errors])."""
    pats, errs = [], []
    try:
        with open(path, encoding="utf-8") as fh:
            raw = fh.read().split("\n")
    except OSError:
        return pats, ["denylist.txt is missing"]
    for i, line in enumerate(raw, start=1):
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        try:
            pats.append((line, re.compile(line, re.IGNORECASE)))
        except re.error as exc:
            errs.append("line %d: bad regex (%s)" % (i, exc))
    return pats, errs


# --- lint --------------------------------------------------------------------------
def rules_dir(root):
    return os.path.join(root, "rules")


def list_packs(root):
    """Sorted pack directory names under rules/ (files at that level are not packs)."""
    base = rules_dir(root)
    if not os.path.isdir(base):
        return []
    return sorted(n for n in os.listdir(base) if os.path.isdir(os.path.join(base, n)))


def pack_rule_files(pack_dir):
    """Sorted *.md names in a pack, excluding README.md (never a rule)."""
    return sorted(n for n in os.listdir(pack_dir)
                  if n.endswith(".md") and n != "README.md" and os.path.isfile(os.path.join(pack_dir, n)))


def read_lines(path):
    with open(path, encoding="utf-8", errors="replace") as fh:
        return fh.read().split("\n")


def lint_rule_file(rel, path, denylist, f):
    """All per-file checks for one rule file. Returns its size in bytes."""
    size = os.path.getsize(path)
    if size > FILE_MAX_BYTES:
        f.add("E_FILE_SIZE", rel, "%d bytes (max %d)" % (size, FILE_MAX_BYTES))
    lines = read_lines(path)

    globs, body, problem = parse_frontmatter(lines)
    if problem:
        f.add("E_FRONTMATTER", rel, problem)
    elif not globs:
        f.add("E_PATHS", rel, "paths: list is empty")
    for g in globs:
        for p in check_glob(g):
            f.add("E_PATHS", rel, p)

    # Title: the first non-blank line after the frontmatter must be `# <Title>`.
    title_idx = None
    for i in range(body, len(lines)):
        if lines[i].strip():
            title_idx = i
            break
    if title_idx is None or not TITLE_RE.match(lines[title_idx]):
        f.add("E_TITLE", rel, "first line after the frontmatter must be `# <Title>`")
        style_start = body
    else:
        style_start = title_idx + 1
    for lineno, msg in check_style(lines, style_start):
        f.add("E_STYLE", rel, "line %d: %s" % (lineno, msg))

    # Denylist is searched per line (so ^ anchors work), first matching pattern only.
    for i, line in enumerate(lines, start=1):
        for pat, rx in denylist:
            if rx.search(line):
                f.add("E_OPINION", rel, "line %d matches denylist pattern %s" % (i, pat))
                break
    return size


def check_url(url):
    """HEAD one URL. Returns an error string, or None when it resolves (2xx/3xx)."""
    import urllib.error
    import urllib.request
    # Some servers reject HEAD (405/501): retry once with GET before failing.
    for method in ("HEAD", "GET"):
        req = urllib.request.Request(url, method=method, headers={"User-Agent": "the-grid-rules-lint"})
        try:
            with urllib.request.urlopen(req, timeout=20) as resp:
                return None if resp.status < 400 else "HTTP %d" % resp.status
        except urllib.error.HTTPError as exc:
            if method == "HEAD" and exc.code in (405, 501):
                continue
            return "HTTP %d" % exc.code
        except Exception as exc:  # network/DNS/TLS: report, never crash the lint
            return "%s" % exc
    return "unreachable"


def lint(root, check_urls=False):
    f = Findings()
    base = rules_dir(root)
    packs = list_packs(root)
    denylist, deny_errs = ([], [])
    if packs:
        # Fail closed: with packs present, a missing or broken denylist is a finding.
        denylist, deny_errs = load_denylist(os.path.join(base, "denylist.txt"))
        for e in deny_errs:
            f.add("E_OPINION", "rules/denylist.txt", e)
    adapted = notices_adapted_packs(os.path.join(base, "THIRD_PARTY_NOTICES.txt"))

    for pack in packs:
        pdir = os.path.join(base, pack)
        prel = "rules/" + pack
        if not NAME_RE.match(pack):
            f.add("E_NAME", prel, "pack name must be lowercase kebab-case")

        # Every entry must be pack.yaml, README.md or a lowercase kebab-case .md rule.
        for name in sorted(os.listdir(pdir)):
            full = os.path.join(pdir, name)
            if os.path.isdir(full):
                f.add("E_NAME", prel + "/" + name, "unexpected directory (rule files are flat)")
            elif name in ("pack.yaml", "README.md"):
                continue
            elif not name.endswith(".md"):
                f.add("E_NAME", prel + "/" + name, "unexpected file (a pack holds pack.yaml, README.md and .md rule files)")
            elif not NAME_RE.match(name[:-3]):
                f.add("E_NAME", prel + "/" + name, "rule file name must be lowercase kebab-case")

        rule_files = pack_rule_files(pdir)
        total = 0
        for name in rule_files:
            total += lint_rule_file("%s/%s" % (prel, name), os.path.join(pdir, name), denylist, f)
        if total > PACK_MAX_BYTES:
            f.add("E_PACK_SIZE", prel, "%d bytes across %d rule files (max %d)" % (total, len(rule_files), PACK_MAX_BYTES))

        # pack.yaml
        meta, problems = read_pack_yaml(os.path.join(pdir, "pack.yaml"))
        for p in problems:
            f.add("E_PACK_META", prel + "/pack.yaml", p)
        tier = meta.get("tier")
        yaml_absent = (problems == ["pack.yaml is missing"])   # already reported above
        if not yaml_absent and not meta.get("summary"):
            f.add("E_PACK_META", prel + "/pack.yaml", "summary is missing or empty")
        if yaml_absent:
            pass
        elif tier not in ("1", "2"):
            f.add("E_PACK_META", prel + "/pack.yaml", "tier must be 1 or 2, got %r" % tier)
        elif tier == "2" and not meta.get("adapted_from"):
            f.add("E_PACK_META", prel + "/pack.yaml", "tier 2 requires adapted_from")
        elif tier == "1" and meta.get("adapted_from"):
            f.add("E_PACK_META", prel + "/pack.yaml", "adapted_from is only allowed on tier 2")

        # README: Sources table (every rule file needs a row with an https URL).
        readme = os.path.join(pdir, "README.md")
        if not os.path.isfile(readme):
            f.add("E_SOURCES", prel + "/README.md", "README.md is missing")
            rlines = []
        else:
            rlines = read_lines(readme)
            rows = sources_rows(rlines)
            for name in rule_files:
                if not rows.get(name):
                    f.add("E_SOURCES", prel + "/README.md", "no Sources row with an https:// URL for %s" % name)
            if check_urls:
                for name in sorted(rows):
                    for url in sorted(set(rows[name])):
                        err = check_url(url)
                        if err:
                            f.add("E_URL", prel + "/README.md", "%s -> %s" % (url, err))

        # Attribution for tier 2 (adapted) packs.
        if tier == "2":
            if rlines and not any(ATTRIBUTION_LINE in ln for ln in rlines):
                f.add("E_ATTRIBUTION", prel + "/README.md", "missing the line `%s`" % ATTRIBUTION_LINE)
            if pack not in adapted:
                f.add("E_ATTRIBUTION", "rules/THIRD_PARTY_NOTICES.txt",
                      "pack %s is not listed under `Adapted packs`" % pack)
    return f


# --- list --------------------------------------------------------------------------
def list_rows(root):
    base = rules_dir(root)
    rows = []
    for pack in list_packs(root):
        pdir = os.path.join(base, pack)
        files = pack_rule_files(pdir)
        size = sum(os.path.getsize(os.path.join(pdir, n)) for n in files)
        meta, _ = read_pack_yaml(os.path.join(pdir, "pack.yaml"))
        rows.append((pack, meta.get("tier", "?"), str(len(files)), str(size), meta.get("summary", "")))
    return rows


def cmd_list(root):
    header = ("pack", "tier", "files", "bytes", "summary")
    rows = list_rows(root)
    # Pad every column but the last to its widest cell; columns separated by two spaces.
    widths = [max(len(r[i]) for r in [header] + rows) for i in range(4)]
    for r in [header] + rows:
        print("  ".join(r[i].ljust(widths[i]) for i in range(4)) + "  " + r[4])
    return 0


# --- main --------------------------------------------------------------------------
def main(argv=None):
    ap = argparse.ArgumentParser(description="Lint and list the-grid rule packs.")
    sub = ap.add_subparsers(dest="cmd")
    sub.required = True
    for name in ("lint", "list"):
        sp = sub.add_parser(name)
        sp.add_argument("--root", help="repo root holding rules/ (default: $GRID_DIR, else the parent of scripts/)")
        if name == "lint":
            sp.add_argument("--check-urls", action="store_true",
                            help="HEAD every Sources URL (network; never used by the gate or tests)")
    args = ap.parse_args(argv)
    root = os.path.realpath(args.root or os.environ.get("GRID_DIR") or os.path.join(HERE, ".."))

    if args.cmd == "list":
        return cmd_list(root)
    f = lint(root, check_urls=args.check_urls)
    for line in f.lines():
        print(line)
    return 1 if f.items else 0


if __name__ == "__main__":
    sys.exit(main())
