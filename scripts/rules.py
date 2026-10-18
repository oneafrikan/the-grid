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
        any finding, 0 if clean (an empty rules/ is clean, and so is an absent one
        when the root is the default; an explicit --root without rules/ exits 2).
        Writes nothing. --check-urls also checks every https URL in each pack
        README's Sources table (8 threads, 10 s each; needs network; the gate and the
        tests never pass it).
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
E_PACK_SIZE E_OPINION E_PACK_META E_SOURCES E_ATTRIBUTION E_NAME E_URL E_MARKER
E_ENCODING E_UNREADABLE.

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
import time
import unicodedata

# Never leave a __pycache__ behind (this file is run, not imported, but be safe).
sys.dont_write_bytecode = True

HERE = os.path.dirname(os.path.abspath(__file__))

# --- limits (design.md "Lint checks"; ceilings, not targets) -----------------------
FILE_MAX_BYTES = 4096    # one rule file: a file read pulls in every matching file
PACK_MAX_BYTES = 9216    # all rule files of one pack
BULLET_MAX_CHARS = 240   # one bullet, continuation lines included
FENCE_MAX_LINES = 10     # lines of content inside one fenced block
MAX_BRACE_GROUPS = 2     # {a,b} groups per glob
MAX_ALTERNATIVES = 12    # alternatives in one {a,b,...} group (shipped maximum: 8)
MAX_EXPANDED_GLOBS = 64  # globs one rule file expands to (shipped maximum: 16)
MIN_LITERAL_CHARS = 2    # literal characters the last path segment of a glob must hold
# A header glob is a path pattern, not text: anything else could carry prose into the
# delivered `applies to:` header, so it is refused outright.
GLOB_CHARS_RE = re.compile(r"^[A-Za-z0-9_./*?{},\[\]-]+$")

NAME_RE = re.compile(r"^[a-z0-9]+(-[a-z0-9]+)*$")        # kebab-case, lowercase
TITLE_RE = re.compile(r"^# \S")
HEADING_RE = re.compile(r"^#{2,3} \S")                    # ## and ### only
PATH_LINE_RE = re.compile(r'^  - "([^"]+)"$')             # one frontmatter glob
PACK_KEYS = ("summary", "tier", "adapted_from")           # the only pack.yaml keys
# Every BEGIN/END spelling the managed block has ever carried lives in ONE data file that
# scripts/lib/harness.sh (wire's "is there a block to remove" grep) reads as well, so a
# reword is a one-line edit that neither side can miss. Format: `BEGIN <line>` / `END <line>`,
# `#` comment lines; the FIRST of each kind is the current spelling (written by emit), the
# rest are retired spellings that are still recognised (and removed) in an old block.
MARKERS_FILE = os.path.join(HERE, "lib", "rules-markers.txt")


def load_marker_spellings(path=MARKERS_FILE):
    """Return (begin_spellings, end_spellings) from `path`; exit 2 with one line if unusable.

    Fail loud: a silently empty list would make every block "user text" and stop removal.
    """
    def die(why):
        sys.stderr.write("rules.py: %s: %s\n" % (path, why))
        sys.exit(2)

    try:
        with open(path, encoding="utf-8") as fh:
            lines = fh.read().split("\n")
    except (OSError, UnicodeDecodeError) as exc:
        die("cannot read the marker spellings (%s)" % (getattr(exc, "strerror", None) or exc.__class__.__name__))
    found = {"BEGIN": [], "END": []}
    for no, line in enumerate(lines, start=1):
        if not line.strip() or line.startswith("#"):
            continue
        kind, _, text = line.partition(" ")
        # An HTML comment of printable ASCII: nothing else is a marker shape wire can grep for.
        if kind not in found or not re.match(r"^<!-- [ -~]* -->$", text) or text in found[kind]:
            die("line %d is not a new `BEGIN <!-- ... -->` or `END <!-- ... -->` line" % no)
        found[kind].append(text)
    if not found["BEGIN"] or not found["END"]:
        die("needs at least one BEGIN and one END spelling")
    return tuple(found["BEGIN"]), tuple(found["END"])


BLOCK_BEGIN_HISTORY, BLOCK_END_HISTORY = load_marker_spellings()

# Marker text that must never appear in a rule file: the managed-block BEGIN/END lines
# (line-start test, so prose such as "the-grid rules" is fine) and the .mdc marker token.
# Retired spellings count too: a rule file must not imitate a line an old block was closed with.
MARKER_PREFIXES = (("<!-- BEGIN the-grid rules", "<!-- END the-grid rules")
                   + BLOCK_BEGIN_HISTORY + BLOCK_END_HISTORY)
MARKER_TOKEN = "the-grid:rules"
# Lint findings that stop a pack from being delivered by emit (rule-file checks only:
# pack metadata, Sources and notices findings do not change what a rule file says).
EMIT_BLOCKING_CODES = ("E_FRONTMATTER", "E_PATHS", "E_TITLE", "E_STYLE", "E_FILE_SIZE",
                       "E_OPINION", "E_MARKER", "E_ENCODING", "E_UNREADABLE")
ATTRIBUTION_LINE = "Adapted from affaan-m/ECC (MIT)"
URL_RE = re.compile(r"https://[^\s|)>\]]+")
# A usable Sources URL: https, a dotted host, optional port and path (not just `https://x`).
URL_FULL_RE = re.compile(r"^https://[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}(:[0-9]+)?(/\S*)?$")
# pack.yaml adapted_from: `<owner>/<repo> rules/<pack> @ <sha> (MIT)`.
ADAPTED_RE = re.compile(r"^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+ rules/[A-Za-z0-9._-]+ @ [0-9a-f]{7,40} \(MIT\)$")
URL_WORKERS = 8          # --check-urls: concurrent checks
URL_TIMEOUT = 10         # --check-urls: seconds per request
FENCE_OPEN_RE = re.compile(r"^(\s*)```")
FENCE_CLOSE_RE = re.compile(r"^\s*`{3,}\s*$")


def is_marker_line(line):
    """True for a line that looks like a managed-block marker or carries the .mdc token."""
    return line.lstrip().startswith(MARKER_PREFIXES) or MARKER_TOKEN in line


# Letters and symbols that render as a blank but are NOT whitespace, so NFKC and \s leave them
# alone: the Hangul fillers (NFKC folds U+3164 and U+FFA0 to U+1160) and the braille blank.
BLANK_LOOKALIKES = frozenset(chr(cp) for cp in (0x115F, 0x1160, 0x3164, 0xFFA0, 0x2800))


def is_invisible(ch):
    """True for characters that render as nothing (or reorder text, or look like a blank):
    category Cf (zero-width, bidi controls, BOM, soft hyphen), line/paragraph separators, tag
    characters, variation selectors, the blank look-alikes above and every combining mark
    (Mn/Me: grapheme joiner, Khmer inherent vowels, Mongolian selectors, a stray accent).
    None of them has a place in a rule file."""
    cp = ord(ch)
    return (unicodedata.category(ch) in ("Cf", "Mn", "Me") or cp in (0x2028, 0x2029)
            or ch in BLANK_LOOKALIKES
            or 0xE0000 <= cp <= 0xE007F or 0xFE00 <= cp <= 0xFE0F or 0xE0100 <= cp <= 0xE01EF)


def is_combining_mark(ch):
    """True for a combining mark (Mn/Me) other than a variation selector, which is reported as
    an invisible character. A mark is refused because it either hides (grapheme joiner) or
    decorates a letter so it escapes the denylist; precomposed letters are the way to write
    accents."""
    cp = ord(ch)
    return (unicodedata.category(ch) in ("Mn", "Me")
            and not (0xFE00 <= cp <= 0xFE0F or 0xE0100 <= cp <= 0xE01EF))


def is_control(ch):
    """True for a control character (category Cc: ESC, NUL, DEL, VT, FF, NEL...). A tab is
    layout and stays legal; a newline never reaches a single line."""
    return unicodedata.category(ch) == "Cc" and ch != "\t"


def normalize_for_match(line):
    """Fold a line for denylist matching: NFKC; blank look-alikes become a space (they render
    as a blank, so dropping them would glue two words together); other invisible characters
    and non-whitespace control characters are dropped; whitespace runs (tab, NBSP, VT,
    double space) collapse to one space. So spacing tricks cannot dodge a pattern.
    Mixed-script homoglyphs are NFKC-stable and are caught by mixed_script_words."""
    out = []
    for ch in unicodedata.normalize("NFKC", line):
        if ch in BLANK_LOOKALIKES:
            out.append(" ")
        elif is_invisible(ch) or (is_control(ch) and not ch.isspace()):
            continue
        else:
            out.append(ch)
    return re.sub(r"\s+", " ", "".join(out))


# Scripts with letters that pass for ASCII ones (matched on the Unicode name). Latin and CJK
# are deliberately absent: accented Latin, sharp s, o-slash, l-stroke and CJK text are ordinary.
LOOKALIKE_SCRIPTS = ("CYRILLIC", "GREEK", "ARMENIAN", "CHEROKEE", "COPTIC", "LISU", "OSAGE",
                     "CANADIAN SYLLABICS")
# Latin-script letters that pass for an ASCII one but are not accented forms of it:
# dotless i, Latin alpha, script g, and the small capitals i c o u v w z.
LATIN_LOOKALIKES = frozenset(chr(cp) for cp in (0x0131, 0x0251, 0x0261, 0x026A, 0x1D04, 0x1D0F,
                                                0x1D1C, 0x1D20, 0x1D21, 0x1D22))


def is_lookalike_letter(ch):
    """True for a non-ASCII letter that could pass for an ASCII one inside an ASCII word:
    (a) one NFKC folds to ASCII letters (fullwidth, ligatures, mathematical alphanumerics),
    (b) one of a script with ASCII look-alikes (LOOKALIKE_SCRIPTS), or (c) one of the few
    Latin look-alikes. Everything else (accented Latin, sharp s, o-slash, the micro sign,
    CJK) is ordinary text and is not flagged."""
    if not ch.isalpha() or ord(ch) < 128:
        return False
    folded = unicodedata.normalize("NFKC", ch)
    if folded != ch and folded.isascii() and any(c.isalpha() for c in folded):
        return True
    return unicodedata.name(ch, "").startswith(LOOKALIKE_SCRIPTS) or ch in LATIN_LOOKALIKES


def mixed_script_words(line):
    """Words that mix ASCII letters with look-alike letters of another script (spoofing)."""
    out = []
    for word in re.findall(r"\w+", line):
        if not any("a" <= c.lower() <= "z" for c in word):
            continue
        if any(is_lookalike_letter(c) for c in word):
            out.append(word)
    return out


def safe_lines(path):
    """Strictly decoded lines of `path`: (lines, None) or (None, (code, message)).

    code is MISSING for an absent file (callers decide whether that is a finding),
    E_ENCODING for bytes that are not UTF-8, E_UNREADABLE for any other OS error.
    """
    try:
        return read_lines(path), None
    except UnicodeDecodeError:
        return None, ("E_ENCODING", "not valid UTF-8")
    except FileNotFoundError:
        return None, ("MISSING", "is missing")
    except OSError as exc:
        return None, ("E_UNREADABLE", "cannot read: %s" % (exc.strerror or exc.__class__.__name__))


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


def literal_chars(segment):
    """Literal characters a glob path segment must match: `[...]`, `*` and `?` count 0 and a
    `{a,b}` group counts as its shortest alternative (so `*.{ts,tsx}` holds 3, `**/*e*` 1)."""
    def shortest(m):
        alts = [re.sub(r"\[[^\]]*\]|[*?]", "", a) for a in m.group(1).split(",")]
        return min(alts, key=len)
    segment = re.sub(r"\{([^{}]*)\}", shortest, segment)
    return len(re.sub(r"\[[^\]]*\]|[*?{},\[\]]", "", segment))


def expanded_count(glob):
    """How many globs `{a,b}` expansion makes of `glob` (the product of the group sizes)."""
    n = 1
    for group in re.findall(r"\{([^{}]*)\}", glob):
        n *= len(group.split(","))
    return n


def check_glob(glob):
    """Return a list of problems with one paths glob (empty list = fine)."""
    if not GLOB_CHARS_RE.match(glob):
        return ["glob %r has characters outside [A-Za-z0-9_./*?{},[]-]" % glob]
    problems = []
    # Brace limits: no nesting, no empty alternative, bounded groups and alternatives.
    # A nested or unbalanced glob is reported once and not examined further.
    depth, groups, cur = 0, 0, ""
    for ch in glob:
        if ch == "{":
            if depth:
                return ["glob %r has nested braces" % glob]
            depth, groups, cur = 1, groups + 1, ""
        elif ch == "}":
            if not depth:
                return ["glob %r has unbalanced braces" % glob]
            depth = 0
            alts = cur.split(",")
            if any(a == "" for a in alts):
                problems.append("glob %r has an empty brace alternative" % glob)
            if len(alts) > MAX_ALTERNATIVES:
                problems.append("glob %r has a brace group with %d alternatives (max %d)"
                                % (glob, len(alts), MAX_ALTERNATIVES))
        elif depth:
            cur += ch
    if depth:
        return ["glob %r has unbalanced braces" % glob]
    if groups > MAX_BRACE_GROUPS:
        problems.append("glob %r has more than %d brace groups" % (glob, MAX_BRACE_GROUPS))
    segs = glob.split("/")
    if glob.startswith("/"):
        problems.append("absolute glob %r" % glob)
    if ".." in segs:
        problems.append("glob %r has a .. path segment" % glob)
    # Too broad: the last path segment must hold at least MIN_LITERAL_CHARS literal
    # characters, so `*`, `**/*.*`, `**/[a-z]*`, `**/{*,x}` and `**/*e*` (which would load
    # the rule on nearly every file) are rejected. A directory scope (`src/**`,
    # `**/migrations/**`) is the one allowed shape ending in a wildcard: its directory
    # segment must be a plain name with at least MIN_LITERAL_CHARS characters.
    is_dir_scope = (segs[-1] == "**" and len(segs) >= 2 and len(segs[-2]) >= MIN_LITERAL_CHARS
                    and not re.search(r"[*?\[\]{},]", segs[-2]))
    if not is_dir_scope and literal_chars(segs[-1]) < MIN_LITERAL_CHARS:
        problems.append("glob %r matches nearly every file (last segment needs %d literal characters)"
                        % (glob, MIN_LITERAL_CHARS))
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
    in_tilde = False         # inside a ~~~ fence (reported once at its opening line)
    fence_open_line = 0
    fence_len = 0
    saw_bullet = False
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
        if in_tilde:
            in_tilde = not line.strip().startswith("~~~")
            continue
        if in_fence:
            # A closing line is backticks only; "```python" inside a fence is content.
            if FENCE_CLOSE_RE.match(line):
                in_fence = False
                if fence_len > FENCE_MAX_LINES:
                    out.append((fence_open_line, "fenced block is %d lines (max %d)" % (fence_len, FENCE_MAX_LINES)))
            else:
                fence_len += 1
            continue
        fence = FENCE_OPEN_RE.match(line)
        if fence and (not fence.group(1) or bullet_open):
            # A top-level fence ends any bullet; an indented one inside a bullet is part of it.
            if not fence.group(1):
                close_bullet()
                bullet_open, bullet_text = False, []
            in_fence, fence_open_line, fence_len = True, lineno, 0
        elif line.lstrip().startswith("~~~") and (not line.startswith(" ") or bullet_open):
            out.append((lineno, "`~~~` fence: use ``` fences"))
            in_tilde = True
        elif line.strip() == "":
            close_bullet()
            bullet_open, bullet_text = False, []
        elif line.startswith("- "):
            close_bullet()
            saw_bullet = True
            if not line[2:].strip():
                out.append((lineno, "empty bullet"))
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
    if not saw_bullet:
        out.append((max(start, 1), "no bullets: a rule file needs at least one `- ` directive"))
    return out


# --- pack.yaml / README / notices readers -------------------------------------------
def read_pack_yaml(path):
    """Strict flat `key: value` reader. Returns (dict, [(code, problem)])."""
    data, problems = {}, []
    raw, err = safe_lines(path)
    if err:
        # A missing file is an E_PACK_META problem; a bad encoding / unreadable file keeps its own code.
        return data, [("E_PACK_META", "pack.yaml is missing")] if err[0] == "MISSING" else [(err[0], "pack.yaml: " + err[1])]
    for i, line in enumerate(raw, start=1):
        text = line.strip()
        if not text or text.startswith("#"):
            continue
        # Strip a trailing comment: two or more spaces then `#` (the documented form), so a
        # value such as `C# and F # here` survives whole.
        text = re.split(r"\s{2,}#", text, maxsplit=1)[0]
        m = re.match(r"^([a-z_]+):\s*(.*)$", text)
        if not m:
            problems.append(("E_PACK_META", "line %d is not `key: value`" % i))
            continue
        key, val = m.group(1), m.group(2).strip()
        if key not in PACK_KEYS:
            problems.append(("E_PACK_META", "line %d: unknown key %r (allowed: %s)" % (i, key, ", ".join(PACK_KEYS))))
        elif key in data:
            problems.append(("E_PACK_META", "line %d: duplicate key %r" % (i, key)))
        else:
            data[key] = val
    return data, problems


def extract_urls(text):
    """https URLs in `text`, minus the sentence punctuation that trails them."""
    return [u.rstrip(".,;:") for u in URL_RE.findall(text)]


def sources_rows(readme_lines):
    """Rows of the README's `## Sources` table: (has_heading, [(rule file, [urls])]).

    Only lines under the `## Sources` heading (up to the next heading) count, so a table
    elsewhere in the README cannot satisfy the requirement. The header and separator rows
    are not data rows.
    """
    rows, in_sources, has_heading = [], False, False
    for line in readme_lines:
        if re.match(r"^#{1,6} ", line):
            in_sources = line.strip() == "## Sources"
            has_heading = has_heading or in_sources
            continue
        if not in_sources or not line.startswith("|"):
            continue
        cells = [c.strip().strip("`") for c in line.strip().strip("|").split("|")]
        if not cells or cells[0].lower() == "rule file" or all(re.match(r"^:?-+:?$", c) for c in cells):
            continue
        rows.append((cells[0], extract_urls(line)))
    return has_heading, rows


def notices_adapted_packs(path):
    """Pack names listed under `Adapted packs` in THIRD_PARTY_NOTICES.txt: (names, error).

    The list ends at the next heading (a line underlined with dashes) or at the first
    line that is not a pack name. `error` is None, or a (code, message) when the file is
    not UTF-8 or cannot be read (an absent file just lists nothing).
    """
    names, active = set(), False
    lines, err = safe_lines(path)
    if err:
        return names, (None if err[0] == "MISSING" else err)
    for i, line in enumerate(lines):
        text = line.strip()
        if text == "Adapted packs":
            active = True
            continue
        if not active or not text or text.startswith("#") or set(text) <= {"-", "="}:
            continue
        under = lines[i + 1].strip() if i + 1 < len(lines) else ""
        if len(under) >= 3 and set(under) <= {"-", "="}:
            break                                   # the next heading
        name = text[2:].strip() if text.startswith("- ") else text
        if not NAME_RE.match(name):
            break                                   # prose, not a pack name: the list is over
        names.add(name)
    return names, None


def load_denylist(path):
    """Compile rules/denylist.txt (one regex per line, # comments). Returns (list, [(code, error)])."""
    pats, errs = [], []
    raw, err = safe_lines(path)
    if err:
        return pats, [("E_OPINION", "denylist.txt is missing")] if err[0] == "MISSING" else [(err[0], "denylist.txt: " + err[1])]
    for i, line in enumerate(raw, start=1):
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        try:
            pats.append((line, re.compile(line, re.IGNORECASE)))
        except re.error as exc:
            errs.append(("E_OPINION", "line %d: bad regex (%s)" % (i, exc)))
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
    # Strict decoding: a replacement character would let a bad byte pass lint and then be
    # silently rewritten by emit. Callers turn UnicodeDecodeError into a finding or a refusal.
    with open(path, encoding="utf-8") as fh:
        return fh.read().split("\n")


def lint_rule_file(rel, path, denylist, f):
    """All per-file checks for one rule file. Returns its size in bytes."""
    try:
        size = os.path.getsize(path)
    except OSError as exc:
        f.add("E_UNREADABLE", rel, "cannot read: %s" % (exc.strerror or exc.__class__.__name__))
        return 0
    if size > FILE_MAX_BYTES:
        # Oversize: say so once and stop (no read of a possibly huge file, no cascade).
        f.add("E_FILE_SIZE", rel, "%d bytes (max %d)" % (size, FILE_MAX_BYTES))
        return size
    lines, err = safe_lines(path)
    if err:
        f.add(err[0], rel, err[1])
        return size

    # A BOM is fixed at the source, so it gets its own message rather than a generic
    # "missing frontmatter" (and is not reported again as an invisible character).
    bom = lines[0][:1] == "\ufeff"
    if bom:
        globs, body, problem = [], 0, "file starts with a UTF-8 byte order mark (BOM); remove it so `---` is the first line"
    else:
        globs, body, problem = parse_frontmatter(lines)
    if problem:
        f.add("E_FRONTMATTER", rel, problem)
    elif not globs:
        f.add("E_PATHS", rel, "paths: list is empty")
    glob_clean = []
    for g in globs:
        gp = check_glob(g)
        for p in gp:
            f.add("E_PATHS", rel, p)
        if not gp:
            glob_clean.append(g)
    # The whole file's expansion is bounded too: emit writes every expanded glob into one .mdc.
    expanded = sum(expanded_count(g) for g in glob_clean)
    if expanded > MAX_EXPANDED_GLOBS:
        f.add("E_PATHS", rel, "paths expand to %d globs (max %d)" % (expanded, MAX_EXPANDED_GLOBS))

    # Title and body shape are only judged when the frontmatter is sound: with a broken one
    # every later line is "wrong", which would bury the one real defect under a cascade.
    if not problem:
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

    # Hidden text, on every line of the file (frontmatter and fences included): an HTML
    # comment hides text from a rendered view, an invisible character hides it from any view,
    # and a look-alike letter of another script inside an ASCII word dodges the denylist.
    for i, line in enumerate(lines, start=1):
        if "<!--" in line or "-->" in line:
            f.add("E_STYLE", rel, "line %d: HTML comment markers are not allowed" % i)
        scan = line[1:] if (bom and i == 1) else line     # the BOM has its own finding
        hidden = sorted(set("U+%04X" % ord(ch) for ch in scan
                            if is_invisible(ch) and not is_combining_mark(ch)))
        if hidden:
            f.add("E_STYLE", rel, "line %d: invisible character %s" % (i, ", ".join(hidden)))
        marks = sorted(set("U+%04X" % ord(ch) for ch in scan if is_combining_mark(ch)))
        if marks:
            f.add("E_STYLE", rel, "line %d: combining mark %s (use the precomposed letter)"
                  % (i, ", ".join(marks)))
        # Control characters (ESC sequences can conceal text in a terminal view) are refused
        # outright; a tab is layout and stays legal.
        ctl = sorted(set("U+%04X" % ord(ch) for ch in scan if is_control(ch)))
        if ctl:
            f.add("E_STYLE", rel, "line %d: control character %s" % (i, ", ".join(ctl)))
        for word in mixed_script_words(line):
            f.add("E_STYLE", rel, "line %d: word %r mixes ASCII letters with a confusable non-ASCII letter" % (i, word))

    # Marker text anywhere (fenced or not) would corrupt the managed block or the .mdc
    # generated-file detection once delivered, so it is refused at the source.
    for i, line in enumerate(lines, start=1):
        if is_marker_line(line):
            f.add("E_MARKER", rel, "line %d carries the-grid marker text" % i)

    # Denylist is searched per normalised line (so ^ anchors work and spacing tricks fold
    # away), first matching pattern only.
    for i, line in enumerate(lines, start=1):
        norm = normalize_for_match(line)
        for pat, rx in denylist:
            if rx.search(norm):
                f.add("E_OPINION", rel, "line %d matches denylist pattern %s" % (i, pat))
                break
    return size


def _http(url, method, timeout):
    """One request: (None, status) when the URL resolves, else (error string, status or None)."""
    import urllib.error
    import urllib.request
    req = urllib.request.Request(url, method=method, headers={"User-Agent": "the-grid-rules-lint"})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return (None if resp.status < 400 else "HTTP %d" % resp.status), resp.status
    except urllib.error.HTTPError as exc:
        if 300 <= exc.code < 400:
            return None, exc.code           # a redirect with no usable Location: the URL exists
        return "HTTP %d" % exc.code, exc.code
    except Exception as exc:  # network/DNS/TLS/timeout: report, never crash the lint
        return "%s" % exc, None


def check_url(url, timeout=URL_TIMEOUT, pause=2):
    """Check one URL. Returns an error string, or None when it resolves (2xx/3xx).

    HEAD first; any HEAD failure (many servers answer HEAD with 403/405/5xx or time out)
    is retried with GET. A GET that ends in 429 or 5xx is retried once after `pause` s.
    """
    err = None
    for method in ("HEAD", "GET"):
        err, code = _http(url, method, timeout)
        if err is None:
            return None
        if method == "GET" and code is not None and (code == 429 or code >= 500):
            time.sleep(pause)
            err, code = _http(url, "GET", timeout)
            if err is None:
                return None
    return err


def lint(root, check_urls=False):
    f = Findings()
    base = rules_dir(root)
    packs = list_packs(root)
    denylist, deny_errs = ([], [])
    if packs:
        # Fail closed: with packs present, a missing or broken denylist is a finding.
        denylist, deny_errs = load_denylist(os.path.join(base, "denylist.txt"))
        for code, e in deny_errs:
            f.add(code, "rules/denylist.txt", e)
        if not deny_errs and not denylist:
            # An empty denylist would pass every opinion: with packs present that fails closed.
            f.add("E_OPINION", "rules/denylist.txt", "denylist has no patterns")
    adapted, notices_err = notices_adapted_packs(os.path.join(base, "THIRD_PARTY_NOTICES.txt"))
    if notices_err:
        f.add(notices_err[0], "rules/THIRD_PARTY_NOTICES.txt", notices_err[1])

    tiers = {}          # pack -> tier string (for the notices cross-check)
    outputs = {}        # generated .mdc name -> first rule file that makes it
    url_jobs = []       # (README path, url) pairs for --check-urls, checked together at the end
    for pack in packs:
        pdir = os.path.join(base, pack)
        prel = "rules/" + pack
        if not NAME_RE.match(pack):
            f.add("E_NAME", prel, "pack name must be lowercase kebab-case")

        # Every entry must be pack.yaml, README.md or a lowercase kebab-case .md rule.
        for name in sorted(os.listdir(pdir)):
            full = os.path.join(pdir, name)
            if os.path.islink(full) and not os.path.exists(full):
                f.add("E_NAME", prel + "/" + name, "dangling symlink")
            elif os.path.isdir(full):
                f.add("E_NAME", prel + "/" + name, "unexpected directory (rule files are flat)")
            elif name in ("pack.yaml", "README.md"):
                continue
            elif not name.endswith(".md"):
                f.add("E_NAME", prel + "/" + name, "unexpected file (a pack holds pack.yaml, README.md and .md rule files)")
            elif name[:-3].lower() == "readme":
                f.add("E_NAME", prel + "/" + name, "`readme` is a reserved topic name (README.md is never a rule)")
            elif not NAME_RE.match(name[:-3]):
                f.add("E_NAME", prel + "/" + name, "rule file name must be lowercase kebab-case")

        rule_files = pack_rule_files(pdir)
        if not rule_files:
            f.add("E_PACK_META", prel, "pack has no rule files")
        for name in rule_files:
            # `a-b` + `c.md` and `a` + `b-c.md` would both write grid-a-b-c.mdc for Cursor.
            out_name = "grid-%s-%s.mdc" % (pack, name[:-3])
            if out_name in outputs:
                f.add("E_NAME", prel + "/" + name, "Cursor output %s collides with %s" % (out_name, outputs[out_name]))
            else:
                outputs[out_name] = "%s/%s" % (prel, name)
        total, oversize = 0, False
        for name in rule_files:
            sz = lint_rule_file("%s/%s" % (prel, name), os.path.join(pdir, name), denylist, f)
            total += sz
            oversize = oversize or sz > FILE_MAX_BYTES
        # A pack that is over because one file is already flagged E_FILE_SIZE is one defect.
        if total > PACK_MAX_BYTES and not oversize:
            f.add("E_PACK_SIZE", prel, "%d bytes across %d rule files (max %d)" % (total, len(rule_files), PACK_MAX_BYTES))

        # pack.yaml
        meta, problems = read_pack_yaml(os.path.join(pdir, "pack.yaml"))
        for code, p in problems:
            f.add(code, prel + "/pack.yaml", p)
        tier = meta.get("tier")
        tiers[pack] = tier
        # Missing, undecodable or unreadable: already reported above, so skip the field checks.
        yaml_absent = any(c != "E_PACK_META" or p == "pack.yaml is missing" for c, p in problems)
        if not yaml_absent and not meta.get("summary"):
            f.add("E_PACK_META", prel + "/pack.yaml", "summary is missing or empty")
        if yaml_absent:
            pass
        elif tier not in ("1", "2"):
            f.add("E_PACK_META", prel + "/pack.yaml", "tier must be 1 or 2, got %r" % tier)
        elif tier == "2" and not meta.get("adapted_from"):
            f.add("E_PACK_META", prel + "/pack.yaml", "tier 2 requires adapted_from")
        elif tier == "2" and not ADAPTED_RE.match(meta["adapted_from"]):
            f.add("E_PACK_META", prel + "/pack.yaml",
                  "adapted_from must read `<owner>/<repo> rules/<pack> @ <sha> (MIT)`")
        elif tier == "1" and meta.get("adapted_from"):
            f.add("E_PACK_META", prel + "/pack.yaml", "adapted_from is only allowed on tier 2")

        # README: Sources table (every rule file needs a row with an https URL).
        readme = os.path.join(pdir, "README.md")
        if not os.path.isfile(readme):
            f.add("E_SOURCES", prel + "/README.md", "README.md is missing")
            rlines = []
        else:
            rlines, rerr = safe_lines(readme)
            if rerr:
                f.add(rerr[0], prel + "/README.md", rerr[1])
                rlines = []
            else:
                has_heading, rows = sources_rows(rlines)
                good_urls = {}
                if not has_heading:
                    f.add("E_SOURCES", prel + "/README.md", "README.md has no `## Sources` section")
                for name, urls in rows:
                    if name not in rule_files:
                        f.add("E_SOURCES", prel + "/README.md", "Sources row names %s, which is not a rule file of this pack" % name)
                    for u in urls:
                        if not URL_FULL_RE.match(u):
                            f.add("E_SOURCES", prel + "/README.md", "malformed URL %s (need https://host.tld/...)" % u)
                    good_urls.setdefault(name, []).extend(u for u in urls if URL_FULL_RE.match(u))
                if has_heading:
                    row_names = set(n for n, _ in rows)
                    for name in rule_files:
                        # A row that only holds a malformed URL was reported above; say it once.
                        has_any = any(u for n, us in rows if n == name for u in us)
                        if name not in row_names or not has_any:
                            f.add("E_SOURCES", prel + "/README.md", "no Sources row with an https:// URL for %s" % name)
                if check_urls:
                    for name in sorted(good_urls):
                        for url in sorted(set(good_urls[name])):
                            url_jobs.append((prel + "/README.md", url))

        # Attribution for tier 2 (adapted) packs.
        if tier == "2":
            if rlines and not any(ATTRIBUTION_LINE in ln for ln in rlines):
                f.add("E_ATTRIBUTION", prel + "/README.md", "missing the line `%s`" % ATTRIBUTION_LINE)
            if pack not in adapted:
                f.add("E_ATTRIBUTION", "rules/THIRD_PARTY_NOTICES.txt",
                      "pack %s is not listed under `Adapted packs`" % pack)

    # The notices list is checked the other way too: every name must be a real tier 2 pack.
    if packs or adapted:
        for name in sorted(adapted):
            if name not in tiers:
                f.add("E_ATTRIBUTION", "rules/THIRD_PARTY_NOTICES.txt",
                      "%s is listed under `Adapted packs` but rules/%s does not exist" % (name, name))
            elif tiers[name] != "2":
                f.add("E_ATTRIBUTION", "rules/THIRD_PARTY_NOTICES.txt",
                      "%s is listed under `Adapted packs` but %s is not a tier 2 pack" % (name, name))

    if url_jobs:
        # Bounded concurrency (not a global time budget, which would hide unchecked URLs);
        # map keeps the findings in job order, so the output stays deterministic.
        from concurrent.futures import ThreadPoolExecutor
        with ThreadPoolExecutor(max_workers=URL_WORKERS) as pool:
            for (rel, url), err in zip(url_jobs, pool.map(lambda job: check_url(job[1]), url_jobs)):
                if err:
                    f.add("E_URL", rel, "%s -> %s" % (url, err))
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


# Plain scalars that YAML 1.1 loads as something other than a string.
_YAML_WORDS = frozenset(["y", "n", "yes", "no", "true", "false", "on", "off", "null", "~",
                         ".inf", "-.inf", "+.inf", ".nan"])
_YAML_TYPED_RES = [re.compile(p) for p in (
    r"^[-+]?(\.[0-9]+|[0-9][0-9_]*(\.[0-9_]*)?)([eE][-+]?[0-9]+)?$",   # int / float
    r"^[-+]?0x[0-9a-fA-F_]+$", r"^[-+]?0o?[0-7_]+$", r"^[-+]?0b[01_]+$",  # hex / octal / binary
    r"^[-+]?[0-9][0-9_]*(:[0-5]?[0-9])+(\.[0-9_]*)?$",                    # sexagesimal
    r"^[0-9]{4}-[0-9]{2}-[0-9]{2}([Tt ].*)?$",                            # date / timestamp
)]


def yaml_scalar(text):
    """Render a one-line frontmatter value: bare when plainly safe, else JSON-quoted.

    A title such as `Style: naming` or `Use # sparingly` would break an unquoted
    YAML scalar, a tab is not allowed in one, and a title such as `No`, `123` or
    `2024-01-01` would load as a bool, number or date; so quote (JSON strings are
    valid YAML) whenever any of that could happen.
    """
    if (re.search(r"(^[^A-Za-z0-9])|(: )|( #)|(:$)|\t", text) or text.lower() in _YAML_WORDS
            or any(rx.match(text) for rx in _YAML_TYPED_RES)):
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
    out_globs, seen = [], set()
    for g in globs:
        for e in expand_braces(g):
            if e not in seen:             # duplicates dropped, first occurrence wins
                seen.add(e)               # (a set keeps this linear, not quadratic)
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
    try:
        lines = read_lines(path)
    except (UnicodeDecodeError, OSError):
        return False                      # not decodable / not readable: not ours to touch
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
# The spellings come from scripts/lib/rules-markers.txt (loaded at the top): the first of each
# is the one emit writes.
BLOCK_BEGIN = BLOCK_BEGIN_HISTORY[0]
BLOCK_END = BLOCK_END_HISTORY[0]
BLOCK_INTRO = ("## Coding rules (the-grid)\n\n"
               "Apply each rule only when working on files matching its globs.\n")
# Marker lines are matched as COMPLETE lines (optional trailing CR), never by prefix: a user
# note that merely starts like a marker is user text, not ours. Every BEGIN/END spelling
# ever shipped is listed in rules-markers.txt (BLOCK_*_HISTORY) so a future rewording keeps
# migrating old blocks. Bytes, because the file is handled as raw bytes.


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
        # Say which half is missing: a lone END usually means the BEGIN line was edited or
        # deleted by hand (wire.sh keys its warning on the leading "expected exactly one BEGIN").
        if not begins:
            hint = "found an END line but no BEGIN line (was the BEGIN line edited or deleted?): " \
                   "restore it or delete the stray END line by hand"
        elif not ends:
            hint = "found a BEGIN line but no END line: restore the END line or delete the block by hand"
        else:
            hint = "fix the markers by hand"
        raise Refusal("%s: expected exactly one BEGIN and one END marker, BEGIN first "
                      "(found %d BEGIN, %d END); %s" % (out, len(begins), len(ends), hint))
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
    denylist = []
    if any(NAME_RE.match(p) and os.path.isdir(os.path.join(base, p)) for p in packs):
        # Fail closed, as lint does: with a pack to deliver, a missing, empty or partly broken
        # denylist must stop delivery, not quietly turn the opinion check off. (Removal, the
        # empty selection, delivers nothing and needs no denylist.)
        denylist, deny_errs = load_denylist(deny_path)
        problems = [msg for _, msg in deny_errs] or ([] if denylist else ["denylist has no patterns"])
        if problems:
            raise Refusal("rules/denylist.txt cannot be used (%s); nothing delivered (run `rules.py lint`)"
                          % "; ".join(problems))
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
    except (Refusal, OSError, UnicodeDecodeError) as exc:
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
    except (OSError, UnicodeDecodeError) as exc:
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
    except (OSError, UnicodeDecodeError) as exc:
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
    # An explicit --root is a promise that rules/ is there: a typo must not read as "clean".
    # (The default root and GRID_DIR, as the gate uses them, stay clean without rules/.)
    if args.cmd in ("lint", "list") and args.root and not os.path.isdir(rules_dir(root)):
        sys.stderr.write("rules.py: rules/ not found under %s\n" % args.root)
        return 2

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
