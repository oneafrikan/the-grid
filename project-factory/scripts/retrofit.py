#!/usr/bin/env python3
"""retrofit.py - move the text of an existing project doc into a standard doc set
WITHOUT LOSING ANY OF IT.

Design: a person (or a model) DECIDES where each block of a source file goes by writing
a plan; this script MOVES the text verbatim. Nobody retypes source content.

Subcommands (run from the repo root, or pass --repo DIR):
  survey <repo>                          read-only: candidate sources and which standard docs exist
  blocks <file> [--rebuild]              numbered blocks B###-<hash4>; --rebuild prints the file
                                         rebuilt from its blocks (round-trip proof)
  apply <plan> [--yes] [--show-text]     dry run by default; --yes appends blocks verbatim
  check <plan> [--report]                coverage check, no judgement; exit 1 on any loss
  keep <plan> [--source S]               print the blocks marked keep, verbatim
  finalize <plan> --replace-with F [--source S] [--yes] [--allow-dirty]
                                         archive the original, put the slim doc in its place

Plan file (strict, one section per source; `blocks` prints the exact header line):
    ## source: CLAUDE.md sha256:<64 hex of the whole file>
    B001-3fa9 -> GUARDRAILS.md#Hard constraints   append at the end of that heading's section
    B004-91c2..B009-00ab -> CONVENTIONS.md        a range; no anchor = under "## Moved from CLAUDE.md"
    B010-ffff -> keep                             stays in the source
    B011-1234 -> unsorted                         goes to UNSORTED.md
Every block of the source must appear exactly once. Lines starting with # are comments.
The sha256 pins the whole source: any edit since `blocks` (even in the middle of a range) is
stale. After `finalize` the same plan still works: the source text is then read from the
archive whose sha256 matches.

Matching is block level: a moved block counts as present only when the destination, parsed
into blocks, holds an equal block (text inside a fence or comment never counts), and one
destination block satisfies at most one source block.

Exit codes: 0 ok; 1 check/coverage failure (check, or finalize that would lose text);
2 usage error, plan error, or a refusal (nothing was written).

Python 3.8+, stdlib only. No network. Never writes outside the repo directory.
Environment: RETROFIT_DATE=YYYY-MM-DD overrides today's date (tests).
"""
import argparse
import collections
import datetime
import hashlib
import os
import re
import subprocess
import sys
import tempfile

# The standard doc set (names at the repo root). MAP.md is generated, so never a destination.
STANDARD_DOCS = [
    "CLAUDE.md", "PURPOSE.md", "RULES.md", "GUARDRAILS.md", "CONVENTIONS.md",
    "DECISIONS.md", "DOCS.md", "CHANGELOG.md", "DESIGN.md", "AGENTS.md", "LOGS.md",
    "HUMANS.md", "CONTEXT.md", "CALCULATIONS.md", "ASSUMPTIONS.md",
]
UNSORTED = "UNSORTED.md"
UNSORTED_HEADER = (
    "# UNSORTED.md: Blocks Awaiting a Home\n\n"
    "Text the retrofit could not place with confidence, moved here verbatim so nothing is lost.\n"
    "Move each block to the doc where it belongs, then delete it here.\n"
)


class Fatal(Exception):
    """Usage error or refusal: printed, exit 2, nothing written."""


# ---------------------------------------------------------------------------
# Block parser. A file is: lead (blank lines) + for each block (text + gap), where
# gap is the blank lines that follow the block. Joining them rebuilds the file byte for byte.
# ---------------------------------------------------------------------------

class Block:
    def __init__(self, idx, kind, first, last, text, gap, off, closed=True):
        self.idx = idx            # 1-based
        self.kind = kind          # frontmatter heading para item fence table comment quote hr
        self.first = first        # 1-based first line
        self.last = last          # 1-based last line
        self.text = text          # exact source text of the block
        self.gap = gap            # exact blank lines after it
        self.off = off            # char offset of text in the file
        self.level = 0            # heading level
        self.htext = ""           # heading text
        self.closed = closed      # False for a fence or comment that runs to the end of the file
        self.norm = norm(text)    # comparison form (see norm)
        self.hash = hashlib.sha1(self.norm.encode("utf-8", "surrogateescape")).hexdigest()[:4]

    @property
    def id(self):
        return "B%03d-%s" % (self.idx, self.hash)

    @property
    def preview(self):
        for ln in self.text.split("\n"):
            if ln.strip():
                s = ln.strip()
                return s if len(s) <= 60 else s[:57] + "..."
        return ""


def norm(text):
    """Comparison form: CRLF -> LF, trailing blanks stripped per line, trailing newlines gone."""
    lines = [ln.rstrip(" \t\r") for ln in text.replace("\r\n", "\n").split("\n")]
    while lines and lines[-1] == "":
        lines.pop()
    return "\n".join(lines)


def norm_lines(text):
    return [ln.rstrip(" \t\r") for ln in text.replace("\r\n", "\n").split("\n")]


def split_lines(text):
    parts = text.split("\n")
    out = [p + "\n" for p in parts[:-1]]
    if parts[-1] != "":
        out.append(parts[-1])
    return out


def body(line):
    return line.rstrip("\r\n")


def is_blank(line):
    return body(line).strip(" \t\r\f") == ""


def indent_of(line):
    col = 0
    for ch in line:
        if ch == " ":
            col += 1
        elif ch == "\t":
            col += 4 - (col % 4)
        else:
            break
    return col


RE_ATX = re.compile(r"^ {0,3}(#{1,6})(?:[ \t]+(.*?))?(?:[ \t]+#+)?[ \t]*$")
RE_HR = re.compile(r"^ {0,3}([-*_])(?:[ \t]*\1){2,}[ \t]*$")
RE_QUOTE = re.compile(r"^ {0,3}>")
RE_ITEM = re.compile(r"^[ \t]*(?:[-*+]|(\d{1,9})[.)])(?:[ \t]|$)")
RE_SETEXT = re.compile(r"^ {0,3}(?:=+|-+)[ \t]*$")
RE_TABLE_DELIM = re.compile(r"^[ \t]*\|?[ \t]*:?-+:?[ \t]*(?:\|[ \t]*:?-+:?[ \t]*)*\|?[ \t]*$")
RE_FENCE = re.compile(r"^[ \t]*(`{3,}|~{3,})(.*)$")


def fence_open(line, max_indent):
    """Return (char, length) when `line` opens a code fence indented <= max_indent."""
    b = body(line)
    m = RE_FENCE.match(b)
    if not m or indent_of(b) > max_indent:
        return None
    if m.group(1)[0] == "`" and "`" in m.group(2):   # ```x``` is inline code, not a fence
        return None
    return m.group(1)[0], len(m.group(1))


def fence_end(lines, i, ch, ln):
    """(index of the closing fence line, True); when never closed, as CommonMark does: the last
    line and False."""
    for j in range(i + 1, len(lines)):
        s = body(lines[j]).strip()
        if s and set(s) == {ch} and len(s) >= ln:
            return j, True
    return len(lines) - 1, False


def is_table_start(lines, i):
    return (i + 1 < len(lines) and "|" in body(lines[i]) and "|" in body(lines[i + 1])
            and RE_TABLE_DELIM.match(body(lines[i + 1])) is not None)


def starts_comment(line):
    return body(line).lstrip(" ").startswith("<!--") and indent_of(line) <= 3


def comment_end(lines, i):
    start = body(lines[i]).find("<!--") + 4
    if "-->" in body(lines[i])[start:]:
        return i
    for j in range(i + 1, len(lines)):
        if "-->" in lines[j]:
            return j
    return len(lines) - 1


def interrupts_para(line):
    b = body(line)
    if RE_ATX.match(b) or RE_HR.match(b) or RE_QUOTE.match(b) or starts_comment(line):
        return True
    if fence_open(line, 3):
        return True
    m = RE_ITEM.match(b)
    return bool(m) and (m.group(1) is None or m.group(1) == "1")


def starts_block(line):
    b = body(line)
    return bool(RE_ATX.match(b) or RE_HR.match(b) or RE_QUOTE.match(b) or starts_comment(line)
                or fence_open(line, 3) or RE_ITEM.match(b))


def scan_item(lines, i):
    """Last line of the list item starting at i: indented continuations (nested items, fences,
    text after blank lines) and lazy paragraph continuations stay inside; a sibling ends it."""
    n = len(lines)
    base = indent_of(lines[i])
    last = i
    j = i + 1
    while j < n:
        if is_blank(lines[j]):
            k = j
            while k < n and is_blank(lines[k]):
                k += 1
            if k < n and indent_of(lines[k]) > base:
                j = k
                continue
            break
        if indent_of(lines[j]) > base:
            fo = fence_open(lines[j], 10 ** 6)
            if fo:
                j, _ = fence_end(lines, j, fo[0], fo[1])
            last = j
            j += 1
            continue
        if last == j - 1 and not starts_block(lines[j]) and not is_table_start(lines, j):
            last = j          # lazy continuation of the item's paragraph
            j += 1
            continue
        break
    return last


def scan_block(lines, i, allow_frontmatter):
    """(kind, last_line_index, closed) of the block starting at line i."""
    n = len(lines)
    b = body(lines[i])
    if allow_frontmatter and b.rstrip() in ("---", "+++"):
        for j in range(i + 1, n):
            if body(lines[j]).rstrip() in (b.rstrip(), "..."):
                return "frontmatter", j, True
    fo = fence_open(lines[i], 3)
    if fo:
        j, closed = fence_end(lines, i, fo[0], fo[1])
        return "fence", j, closed
    if RE_ATX.match(b):
        return "heading", i, True
    if starts_comment(lines[i]):
        j = comment_end(lines, i)
        after_open = "".join(lines[i:j + 1]).split("<!--", 1)[1]
        return "comment", j, "-->" in after_open
    if RE_HR.match(b):
        return "hr", i, True
    if RE_QUOTE.match(b):
        j = i
        while j + 1 < n and RE_QUOTE.match(body(lines[j + 1])):
            j += 1
        return "quote", j, True
    if is_table_start(lines, i):
        j = i + 1
        while j + 1 < n and not is_blank(lines[j + 1]) and "|" in lines[j + 1]:
            j += 1
        return "table", j, True
    if RE_ITEM.match(b):
        return "item", scan_item(lines, i), True
    j = i + 1
    while j < n and not is_blank(lines[j]):
        if RE_SETEXT.match(body(lines[j])):            # "Title" / "=====" is a heading
            return "heading", j, True
        if interrupts_para(lines[j]) or is_table_start(lines, j):
            break
        j += 1
    return "para", j - 1, True


def parse_blocks(text):
    """(lead, blocks). Raises Fatal if the rebuild does not equal the input (a parser bug)."""
    lines = split_lines(text)
    n = len(lines)
    i = 0
    while i < n and is_blank(lines[i]):
        i += 1
    lead = "".join(lines[:i])
    blocks = []
    off = len(lead)
    first_block = True
    while i < n:
        kind, last, closed = scan_block(lines, i, first_block and i == 0)
        first_block = False
        btext = "".join(lines[i:last + 1])
        k = last + 1
        while k < n and is_blank(lines[k]):
            k += 1
        gap = "".join(lines[last + 1:k])
        b = Block(len(blocks) + 1, kind, i + 1, last + 1, btext, gap, off, closed)
        if kind == "heading":
            first = body(lines[i])
            m = RE_ATX.match(first)
            if m:
                b.level, b.htext = len(m.group(1)), (m.group(2) or "").strip()
            else:                                      # setext: level from the underline
                b.level = 1 if body(lines[last]).lstrip().startswith("=") else 2
                b.htext = " ".join(body(x).strip() for x in lines[i:last])
        blocks.append(b)
        off += len(btext) + len(gap)
        i = k
    if rebuild(lead, blocks) != text:
        raise Fatal("internal error: block round-trip failed (parser bug)")
    return lead, blocks


def rebuild(lead, blocks):
    return lead + "".join(b.text + b.gap for b in blocks)


# ---------------------------------------------------------------------------
# File helpers. Text is decoded with surrogateescape so any bytes survive a round trip.
# ---------------------------------------------------------------------------

def read_text(path):
    with open(path, "rb") as fh:
        return fh.read().decode("utf-8", "surrogateescape")


def enc(text):
    return text.encode("utf-8", "surrogateescape")


def write_atomic(real, data, mode=0o644):
    d = os.path.dirname(real)
    fd, tmp = tempfile.mkstemp(dir=d, prefix=".retrofit-")
    try:
        with os.fdopen(fd, "wb") as fh:
            fh.write(data)
        os.chmod(tmp, mode)
        os.replace(tmp, real)
    except BaseException:
        if os.path.exists(tmp):
            os.unlink(tmp)
        raise


def within(root, path):
    return path == root or path.startswith(root + os.sep)


def today():
    d = os.environ.get("RETROFIT_DATE") or datetime.date.today().isoformat()
    if not re.match(r"^\d{4}-\d{2}-\d{2}$", d):
        raise Fatal("RETROFIT_DATE must be YYYY-MM-DD")
    return d


def repo_root(arg):
    r = os.path.realpath(arg or os.getcwd())
    if not os.path.isdir(r):
        raise Fatal("repo is not a directory: %s" % r)
    return r


def resolve(root, rel):
    """(clean relative path, real path) or a message. The real path must stay inside the repo,
    also when a symlink on the way points out."""
    if not rel or "\0" in rel:
        return None, "empty or invalid path"
    if os.path.isabs(rel):
        return None, "path escapes the repo (absolute path): %s" % rel
    clean = os.path.normpath(rel)
    if clean == ".." or clean.startswith(".." + os.sep):
        return None, "path escapes the repo: %s" % rel
    if ".git" in clean.split(os.sep):
        return None, "path is inside .git: %s" % rel
    real = os.path.realpath(os.path.join(root, clean))
    if not within(root, real):
        return None, "path escapes the repo (symlink): %s" % rel
    return (clean, real), None


# ---------------------------------------------------------------------------
# Plan parser (strict). Every problem is reported with its line number; nothing is written.
# ---------------------------------------------------------------------------

RE_SRC = re.compile(r"^##\s+source:\s*(.+?)\s+sha256:([0-9a-fA-F]{64})\s*$")
RE_MAP = re.compile(r"^B(\d{3,})-([0-9a-f]{4})(?:\.\.B(\d{3,})-([0-9a-f]{4}))?\s*->\s*(\S.*?)\s*$")


def sha256_bytes(data):
    return hashlib.sha256(data).hexdigest()


def source_header(rel, data):
    """The exact plan header line for a source; `blocks` prints it for pasting."""
    return "## source: %s sha256:%s" % (rel, sha256_bytes(data))


class Entry:
    def __init__(self, line, first, last, kind, dest=None, dest_real=None, anchor=None):
        self.line, self.first, self.last = line, first, last
        self.kind = kind            # move keep unsorted
        self.dest, self.dest_real, self.anchor = dest, dest_real, anchor


class SourcePlan:
    def __init__(self, line, rel, real, sha, origin, text, lead, blocks):
        self.line, self.rel, self.real, self.sha = line, rel, real, sha
        self.origin = origin        # live: the file on disk is the planned text; archive: finalized
        self.text, self.lead, self.blocks = text, lead, blocks
        self.entries = []
        self.assign = {}            # block idx -> Entry

    def ids(self, entry):
        a, b = self.blocks[entry.first - 1], self.blocks[entry.last - 1]
        return a.id if a is b else "%s..%s" % (a.id, b.id)


class Plan:
    def __init__(self, root, path):
        self.root, self.path, self.sources = root, path, []


def load_source(root, rel, real, sha):
    """(bytes, origin) of the text the plan was made from, or None. The live file counts only
    if its sha256 matches; otherwise the archive made by finalize, if ITS sha256 matches."""
    if os.path.isfile(real):
        data = open(real, "rb").read()
        if sha256_bytes(data) == sha:
            return data, "live"
    name = rel.replace(os.sep, "__")
    adir = os.path.join(root, "docs", "archive")
    if os.path.isdir(adir):
        for f in sorted(os.listdir(adir)):
            mid = f[len(name) + 1:-5]
            if f.startswith(name + ".") and f.endswith(".orig") and re.match(r"^\d{4}-\d{2}-\d{2}$", mid):
                p = os.path.realpath(os.path.join(adir, f))
                if within(root, p) and os.path.isfile(p):
                    data = open(p, "rb").read()
                    if sha256_bytes(data) == sha:
                        return data, "archive"
    return None


def dest_problem(rel, real, strict):
    """Why `rel` cannot be a destination, or None. Only existing .md/.txt text files qualify."""
    if os.path.basename(rel).startswith("."):
        return "dotfiles are never destinations: %s" % rel
    if not rel.lower().endswith((".md", ".txt")):
        return "destination must be a .md or .txt file: %s" % rel
    if rel == "MAP.md":
        return "MAP.md is generated; run scripts/map.py instead"
    if os.path.exists(real):
        if not os.path.isfile(real):
            return "destination is not a regular file: %s" % rel
        if strict:
            data = open(real, "rb").read()
            try:
                data.decode("utf-8")
            except UnicodeDecodeError:
                return "destination is not UTF-8 text: %s" % rel
            if b"\0" in data:
                return "destination looks binary (NUL byte): %s" % rel
    elif strict and rel != UNSORTED:
        if rel in STANDARD_DOCS:
            return ("standard doc %s does not exist; scaffold it first (cut-project.sh --generic [--with ...])"
                    % rel)
        return "%s is not a standard doc and does not exist" % rel
    return None


def parse_plan(root, plan_path, strict_dest=False):
    """Parse and validate. strict_dest (apply only) also demands that destinations exist; the
    other commands tolerate a missing destination so that `check` can report the loss (exit 1)."""
    if not os.path.isfile(plan_path):
        raise Fatal("plan file not found: %s" % plan_path)
    plan_real = os.path.realpath(plan_path)
    errs = []
    plan = Plan(root, plan_path)
    cur = None
    for no, raw in enumerate(read_text(plan_path).split("\n"), 1):
        line = raw.rstrip("\r").strip()
        if not line:
            continue
        m = RE_SRC.match(line)
        if m:
            cur = None
            r, msg = resolve(root, m.group(1))
            if msg:
                errs.append((no, msg))
                continue
            rel, real = r
            if any(s.rel == rel for s in plan.sources):
                errs.append((no, "source listed twice: %s" % rel))
                continue
            loaded = load_source(root, rel, real, m.group(2).lower())
            if loaded is None:
                errs.append((no, "source %s is missing or changed since 'blocks' (sha256 differs and no "
                             "matching archive); re-run blocks and rebuild the plan" % rel))
                continue
            data, origin = loaded
            text = data.decode("utf-8", "surrogateescape")
            lead, blocks = parse_blocks(text)
            cur = SourcePlan(no, rel, real, m.group(2).lower(), origin, text, lead, blocks)
            plan.sources.append(cur)
            continue
        if line.startswith("## source"):
            errs.append((no, "malformed source header (want: ## source: <path> sha256:<64 hex>, "
                         "the line `blocks` prints)"))
            continue
        if line.startswith("#"):
            continue
        m = RE_MAP.match(line)
        if not m:
            errs.append((no, "cannot parse line: %s" % line))
            continue
        if cur is None:
            errs.append((no, "mapping line outside a valid '## source:' section"))
            continue
        i1, h1, i2, h2, dest = int(m.group(1)), m.group(2), m.group(3), m.group(4), m.group(5)
        i2 = int(i2) if i2 else i1
        h2 = h2 or h1
        ok = True
        for idx, h in ((i1, h1), (i2, h2)):
            if idx < 1 or idx > len(cur.blocks):
                errs.append((no, "unknown block id B%03d-%s (source has %d blocks)" % (idx, h, len(cur.blocks))))
                ok = False
            elif cur.blocks[idx - 1].hash != h:
                errs.append((no, "stale hash for B%03d-%s: source now has B%03d-%s (re-run blocks)"
                             % (idx, h, idx, cur.blocks[idx - 1].hash)))
                ok = False
        if ok and i2 < i1:
            errs.append((no, "range runs backwards"))
            ok = False
        if ok:
            for idx in range(i1, i2 + 1):
                if idx in cur.assign:
                    errs.append((no, "block %s mentioned twice (first at line %d)"
                                 % (cur.blocks[idx - 1].id, cur.assign[idx].line)))
                    ok = False
                    break
        entry = None
        if dest == "keep":
            entry = Entry(no, i1, i2, "keep")
        elif dest == "unsorted":
            entry = Entry(no, i1, i2, "unsorted")
            r, msg = resolve(root, UNSORTED)
            if msg:
                errs.append((no, msg))
                ok = False
            else:
                entry.dest, entry.dest_real = UNSORTED, r[1]
        else:
            path, _, anchor = dest.partition("#")
            path = path.strip()
            if "#" in dest and not anchor.strip():
                errs.append((no, "empty #anchor"))
                ok = False
            r, msg = resolve(root, path)
            if msg:
                errs.append((no, msg))
                ok = False
            else:
                rel, real = r
                msg = dest_problem(rel, real, strict_dest)
                if msg:
                    errs.append((no, msg))
                    ok = False
                else:
                    entry = Entry(no, i1, i2, "move", rel, real, anchor.strip() or None)
        if ok and entry:
            cur.entries.append(entry)
            for idx in range(i1, i2 + 1):
                cur.assign[idx] = entry
    # A destination may be none of: the plan file, a source of this plan (also via hard link).
    for s in plan.sources:
        for e in s.entries:
            if not e.dest_real:
                continue
            for g, what in [(x.real, "the source itself" if x is s else "another source of this plan (%s)" % x.rel)
                            for x in plan.sources] + [(plan_real, "the plan file")]:
                same = e.dest_real == g or (os.path.exists(e.dest_real) and os.path.exists(g)
                                            and os.path.samefile(e.dest_real, g))
                if same:
                    errs.append((e.line, "destination is %s" % what))
                    break
    if not plan.sources and not errs:
        errs.append((1, "plan has no '## source: <path> sha256:<hash>' section"))
    if plan.sources and not errs and not any(s.entries for s in plan.sources):
        errs.append((1, "plan maps no blocks"))
    for s in plan.sources:
        missing = [b.id for b in s.blocks if b.idx not in s.assign]
        if missing and not errs:       # report unaccounted blocks once the lines themselves are valid
            more = " (+%d more)" % (len(missing) - 15) if len(missing) > 15 else ""
            errs.append((s.line, "%d block(s) of %s not accounted for: %s%s"
                         % (len(missing), s.rel, ", ".join(missing[:15]), more)))
    if errs:
        errs.sort()
        for no, msg in errs[:50]:
            sys.stderr.write("%s:%d: %s\n" % (os.path.basename(plan_path), no, msg))
        if len(errs) > 50:
            sys.stderr.write("... %d more errors\n" % (len(errs) - 50))
        sys.stderr.write("plan rejected; nothing written\n")
        raise SystemExit(2)
    return plan


def run_text(src, entry):
    """The exact text of a run: its blocks with their original gaps between them."""
    out = ""
    for k in range(entry.first, entry.last + 1):
        b = src.blocks[k - 1]
        out += b.text + (b.gap if k < entry.last else "")
    return out


# ---------------------------------------------------------------------------
# Matching: block level. A source block is present in a text only if the text, parsed into
# blocks, holds an equal block (same kind, same normalised text) or a short run of consecutive
# blocks whose joined text equals it (front matter re-parses as a rule plus a heading, say).
# Text inside a fence or comment is part of that fence/comment block, so it never matches.
# Each destination block satisfies at most ONE source block.
# ---------------------------------------------------------------------------

def match_rows(hay, rows):
    """Set row['ok'] for each row {'block': Block}; `hay` is the list of blocks of the text."""
    used = set()
    firsts = [b.norm.split("\n", 1)[0] for b in hay]

    def match_run(r):
        """Match r to a short run of unused consecutive blocks whose joined text equals it."""
        target = r["block"].norm
        first = target.split("\n", 1)[0]
        for i in range(len(hay)):
            if i in used or firsts[i] != first:
                continue
            parts, j = [hay[i].text], i
            while True:
                if norm("".join(parts)) == target:
                    used.update(range(i, j + 1))
                    r["ok"] = True
                    return
                if j + 1 >= len(hay) or j - i >= 5 or (j + 1) in used:
                    break
                parts += [hay[j].gap, hay[j + 1].text]
                j += 1

    # Front matter first: mid-file it re-parses as a rule plus a heading, and the rule must not
    # be taken by a real horizontal rule matched earlier.
    for r in rows:
        if r["block"].kind == "frontmatter":
            match_run(r)
    index = collections.defaultdict(collections.deque)
    for i, b in enumerate(hay):
        if i not in used:
            index[(b.kind, b.norm)].append(i)
    pending = []
    for r in rows:
        if r["ok"]:
            continue
        sb = r["block"]
        q = index.get((sb.kind, sb.norm))
        if q:
            used.add(q.popleft())
            r["ok"] = True
        else:
            pending.append(r)
    for r in pending:
        match_run(r)


def run_check(plan, overrides=None):
    """A row for every block: moved => in its destination; keep => in the live source file;
    unsorted => in UNSORTED.md. `overrides` maps a real path to the text to use instead of
    the file (apply uses it to verify before it writes)."""
    overrides = overrides or {}
    by_target = collections.OrderedDict()
    rows = []
    for src in plan.sources:
        for b in src.blocks:
            e = src.assign[b.idx]
            target = src.real if e.kind == "keep" else e.dest_real
            row = {"src": src, "block": b, "entry": e, "ok": False, "why": ""}
            rows.append(row)
            by_target.setdefault(target, []).append(row)
    for target, rs in by_target.items():
        if target in overrides:
            text = overrides[target]
        elif os.path.isfile(target):
            text = read_text(target)
        else:
            text = None
        if text is None:
            for r in rs:
                r["why"] = "file does not exist"
            continue
        match_rows(parse_blocks(text)[1], rs)
    return rows


def where_of(row):
    e = row["entry"]
    return "keep" if e.kind == "keep" else e.dest


# ---------------------------------------------------------------------------
# apply
# ---------------------------------------------------------------------------

def nl_of(text):
    """The destination's own line ending (from its first line), for the text we add around blocks."""
    i = text.find("\n")
    return "\r\n" if i > 0 and text[i - 1] == "\r" else "\n"


def norm_heading(s):
    return " ".join(s.casefold().split())


def section_end(text, hb, blocks):
    """Offset where the section of heading block hb ends: the next heading of the same or a
    higher level, else end of file."""
    for b in blocks[hb.idx:]:
        if b.kind == "heading" and b.level <= hb.level:
            return b.off
    return len(text)


def resolve_anchor(blocks, anchor, line):
    want = norm_heading(anchor)
    hits = [b for b in blocks if b.kind == "heading" and norm_heading(b.htext) == want]
    if not hits:
        avail = ", ".join(b.htext for b in blocks if b.kind == "heading")[:300]
        raise Fatal("plan line %d: heading '%s' not found in destination (headings: %s)" % (line, anchor, avail))
    if len(hits) > 1:
        raise Fatal("plan line %d: heading '%s' is ambiguous in destination (%d matches)" % (line, anchor, len(hits)))
    return hits[0]


def blank_sep(out, nl):
    """Make `out` end with a blank line (or be empty) so what follows starts a fresh block."""
    if out and not out.endswith("\n"):
        out += nl
    if out and not re.search(r"\n[ \t\r]*\n$", out):
        out += nl
    return out


def assemble(text, items):
    """Splice the new items into the ORIGINAL text. items: (offset, kind, payload) in plan
    order; items at one offset keep plan order, so a second run lands after the first."""
    nl = nl_of(text)
    out, cur = "", 0
    for pos in sorted({p for p, _, _ in items}):
        out += text[cur:pos]
        cur = pos
        for p, kind, payload in items:
            if p != pos:
                continue
            out = blank_sep(out, nl)
            if kind == "heading":
                out += "## %s%s" % (payload, nl)
            else:
                comment, run = payload
                out += comment + nl + run
                if not out.endswith("\n"):
                    out += nl
        if text[pos:]:
            out += nl             # blank line before the heading that follows
    return out + text[cur:]


def simulate(plan):
    """Apply the whole plan in memory against the destinations as they are NOW. Anchors are
    resolved against that original text, so a heading moved by an earlier run cannot make an
    anchor ambiguous or end its section early. Returns (texts, created, recs)."""
    orig, parsed, created, groups, recs = {}, {}, set(), collections.OrderedDict(), []
    emitted = set()
    for src in plan.sources:
        for e in src.entries:
            if e.kind == "keep":
                continue
            real = e.dest_real
            if real not in orig:
                if os.path.exists(real):
                    orig[real] = read_text(real)
                else:
                    orig[real] = UNSORTED_HEADER
                    created.add(real)
                parsed[real] = parse_blocks(orig[real])[1]
            text, blocks = orig[real], parsed[real]
            comment = "<!-- moved from %s %s -->" % (src.rel, src.ids(e))
            rec = {"dest": e.dest, "real": real, "src": src, "entry": e, "comment": comment,
                   "done": comment in text, "where": None, "warn": None}
            recs.append(rec)
            if rec["done"]:
                continue
            items = groups.setdefault(real, [])
            if blocks and not blocks[-1].closed:
                raise Fatal("%s ends inside an unclosed code fence or comment; close it first "
                            "(a run would be appended inside it)" % e.dest)
            if e.anchor:
                hb = resolve_anchor(blocks, e.anchor, e.line)
                pos = section_end(text, hb, blocks)
                rec["where"] = 'end of "%s"' % hb.htext
                levels = [b.level for b in src.blocks[e.first - 1:e.last] if b.kind == "heading"]
                if levels and min(levels) <= hb.level:
                    rec["warn"] = ("run holds a level-%d heading, which ends the section of '%s' (level %d) "
                                   "for later readers; use a flat anchor or include its children"
                                   % (min(levels), hb.htext, hb.level))
            else:
                title = "Moved from %s" % src.rel
                pos = len(text)
                rec["where"] = 'end of file, under "## %s"' % title
                has = any(b.kind == "heading" and b.level == 2 and b.htext == title for b in blocks)
                if not has and (real, src.rel) not in emitted:
                    items.append((pos, "heading", title))
                    emitted.add((real, src.rel))
            items.append((pos, "run", (comment, run_text(src, e))))
    texts = {real: assemble(orig[real], groups.get(real, [])) for real in orig}
    return texts, created, recs


def preflight_fs(texts, created):
    """Every file that will change must be writable BEFORE the first one is written."""
    for real, text in texts.items():
        d = os.path.dirname(real)
        if real in created:
            if not (os.path.isdir(d) and os.access(d, os.W_OK | os.X_OK)):
                raise Fatal("cannot create %s: directory not writable" % os.path.basename(real))
        elif read_text(real) != text:
            if not os.access(real, os.W_OK):
                raise Fatal("destination not writable: %s" % os.path.relpath(real))
            if not os.access(d, os.W_OK | os.X_OK):
                raise Fatal("directory not writable (needed for an atomic replace): %s" % os.path.relpath(d))


def cmd_apply(args):
    root = repo_root(args.repo)
    plan = parse_plan(root, args.plan, strict_dest=True)
    texts, created, runs = simulate(plan)
    preflight_fs(texts, created)
    bad = [r for r in run_check(plan, texts) if not r["ok"]]
    if bad:
        for r in bad[:20]:
            sys.stderr.write("would not be found verbatim: %s:%s -> %s (%s)\n"
                             % (r["src"].rel, r["block"].id, where_of(r), r["block"].preview))
        raise Fatal("refusing to apply: %d block(s) would not read back as the same block in their "
                    "destination (merged with neighbouring text, or a comment/provenance line is stale)" % len(bad))
    per = collections.OrderedDict()
    for r in runs:
        d = per.setdefault(r["dest"], {"blocks": 0, "bytes": 0, "new": 0, "done": 0, "real": r["real"]})
        e, src = r["entry"], r["src"]
        if r["done"]:
            d["done"] += 1
        else:
            d["new"] += 1
            d["blocks"] += e.last - e.first + 1
            d["bytes"] += len(enc(run_text(src, e)))
    print("%s: %s" % ("APPLY" if args.yes else "DRY RUN (nothing written; add --yes to apply)", args.plan))
    for dest, d in per.items():
        state = "will be created" if d["real"] in created else "exists"
        print("%s (%s): %d block(s), %d byte(s) to append in %d run(s); %d run(s) already applied"
              % (dest, state, d["blocks"], d["bytes"], d["new"], d["done"]))
    for r in runs:
        e, src = r["entry"], r["src"]
        if r["done"]:
            print("  skip (already applied): %s" % r["comment"])
            continue
        print("  %s -> %s at %s" % (r["comment"], r["dest"], r["where"]))
        if r["warn"]:
            print("  WARNING: %s" % r["warn"])
        for k in range(e.first, e.last + 1):
            b = src.blocks[k - 1]
            print("    %s %-8s %s" % (b.id, b.kind, b.preview))
        if args.show_text:
            print("    ---- text ----")
            print(run_text(src, e).rstrip("\n"))
            print("    ---- end ----")
    keeps = sum(e.last - e.first + 1 for s in plan.sources for e in s.entries if e.kind == "keep")
    print("keep: %d block(s) stay in their source (never modified by apply)" % keeps)
    if not args.yes:
        return 0
    written = 0
    for real, text in texts.items():
        if os.path.exists(real) and read_text(real) == text:
            continue
        mode = (os.stat(real).st_mode & 0o777) if os.path.exists(real) else 0o644
        write_atomic(real, enc(text), mode)
        written += 1
    print("wrote %d file(s). Next: retrofit.py check %s --report" % (written, args.plan))
    print("apply has no revert command: undo with git (restore the destinations, delete a new UNSORTED.md)")
    return 0


# ---------------------------------------------------------------------------
# check
# ---------------------------------------------------------------------------

def cmd_check(args):
    root = repo_root(args.repo)
    plan = parse_plan(root, args.plan)
    rows = run_check(plan)
    bad = [r for r in rows if not r["ok"]]
    for src in plan.sources:
        mine = [r for r in rows if r["src"] is src]
        print("source %s: %d block(s)%s" % (src.rel, len(mine), " (read from its archive)" if src.origin == "archive" else ""))
        tally = collections.OrderedDict()
        for r in mine:
            t = tally.setdefault(where_of(r), [0, 0])
            t[0 if r["ok"] else 1] += 1
        for dest, (ok, miss) in tally.items():
            print("  %-28s ok %4d   missing %4d" % (dest, ok, miss))
    print("accounted: %d/%d   missing or altered: %d" % (len(rows) - len(bad), len(rows), len(bad)))
    for r in bad:
        print("MISSING %s:%s -> %s  (%s)%s" % (r["src"].rel, r["block"].id, where_of(r), r["block"].preview,
                                               "  [%s]" % r["why"] if r["why"] else ""))
    if args.report:
        for src in plan.sources:
            write_report(root, plan, src, [r for r in rows if r["src"] is src])
    return 1 if bad else 0


def write_report(root, plan, src, rows):
    name = src.rel.replace(os.sep, "-")
    rel = os.path.join("docs", "archive", "retrofit-%s-%s-coverage.md" % (name, today()))
    r, msg = resolve(root, rel)
    if msg:
        raise Fatal(msg)
    bad = sum(1 for x in rows if not x["ok"])
    out = ["# Retrofit coverage: %s" % src.rel, "",
           "- Date: %s" % today(),
           "- Result: %s (%d of %d blocks accounted)" % ("PASS" if not bad else "FAIL", len(rows) - bad, len(rows)),
           "- Source sha256: %s" % src.sha,
           "- Checked block by block: each source block must equal a block of its destination, ignoring "
           "only CRLF and trailing blanks.", "",
           "| Block | Lines | Kind | Preview | Went to | Status |", "|---|---|---|---|---|---|"]
    for x in rows:
        b = x["block"]
        out.append("| %s | %d-%d | %s | %s | %s | %s |" % (
            b.id, b.first, b.last, b.kind, b.preview.replace("|", "\\|"), where_of(x),
            "ok" if x["ok"] else "MISSING"))
    os.makedirs(os.path.dirname(r[1]), exist_ok=True)
    write_atomic(r[1], enc("\n".join(out) + "\n"))
    print("report: %s" % r[0])


# ---------------------------------------------------------------------------
# keep / finalize
# ---------------------------------------------------------------------------

def pick_source(plan, name):
    if name:
        for s in plan.sources:
            if s.rel == os.path.normpath(name):
                return s
        raise Fatal("source not in plan: %s" % name)
    if len(plan.sources) != 1:
        raise Fatal("plan has %d sources; pass --source" % len(plan.sources))
    return plan.sources[0]


def keep_blocks(src):
    return [src.blocks[k - 1] for e in src.entries if e.kind == "keep" for k in range(e.first, e.last + 1)]


def cmd_keep(args):
    plan = parse_plan(repo_root(args.repo), args.plan)
    src = pick_source(plan, args.source)
    # Blocks are separated by one blank line; the text itself is untouched.
    out = "".join((b.text if b.text.endswith("\n") else b.text + "\n") + "\n"
                  for b in sorted(keep_blocks(src), key=lambda b: b.idx))
    sys.stdout.flush()
    sys.stdout.buffer.write(enc(out))
    return 0


def git_clean(root, rel):
    """True when `rel` is tracked and has no uncommitted change."""
    try:
        t = subprocess.run(["git", "-C", root, "ls-files", "--error-unmatch", "--", rel],
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        if t.returncode != 0:
            return False
        s = subprocess.run(["git", "-C", root, "status", "--porcelain", "--", rel],
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        return s.returncode == 0 and not s.stdout.strip()
    except OSError:
        return False


def shquote(s):
    return "'" + s.replace("'", "'\\''") + "'"


def cmd_finalize(args):
    root = repo_root(args.repo)
    plan = parse_plan(root, args.plan)
    src = pick_source(plan, args.source)
    if src.origin != "live":
        raise Fatal("%s is already finalized (the live file no longer matches the plan's sha256)" % src.rel)
    rows = run_check(plan)
    bad = [r for r in rows if not r["ok"]]
    if bad:
        for r in bad[:30]:
            print("MISSING %s:%s -> %s" % (r["src"].rel, r["block"].id, where_of(r)))
        print("finalize refused: check fails (%d block(s) missing). Nothing changed." % len(bad))
        return 1
    if not os.path.isfile(args.replace_with):
        raise Fatal("--replace-with file not found: %s" % args.replace_with)
    repl = read_text(args.replace_with)
    if not repl.strip():
        raise Fatal("--replace-with file is empty")
    if os.path.realpath(args.replace_with) == src.real:
        raise Fatal("--replace-with is the source itself")
    # Blocks marked keep must survive in the new entry doc, verbatim, as blocks of their own.
    krows = [{"block": b, "ok": False} for b in keep_blocks(src)]
    match_rows(parse_blocks(repl)[1], krows)
    lost = [r["block"] for r in krows if not r["ok"]]
    if lost:
        for b in lost[:30]:
            print("KEEP BLOCK NOT IN REPLACEMENT %s (%s)" % (b.id, b.preview))
        print("finalize refused: blocks marked keep are missing from %s. Put them in verbatim "
              "(retrofit.py keep prints them) or re-route them in the plan. Nothing changed." % args.replace_with)
        return 1
    if os.path.islink(os.path.join(root, src.rel)):
        raise Fatal("%s is a symlink; finalize its target instead" % src.rel)
    if not args.allow_dirty and not git_clean(root, src.rel):
        raise Fatal("%s is not tracked-and-clean in git (commit it first; --allow-dirty only with the "
                    "operator's explicit yes)" % src.rel)
    arch_rel = os.path.join("docs", "archive", "%s.%s.orig" % (src.rel.replace(os.sep, "__"), today()))
    r, msg = resolve(root, arch_rel)
    if msg:
        raise Fatal(msg)
    original = open(src.real, "rb").read()
    reuse = False
    if os.path.lexists(r[1]):
        if os.path.isfile(r[1]) and not os.path.islink(r[1]) and open(r[1], "rb").read() == original:
            reuse = True      # a retry after a failed replace: the archive is already the original
        else:
            raise Fatal("archive already exists and differs, refusing to overwrite: %s" % arch_rel)
    print("%s: %s" % ("FINALIZE" if args.yes else "DRY RUN (nothing written; add --yes)", src.rel))
    print("  check passes; all %d keep block(s) are in the replacement" % len(keep_blocks(src)))
    print("  %s original (%d bytes) -> %s" % ("archive already holds the" if reuse else "archive", len(original), arch_rel))
    print("  replace %s with %s (%d lines)" % (src.rel, args.replace_with, len(split_lines(repl))))
    undo = "mv %s %s" % (shquote(arch_rel), shquote(src.rel))
    if args.yes:
        if not reuse:
            os.makedirs(os.path.dirname(r[1]), exist_ok=True)
            write_atomic(r[1], original, 0o644)
            if open(r[1], "rb").read() != original:
                raise Fatal("archive verification failed; source left untouched")
        write_atomic(src.real, enc(repl), os.stat(src.real).st_mode & 0o777)
        print("done. Undo, from the repo root (restores exactly what was archived): %s" % undo)
    else:
        print("  undo later, from the repo root: %s" % undo)
    return 0


# ---------------------------------------------------------------------------
# survey / blocks
# ---------------------------------------------------------------------------

def cmd_survey(args):
    root = repo_root(args.repo)
    cands = []
    for name in sorted(os.listdir(root)):
        low = name.lower()
        if name in ("CLAUDE.md", "AGENTS.md", "README.md", "TODO.md") or low.startswith("notes"):
            cands.append(name)
    docs = os.path.join(root, "docs")
    if os.path.isdir(docs):
        cands += ["docs/" + n for n in sorted(os.listdir(docs)) if n.endswith(".md")]
    if os.path.isfile(os.path.join(root, ".claude", "CLAUDE.md")):
        cands.append(".claude/CLAUDE.md")
    print("candidate source docs in %s" % root)
    for rel in cands:
        r, msg = resolve(root, rel)
        if msg or not os.path.isfile(r[1]):
            print("  %-28s skipped (%s)" % (rel, msg or "not a regular file"))
            continue
        text = read_text(r[1])
        _, blocks = parse_blocks(text)
        print("  %-28s %7d bytes %5d blocks" % (rel, len(enc(text)), len(blocks)))
    for d in ("LOGS", "logs", "Logs"):
        p = os.path.join(root, d)
        if os.path.isdir(p) and not os.path.islink(p):
            names = sorted(os.listdir(p))
            print("  %s/ (names only, %d): %s%s" % (d, len(names), ", ".join(names[:20]),
                                                    " ..." if len(names) > 20 else ""))
    print("standard docs")
    for name in STANDARD_DOCS + [UNSORTED]:
        p = os.path.join(root, name)
        if os.path.isfile(p):
            fills = read_text(p).count("<fill")
            print("  %-18s exists  %6d bytes  %d <fill> marker(s)" % (name, os.path.getsize(p), fills))
        else:
            print("  %-18s missing" % name)
    return 0


def cmd_blocks(args):
    if not os.path.isfile(args.file):
        raise Fatal("file not found: %s" % args.file)
    data = open(args.file, "rb").read()
    text = data.decode("utf-8", "surrogateescape")
    lead, blocks = parse_blocks(text)
    if args.rebuild:
        sys.stdout.flush()
        sys.stdout.buffer.write(enc(rebuild(lead, blocks)))
        return 0
    print("# %s: %d blocks, %d bytes" % (args.file, len(blocks), len(data)))
    print(source_header(os.path.normpath(args.file), data))   # paste this line into the plan
    for b in blocks:
        print("%s  L%d-%d  %-11s %s" % (b.id, b.first, b.last, b.kind, b.preview))
    return 0


def main(argv=None):
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.reconfigure(errors="backslashreplace")
        except AttributeError:
            pass
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("survey"); p.add_argument("repo", nargs="?")
    p = sub.add_parser("blocks"); p.add_argument("file"); p.add_argument("--rebuild", action="store_true")
    for name in ("apply", "check", "keep", "finalize"):
        p = sub.add_parser(name)
        p.add_argument("plan")
        p.add_argument("--repo", help="repo root (default: current directory)")
        if name == "apply":
            p.add_argument("--yes", action="store_true")
            p.add_argument("--show-text", action="store_true")
        if name == "check":
            p.add_argument("--report", action="store_true")
        if name in ("keep", "finalize"):
            p.add_argument("--source")
        if name == "finalize":
            p.add_argument("--replace-with", required=True)
            p.add_argument("--yes", action="store_true")
            p.add_argument("--allow-dirty", action="store_true")
    args = ap.parse_args(argv)
    fn = {"survey": cmd_survey, "blocks": cmd_blocks, "apply": cmd_apply, "check": cmd_check,
          "keep": cmd_keep, "finalize": cmd_finalize}[args.cmd]
    try:
        return fn(args)
    except Fatal as ex:
        sys.stderr.write("retrofit: %s\n" % ex)
        return 2
    except BrokenPipeError:
        # The reader went away (| head): stop quietly and keep the exit-time flush from complaining.
        os.dup2(os.open(os.devnull, os.O_WRONLY), sys.stdout.fileno())
        return 0
    except (OSError, UnicodeError) as ex:
        sys.stderr.write("retrofit: %s: %s\n" % (type(ex).__name__, ex))
        return 2


if __name__ == "__main__":
    sys.exit(main())
