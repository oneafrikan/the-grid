#!/usr/bin/env python3
"""rules.py - lint, list and emit the-grid's rule packs (rules/<pack>/).

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

  emit --harness cursor|agents-md|gemini --packs a,b [--out PATH] [--check] [--root DIR]
        Render packs for another harness (the interface other changes call; see
        design.md "Emitters"). `cursor` writes one `<out>/grid-<pack>-<topic>.mdc`
        per rule (default --out .cursor/rules). `agents-md` and `gemini` write ONE
        managed block between BEGIN/END marker comments in a single file (default
        --out AGENTS.md / GEMINI.md; capped at BLOCK_CAP bytes; text outside the
        markers is never touched; an empty --packs removes the block). Prints
        `wrote <path>` / `removed <path>` per change. --check writes nothing and
        exits 1 on any difference (it prints `would write` / `would remove`, not
        `wrote` / `removed`). Exit 0 done/no drift, 1 drift (--check), 2 usage,
        refusal or I/O error (nothing written, except: emit lints every selected
        pack first; a pack with rule-file findings is excluded and named on stderr,
        the clean packs are still delivered, and the exit is 2). Exit 3: the block
        would be over BLOCK_CAP; nothing is written and any existing block is left
        as it was, so a caller can tell a skip from a refusal without parsing text. Every write is atomic (temp file in
        the same directory + os.replace), keeps the file mode, never goes through a
        symlink, and breaks hard links (the replace gives the file a new inode).

Finding codes (stable): E_FRONTMATTER E_PATHS E_TITLE E_STYLE E_FILE_SIZE
E_PACK_SIZE E_OPINION E_PACK_META E_SOURCES E_ATTRIBUTION E_NAME E_URL E_MARKER.

Environment: GRID_DIR (repo root; default: parent of scripts/). --root wins over it.

Python 3 stdlib only, 3.8-compatible (macOS system Python), so it runs on any
machine without the agent-factory venv. No PyYAML: the frontmatter and pack.yaml
formats are tiny, so both are read by strict hand-written parsers.
"""
from __future__ import annotations

import argparse
import itertools
import json
import os
import re
import stat
import sys
import tempfile

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
# Marker text that must never appear in a rule file: the managed-block BEGIN/END lines
# (line-start test, so prose such as "the-grid rules" is fine) and the .mdc marker token.
MARKER_PREFIXES = ("<!-- BEGIN the-grid rules", "<!-- END the-grid rules")
MARKER_TOKEN = "the-grid:rules"
# Lint findings that stop a pack from being delivered by emit (rule-file checks only:
# pack metadata, Sources and notices findings do not change what a rule file says).
EMIT_BLOCKING_CODES = ("E_FRONTMATTER", "E_PATHS", "E_TITLE", "E_STYLE", "E_FILE_SIZE",
                       "E_OPINION", "E_MARKER")
ATTRIBUTION_LINE = "Adapted from affaan-m/ECC (MIT)"
URL_RE = re.compile(r"https://[^\s|)>\]]+")


def is_marker_line(line):
    """True for a line that looks like a managed-block marker or carries the .mdc token."""
    return line.lstrip().startswith(MARKER_PREFIXES) or MARKER_TOKEN in line


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

    # Marker text anywhere (fenced or not) would corrupt the managed block or the .mdc
    # generated-file detection once delivered, so it is refused at the source.
    for i, line in enumerate(lines, start=1):
        if is_marker_line(line):
            f.add("E_MARKER", rel, "line %d carries the-grid marker text" % i)

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


# --- emit --------------------------------------------------------------------------
# Marker carried by every generated Cursor file. Its presence is the ONLY thing that
# lets emit delete or overwrite a file: unmarked (hand-written) files are never touched.
MDC_MARKER_PREFIX = "<!-- the-grid:rules generated from "
MDC_MARKER_FMT = MDC_MARKER_PREFIX + "%s; do not edit -->"
MDC_MARKER_RE = re.compile("^" + re.escape(MDC_MARKER_PREFIX) + r"rules/[a-z0-9-]+/[a-z0-9-]+\.md; do not edit -->$")
CURSOR_DEFAULT_OUT = os.path.join(".cursor", "rules")
HARNESSES = ("cursor", "agents-md", "gemini")


class Refusal(Exception):
    """A usage error or refusal: reported on stderr, exit 2, nothing written."""


class OverCap(Refusal):
    """The managed block would exceed BLOCK_CAP: reported on stderr, exit 3, nothing written."""


def expand_braces(glob):
    """Expand `{a,b}` groups left to right as a cartesian product, in source order.

    Lint guarantees no nesting, no empty alternative and at most MAX_BRACE_GROUPS
    groups, so a plain split is a total definition here:
    `*.{test,spec}.{tsx,jsx}` -> test.tsx, test.jsx, spec.tsx, spec.jsx.
    """
    parts = re.split(r"(\{[^{}]*\})", glob)
    choices = []
    for part in parts:
        if part.startswith("{") and part.endswith("}"):
            choices.append(part[1:-1].split(","))
        else:
            choices.append([part])
    return ["".join(combo) for combo in itertools.product(*choices)]


def yaml_scalar(text):
    """Render a one-line frontmatter value: bare when plainly safe, else JSON-quoted.

    A title such as `Style: naming` or `Use # sparingly` would break an unquoted
    YAML scalar, so quote (JSON strings are valid YAML) whenever it could.
    """
    if re.search(r"(^[^A-Za-z0-9])|(: )|( #)|(:$)", text):
        return json.dumps(text)
    return text


def render_mdc(rel, path):
    """Return the exact .mdc text for one rule file (rel = rules/<pack>/<topic>.md)."""
    lines = read_lines(path)
    globs, body, problem = parse_frontmatter(lines)
    if problem or not globs:
        raise Refusal("%s: %s (run `rules.py lint`)" % (rel, problem or "paths: list is empty"))
    # Body = everything after the frontmatter, leading blank lines dropped; the first
    # remaining line is the `# Title`, which doubles as the Cursor description.
    rest = lines[body:]
    while rest and not rest[0].strip():
        rest.pop(0)
    if not rest or not TITLE_RE.match(rest[0]):
        raise Refusal("%s: first line after the frontmatter must be `# <Title>` (run `rules.py lint`)" % rel)
    title = rest[0][2:].strip()
    out_globs = []
    for g in globs:
        for e in expand_braces(g):
            if e not in out_globs:        # duplicates dropped, first occurrence wins
                out_globs.append(e)
    text = "\n".join(rest)
    if not text.endswith("\n"):
        text += "\n"
    return "---\ndescription: %s\nglobs: %s\nalwaysApply: false\n---\n%s\n%s" % (
        yaml_scalar(title), json.dumps(out_globs), MDC_MARKER_FMT % rel, text)


def is_generated(path):
    """True when `path` is a regular file (never a symlink) that rules.py generated.

    Generated means the marker sits on the line directly after the frontmatter's closing
    `---`, in the form `rules/<pack>/<name>.md`. A hand-written file that merely quotes
    the marker somewhere else is not ours, so it is never deleted or overwritten. A
    symlink is "not generated" even when its target holds the marker: otherwise a planted
    link would make emit overwrite or delete whatever it points at.
    """
    if os.path.islink(path) or not os.path.isfile(path):
        return False
    lines = read_lines(path)
    if not lines or lines[0] != "---" or "---" not in lines[1:]:
        return False
    end = lines.index("---", 1)
    return end + 1 < len(lines) and MDC_MARKER_RE.match(lines[end + 1]) is not None


def atomic_write(path, data):
    """Write `data` to `path` via a temp file in the same directory, then os.replace.

    The old file is never truncated, so a failed write (disk full, size limit, kill)
    leaves it byte-identical. The mode (and, best effort, the owner) of an existing
    file is kept. os.replace swaps the inode, so a second hard link to the file keeps
    the OLD content (documented in rules/README.md); a symlink is never followed
    because callers refuse one first. A read-only existing file is refused: the
    rename would otherwise succeed in a writable directory and override the operator.
    """
    d = os.path.dirname(path) or "."
    os.makedirs(d, exist_ok=True)
    try:
        st = os.stat(path)
    except FileNotFoundError:
        st = None
    if st is not None and not os.access(path, os.W_OK):
        raise OSError("%s is not writable" % path)
    fd, tmp = tempfile.mkstemp(dir=d, prefix="." + os.path.basename(path) + ".", suffix=".tmp")
    try:
        with os.fdopen(fd, "wb") as fh:
            fh.write(data)
            fh.flush()
            os.fsync(fh.fileno())
        if st is not None:
            os.chmod(tmp, stat.S_IMODE(st.st_mode))
            try:
                os.chown(tmp, st.st_uid, st.st_gid)
            except (OSError, AttributeError):
                pass                        # best effort: only root can give files away
        else:
            um = os.umask(0)
            os.umask(um)
            os.chmod(tmp, 0o666 & ~um)      # mkstemp makes 0600; a new file gets the normal default
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def plan_cursor(root, packs, out):
    """Work out what an emit would do without touching disk.

    Returns (writes, removals): `writes` is a sorted list of (path, bytes) that
    differ from disk (new or changed); `removals` is a sorted list of stale
    marker-carrying grid-*.mdc paths. Raises Refusal on any problem, before any write.
    """
    if os.path.exists(out) and not os.path.isdir(out):
        raise Refusal("--out %s exists and is not a directory (cursor writes a directory)" % out)

    # Desired set: grid-<pack>-<topic>.mdc for every rule file of every selected pack.
    wanted = {}
    for pack in packs:
        if not NAME_RE.match(pack) or not os.path.isdir(os.path.join(rules_dir(root), pack)):
            raise Refusal("unknown pack %r" % pack)
        pdir = os.path.join(rules_dir(root), pack)
        for name in pack_rule_files(pdir):
            target = os.path.join(out, "grid-%s-%s.mdc" % (pack, name[:-3]))
            if target in wanted:
                raise Refusal("packs collide on output file %s" % target)
            rel = "rules/%s/%s" % (pack, name)
            wanted[target] = render_mdc(rel, os.path.join(pdir, name)).encode("utf-8")

    writes = []
    for target in sorted(wanted):
        if os.path.lexists(target):
            # Never overwrite a file we did not generate; refuse rather than clobber.
            if not is_generated(target):
                raise Refusal("%s exists and is not generated by rules.py (no marker); move it or choose another --out" % target)
            with open(target, "rb") as fh:
                if fh.read() == wanted[target]:
                    continue                # already up to date
        writes.append((target, wanted[target]))

    # Stale: marker-carrying grid-*.mdc in --out that are not in the desired set.
    removals = []
    if os.path.isdir(out):
        for name in sorted(os.listdir(out)):
            full = os.path.join(out, name)
            if name.startswith("grid-") and name.endswith(".mdc") and full not in wanted and is_generated(full):
                removals.append(full)
    return writes, removals


# --- agents-md / gemini: one managed block in a single file -------------------------
# Neither harness has path scoping, so the block is always loaded: it is capped (a fixed
# constant, not a flag) and an over-cap selection is refused rather than truncated,
# because silent truncation would drop rules without notice.
BLOCK_CAP = 12288
BLOCK_BEGIN = "<!-- BEGIN the-grid rules (generated by scripts/rules.py; edits inside are overwritten) -->"
BLOCK_END = "<!-- END the-grid rules -->"
BLOCK_INTRO = ("## Coding rules (the-grid)\n\n"
               "Apply each rule only when working on files matching its globs.\n")
# Marker lines are matched as COMPLETE lines (optional trailing CR), never by prefix: a user
# note that merely starts like a marker is user text, not ours. Every BEGIN/END spelling
# ever shipped is listed so a future rewording keeps migrating old blocks (the commit
# history shows only the current spelling has shipped). Bytes, because the file is handled
# as raw bytes.
BLOCK_BEGIN_HISTORY = (BLOCK_BEGIN,)
BLOCK_END_HISTORY = (BLOCK_END,)


def _marker_re(spellings):
    alt = b"|".join(re.escape(t.encode("utf-8")) for t in spellings)
    return re.compile(b"^(?:" + alt + b")\r?$", re.M)


BEGIN_RE = _marker_re(BLOCK_BEGIN_HISTORY)
BARE_BEGIN_RE = re.compile(br"^<!-- BEGIN the-grid rules[^\n]*$", re.M)
END_RE = _marker_re(BLOCK_END_HISTORY)
BLOCK_DEFAULT_OUT = {"agents-md": "AGENTS.md", "gemini": "GEMINI.md"}


def render_section(rel, path):
    """Return one rule as a block section: `### <pack> / <topic> (applies to: ...)` + body."""
    lines = read_lines(path)
    globs, body, problem = parse_frontmatter(lines)
    if problem or not globs:
        raise Refusal("%s: %s (run `rules.py lint`)" % (rel, problem or "paths: list is empty"))
    rest = lines[body:]
    while rest and not rest[0].strip():
        rest.pop(0)
    if not rest or not TITLE_RE.match(rest[0]):
        raise Refusal("%s: first line after the frontmatter must be `# <Title>` (run `rules.py lint`)" % rel)
    for ln in rest:
        # Backstop for callers that skip lint: marker text in a body would wedge removal.
        if is_marker_line(ln):
            raise Refusal("%s: a line carries the-grid marker text (E_MARKER)" % rel)
    rest = rest[1:]                       # the H1 goes: the ### header replaces it
    while rest and not rest[0].strip():
        rest.pop(0)
    while rest and not rest[-1].strip():
        rest.pop()
    pack, topic = rel.split("/")[1], os.path.basename(rel)[:-3]
    header = "### %s / %s (applies to: %s)" % (pack, topic, ", ".join("`%s`" % g for g in globs))
    return header + "\n\n" + "\n".join(rest) + "\n"


def render_block(root, packs):
    """Return the whole managed block as bytes, or None for the empty selection."""
    sections = []
    for pack in packs:
        if not NAME_RE.match(pack) or not os.path.isdir(os.path.join(rules_dir(root), pack)):
            raise Refusal("unknown pack %r" % pack)
        pdir = os.path.join(rules_dir(root), pack)
        for name in pack_rule_files(pdir):
            sections.append(render_section("rules/%s/%s" % (pack, name), os.path.join(pdir, name)))
    if not sections:
        return None
    text = "%s\n%s\n%s%s\n" % (BLOCK_BEGIN, BLOCK_INTRO, "\n".join(sections), BLOCK_END)
    data = text.encode("utf-8")
    if len(data) > BLOCK_CAP:
        raise OverCap("block is %d bytes, over the %d-byte cap; nothing written, select fewer packs"
                      % (len(data), BLOCK_CAP))
    return data


def detect_eol(data):
    """CRLF only when every newline in `data` is a CRLF; otherwise LF (also for no newline)."""
    n = data.count(b"\n")
    return b"\r\n" if n and data.count(b"\r\n") == n else b"\n"


def plan_block(root, packs, out):
    """Work out the new content of the --out file without touching disk.

    Returns (old, new): bytes, or None for "file absent" (new is never None).
    Raises Refusal on any problem, before any write.
    """
    if os.path.islink(out):
        raise Refusal("--out %s is a symlink; refusing to write through it" % out)
    if os.path.lexists(out) and not os.path.isfile(out):
        raise Refusal("--out %s exists and is not a regular file (agents-md/gemini write a file)" % out)
    old = None
    if os.path.isfile(out):
        with open(out, "rb") as fh:
            old = fh.read()
    # Marker check comes first so a damaged file is refused even for the empty selection.
    begins = list(BEGIN_RE.finditer(old or b""))
    ends = list(END_RE.finditer(old or b""))
    if begins:
        # Only an END after our BEGIN can close our block; an exact END line before it is
        # user text (e.g. a fenced quote of the markers), so it does not count.
        ends = [e for e in ends if e.start() > begins[0].start()]
    elif ends and BARE_BEGIN_RE.search(old):
        # No exact BEGIN, but a bare BEGIN-like line sits in the file: a user fence quoting
        # the markers, so the exact END beside it is quoted text as well, not a damaged block.
        ends = []
    if len(begins) != len(ends) or len(begins) > 1:
        raise Refusal("%s: expected exactly one BEGIN and one END marker, BEGIN first "
                      "(found %d BEGIN, %d END); fix the markers by hand" % (out, len(begins), len(ends)))
    block = render_block(root, packs)
    # The block takes the file's line ending, so a CRLF file stays uniformly CRLF and
    # --check compares like with like after an editor re-save.
    eol = detect_eol(old or b"")
    if block is not None and eol == b"\r\n":
        block = block.replace(b"\n", b"\r\n")

    if begins:
        # Replace (or drop) the region from the BEGIN line through the END line's newline.
        # Everything before and after is carried over as raw bytes, unchanged.
        start, end = begins[0].start(), ends[0].end()
        if old[end:end + 1] == b"\n":
            end += 1
        before, after = old[:start], old[end:]
        if block is None and after == b"" and before.endswith(b"\n"):
            # Removal at EOF: take back the one newline the append added as a separator,
            # so emit then emit '' round-trips the operator's bytes.
            before = before[:-len(eol)] if before.endswith(eol) else before[:-1]
        new = before + (block or b"") + after
    elif block is None:
        return old, old                    # nothing to remove, nothing to add
    else:
        # No block yet: append, separated from existing text by one blank line: one extra
        # newline after a newline-terminated text, two after text with no final newline,
        # none for an empty file. (A file with no final newline thus gains one on removal.)
        before = old or b""
        sep = b"" if not before else (eol if before.endswith(b"\n") else eol * 2)
        new = before + sep + block
    # Removing the block from a file that held nothing else leaves a 0-byte file, never a
    # deletion: an empty file is the operator's opt-in to receive rules (the grid never
    # creates the instruction file), and deleting it would silently withdraw that opt-in.
    return old, new


def apply_block(root, packs, out, check):
    """Emit the managed block; returns the exit code (0 done/no drift, 1 drift under --check)."""
    old, new = plan_block(root, packs, out)
    if old == new:
        return 0
    if not check:
        atomic_write(out, new)
    print("%s %s" % ("would write" if check else "wrote", out))
    return 1 if check else 0


def validate_packs(root, packs):
    """Re-lint the rule files of each selected pack before delivery.

    Returns (good, bad): `good` keeps the packs to deliver (an unknown pack name stays in
    it so the normal "unknown pack" refusal fires); `bad` maps a failing pack to its
    finding lines. Only EMIT_BLOCKING_CODES block: pack metadata, Sources and notices
    findings say nothing about the text that gets loaded as instructions.
    """
    base = rules_dir(root)
    deny_path = os.path.join(base, "denylist.txt")
    denylist = load_denylist(deny_path)[0] if os.path.isfile(deny_path) else []
    good, bad = [], {}
    for pack in packs:
        pdir = os.path.join(base, pack)
        if not NAME_RE.match(pack) or not os.path.isdir(pdir):
            good.append(pack)
            continue
        f = Findings()
        for name in pack_rule_files(pdir):
            lint_rule_file("rules/%s/%s" % (pack, name), os.path.join(pdir, name), denylist, f)
        found = ["%s %s: %s" % (c, pth, m) for c, pth, m in f.items if c in EMIT_BLOCKING_CODES]
        if found:
            bad[pack] = found
        else:
            good.append(pack)
    return good, bad


def cmd_emit(root, harness, packs_arg, out, check):
    """Run `emit`. Returns the process exit code (0 done, 1 drift, 2 refusal)."""
    # Sorted, de-duplicated, empty entries dropped: `""` is the empty selection.
    packs = sorted(set(p.strip() for p in packs_arg.split(",") if p.strip()))
    # Re-validate what is about to be rendered: emit must not trust that lint ran. A failing
    # pack is dropped and named; the clean ones still go out, but the exit is 2 so wire
    # shows red. If EVERY selected pack fails nothing is written (an empty selection would
    # otherwise strip the rules that are already delivered).
    try:
        packs, bad = validate_packs(root, packs)
    except OSError as exc:
        sys.stderr.write("rules.py emit: %s\n" % exc)
        return 2
    for pack in sorted(bad):
        for line in bad[pack]:
            sys.stderr.write("rules.py emit: pack %s excluded: %s\n" % (pack, line))
    if bad and not packs:
        return 2
    rc = _emit(root, harness, packs, out, check)
    return 2 if bad else rc


def _emit(root, harness, packs, out, check):
    """Deliver the already-validated `packs`; the exit code is cmd_emit's contract."""
    try:
        if harness in BLOCK_DEFAULT_OUT:
            return apply_block(root, packs, out or BLOCK_DEFAULT_OUT[harness], check)
        out = out or CURSOR_DEFAULT_OUT
        writes, removals = plan_cursor(root, packs, out)
    except Refusal as exc:
        sys.stderr.write("rules.py emit: %s\n" % exc)
        return 3 if isinstance(exc, OverCap) else 2
    except OSError as exc:
        # A failed read or write is a refusal with one line, never a traceback (a direct
        # caller must be able to tell it from drift, which is exit 1 under --check).
        sys.stderr.write("rules.py emit: %s\n" % exc)
        return 2

    # Validation is complete; from here on we either report (--check) or apply.
    try:
        for path, data in writes:
            if not check:
                atomic_write(path, data)
            print("%s %s" % ("would write" if check else "wrote", path))
        for path in removals:
            if not check:
                os.remove(path)
            print("%s %s" % ("would remove" if check else "removed", path))
    except OSError as exc:
        sys.stderr.write("rules.py emit: %s\n" % exc)
        return 2
    return 1 if (check and (writes or removals)) else 0


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
    sp = sub.add_parser("emit", help="render packs for another harness")
    sp.add_argument("--root", help="repo root holding rules/ (default: $GRID_DIR, else the parent of scripts/)")
    sp.add_argument("--harness", required=True, choices=HARNESSES)
    sp.add_argument("--packs", required=True, help='comma list of packs; "" = empty selection (removes previous output)')
    sp.add_argument("--out", help="output: a dir for cursor (default .cursor/rules), a file for agents-md / gemini (default AGENTS.md / GEMINI.md)")
    sp.add_argument("--check", action="store_true", help="write nothing; exit 1 if a run would change anything")
    args = ap.parse_args(argv)
    root = os.path.realpath(args.root or os.environ.get("GRID_DIR") or os.path.join(HERE, ".."))

    if args.cmd == "list":
        return cmd_list(root)
    if args.cmd == "emit":
        return cmd_emit(root, args.harness, args.packs, args.out, args.check)
    f = lint(root, check_urls=args.check_urls)
    for line in f.lines():
        print(line)
    return 1 if f.items else 0


if __name__ == "__main__":
    sys.exit(main())
