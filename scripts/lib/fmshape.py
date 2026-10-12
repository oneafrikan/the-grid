"""fmshape - a reader-independent SHAPE WHITELIST for the frontmatter of SKILL.md / agent .md.

Python 3 standard library only; no regex with nested quantifiers (every check is a per-line
string operation or a single-character-class scan, so cost is linear in the frontmatter).

Why: the vetting scanner (scripts/audit.py) must catch a `hooks` declaration in a frontmatter
written by an UNTRUSTED upstream author, but Claude Code does not read frontmatter the way any
one YAML parser does. Its reader cuts the text at the FIRST `---` anywhere, parses it with a
strict YAML parser and, when that throws, REPAIRS the text line by line (quoting some values)
and parses again. Every round of "model the reader" (a line scanner, then a YAML scanner)
was bypassed by a spelling the model did not share with the real reader. So this module does
not model a reader. It accepts a frontmatter ONLY if every line fits a deliberately tiny
grammar that every YAML reader, the repair path included, reads identically; anything else is
a finding (`frontmatter-complex`) that an allowlist entry has to pin, line by line.

The grammar (`key` is [A-Za-z][A-Za-z0-9_.-]*, top-level keys at column 0):
  1. `key: value`      value = one-line plain scalar, `[]`, or a one-line single/double quoted
                       scalar (no embedded quote of its own kind; in double quotes only the
                       escapes `\\"` and `\\\\`). A plain scalar does not start with a YAML
                       indicator (`[ ] { } & * ! | > ' " % @ ` # , ? :` or `- `), has no `: ` or
                       ` #` inside and does not end with `:`.
     A plain scalar may continue on indented lines that follow the same plain rules.
  2. `key: |` / `>` (+ optional `-` / `+`), then body lines indented more than the key. The body
                       is free text, never keys; it ends at the first non-blank column-0 line,
                       and its lines may not be indented less than its first line.
  3. `key:` (bare), then indented or `- ` lines: `- item`, `- sub: value`, `sub: value`, `sub:`,
                       or a whole-line `# comment`. Each is one line with a scalar as in 1 and no key named `hooks`: nothing
                       there can open a multi-line construct, an anchor, an alias or a tag.
  4. blank lines.
  5. the top-level `hooks:` key (bare) with its indented block. Each indented line must read
     `[- ]key:` or `[- ]key: <anything>`; what the lines MEAN is decided by the deny-by-default
     hooks judging in audit.py (this module only keeps the block line-oriented).
Not accepted (each is a finding): flow collections (`[` `{`) other than `[]`, anchors, aliases,
tags, `?` keys, directives, comments, multi-line quoted or plain scalars, other escapes, tabs,
`<<`, duplicate keys, control / invisible characters, an unterminated frontmatter, and any
`---` inside the frontmatter beyond the two fences (Claude's reader ends the text at the first
one, mid-line or not).

API
  check(text) -> Shape | None    text = the whole file, decoded; None when it has no frontmatter
  Shape.violations   [(line_index, message)]  0-based index into the file's lines
  Shape.lines        the frontmatter's lines (between the fences); lines[0] is file line 1
  Shape.word_lines   file line indexes holding the whole word `hooks` (case-sensitive)
"""
import re

MAX_BYTES = 131072          # a frontmatter larger than this is a finding (a real one is < 4 KiB)
MAX_VIOLATIONS = 64         # report at most this many; the rest are one summary entry
MAX_NEST_INDENT = 12

# JavaScript's `\s` (what Claude's `RE` uses), written out: Python's differs (it has \x1c-\x1f
# and \x85, not ﻿).
_JS_WS = frozenset("\t\n\v\f\r           "
                   "       　﻿")
# Characters no frontmatter line may carry: C0/C1 controls (tab and bare CR included),
# NBSP-like spaces, zero-width and bidi controls, line/paragraph separators, BOM. One class.
_BAD_CHAR = re.compile("[\x00-\x1f\x7f-\x9f   -‏ -  -⁤　﻿]")
_HOOKS_WORD = re.compile(r"(?<![A-Za-z0-9_])hooks(?![A-Za-z0-9_])")
_KEY_START = frozenset("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz")
_KEY_CHARS = _KEY_START | frozenset("0123456789_.-")
_BLOCK_HEADERS = frozenset(("|", "|-", "|+", ">", ">-", ">+"))
_PLAIN_BAD_START = frozenset("[]{}&*!|>%@`#,?:'\"")


class Shape:
    def __init__(self):
        self.violations = []
        self.lines = []
        self.word_lines = []

    def words(self, idx, text):
        """Record line `idx` when `text` (the part of it that could be a key) holds the whole
        word `hooks`. The value of a line that passed the grammar is not searched: the grammar
        guarantees a value is one closed scalar, never a key (no anchor, alias, tag, flow or
        multi-line construct), so a description that merely mentions hooks is not a finding."""
        if _HOOKS_WORD.search(text) and (not self.word_lines or self.word_lines[-1] != idx):
            self.word_lines.append(idx)

    def bad(self, idx, msg):
        if len(self.violations) < MAX_VIOLATIONS:
            self.violations.append((idx, msg))
        elif len(self.violations) == MAX_VIOLATIONS:
            self.violations.append((idx, "more frontmatter lines outside the allowed shape (not listed)"))

    def bad_if(self, idx, why, text=""):
        """Record a violation; `text` (the whole line) is also searched for the word `hooks`."""
        if why:
            self.bad(idx, why)
            self.words(idx, text)


def _claude_cut(text):
    """(start, end) offsets, in `text` minus one leading BOM, of the frontmatter Claude's own
    reader extracts: /^---\\s*\\n([\\s\\S]*?)---\\s*\\n?/ after a single leading BOM is dropped.
    None when it matches nothing. String code, not a regex, so a hostile whitespace run
    cannot backtrack."""
    if text[:1] == "﻿":
        text = text[1:]
    if text[:3] != "---":
        return None
    n = len(text)
    j = 3
    while j < n and text[j] in _JS_WS:      # the greedy `\s*`
        j += 1
    k = text.rfind("\n", 3, j)              # ... backtracked to the last newline inside the run
    if k < 0:
        return None
    start = k + 1
    end = text.find("---", start)           # the lazy group ends at the FIRST `---` anywhere
    if end < 0:
        return None
    return start, end


def _scalar_problem(v):
    """None when `v` (text after `key: ` or `- `) is an allowed one-line scalar, else why not."""
    v = v.strip(" ")
    if not v:
        return "empty value"
    if v == "[]":
        return None                                     # an empty flow list holds nothing
    if v[0] in "\"'":
        q = v[0]
        if len(v) < 2 or v[-1] != q:
            return "quoted scalar that does not end on this line"
        inner = v[1:-1]
        if q == '"':
            # Only the two escapes that keep a quote or a backslash inside a VALUE: they cannot
            # spell a key (keys are never quoted) and every reader decodes them the same way.
            inner = inner.replace("\\\\", "").replace('\\"', "")
            if "\\" in inner:
                return "escape in a double-quoted scalar"
        if q in inner:
            return "embedded quote in a quoted scalar"
        return None
    if v[0] in _PLAIN_BAD_START:
        return "value starts with the YAML indicator %r" % v[0]
    if v[0] == "-" and (len(v) == 1 or v[1] == " "):
        return "value starts with an indicator"
    if ": " in v or " #" in v or v[-1] == ":":
        return "plain scalar with `: ` or ` #` inside"
    return None


def _key_split(body):
    """(key, rest-after-colon) for `key:` / `key: value`, else None."""
    if not body or body[0] not in _KEY_START:
        return None
    i = 1
    n = len(body)
    while i < n and body[i] in _KEY_CHARS:
        i += 1
    if i >= n or body[i] != ":" or (i + 1 < n and body[i + 1] != " "):
        return None
    return body[:i], body[i + 1:]


def _hooks_line_ok(body):
    """A line inside the hooks block: optional `- `, then `key:` or `key: anything`."""
    if body.startswith("- "):
        body = body[2:].lstrip(" ")
    return _key_split(body) is not None


def _nest_problem(stripped):
    """(why, key_part) for `stripped` (an indented / `- ` line under a bare key): why is the
    reason it is not allowed or None; key_part is the text before its value (the part that
    could be a key)."""
    if stripped.startswith("-"):
        stripped = stripped[1:].lstrip(" ")
        if not stripped:
            return "empty list item", ""
    kv = _key_split(stripped)
    if kv is None:
        return _scalar_problem(stripped), ""            # a plain `- item`
    if kv[0] == "hooks":
        return "key `hooks` below the top level", kv[0]
    rest = kv[1].strip(" ")
    return (_scalar_problem(rest) if rest else None), kv[0]


def check(text):
    """Shape of the frontmatter of the file `text`, or None when the file has none."""
    after_bom = text[1:] if text[:1] == "﻿" else text
    cut = _claude_cut(text)
    raw_lines = after_bom.split("\n")
    # Claude has a frontmatter, or the scanner's own reader (audit.py / fmyaml) would see one.
    scanner_fm = text.lstrip("﻿").split("\n", 1)[0].strip() == "---"
    if cut is None and not scanner_fm:
        return None
    sh = Shape()
    if cut is not None and raw_lines[0].rstrip("\r") != "---":
        sh.bad(0, "opening fence is not a bare `---` line")
    # The lines after the opening fence up to the first column-0 fence (the scanner's cut).
    close = None
    for i in range(1, len(raw_lines)):
        t = raw_lines[i].rstrip("\r")
        if t.startswith("---") and t[3:].strip(" \t") == "":
            close = i
            break
    body = raw_lines[1:close] if close is not None else raw_lines[1:]
    if cut is not None:
        end = cut[1]
        # Claude's cut must end exactly where a column-0 fence line begins; otherwise a `---`
        # sits inside the text (mid-line or in a value) and the two readers see different texts.
        eol = after_bom.find("\n", end)
        tail = after_bom[end + 3:eol if eol >= 0 else len(after_bom)]
        if not ((end == 0 or after_bom[end - 1] == "\n") and tail.strip(" \t\r") == ""):
            sh.bad(after_bom.count("\n", 0, end), "`---` inside the frontmatter ends Claude's reader early")
    if close is None:
        sh.bad(len(raw_lines) - 1, "frontmatter has no closing --- fence")
    lines = [b[:-1] if b.endswith("\r") else b for b in body]
    if sum(len(b) + 1 for b in lines) > MAX_BYTES:
        sh.bad(1, "frontmatter larger than %d bytes" % MAX_BYTES)
        return sh
    sh.lines = lines
    _grammar(sh, lines)
    return sh


def _grammar(sh, lines):
    seen = set()
    mode = "top"            # top | plain | nest | block | hooks
    block_min = None

    def fail(idx, why, line):
        sh.bad(idx, why)
        sh.words(idx, line)                             # a violating line is searched whole

    for i, line in enumerate(lines):
        idx = i + 1                                     # file line index (line 0 is the fence)
        if _BAD_CHAR.search(line):
            fail(idx, "control, invisible or tab character", line)
            continue
        stripped = line.lstrip(" ")
        if not stripped:
            continue                                    # blank line
        indent = len(line) - len(stripped)
        if "---" in line:
            fail(idx, "`---` inside the frontmatter", line)
            continue
        if indent > 0 and mode == "hooks":
            sh.words(idx, line)                         # judged line by line in audit.py
            if not _hooks_line_ok(stripped):
                sh.bad(idx, "hooks block line is not `key:` or `key: value`")
            continue
        if indent > 0 and mode == "block":
            if block_min is None:
                block_min = indent
            elif indent < block_min:
                fail(idx, "block scalar line indented less than its first line", line)
            continue                                    # free text, never searched for keys
        # a column-0 line, or an indented / `- ` line under a bare key
        if mode in ("hooks", "block"):
            mode = "top"
        is_item = stripped.startswith("-") and (len(stripped) == 1 or stripped[1] == " ")
        if stripped[0] == "#" and mode == "nest" and indent <= MAX_NEST_INDENT:
            sh.words(idx, line)
            continue                                    # a whole-line comment inside a nested block
        if indent > 0 and mode == "plain" and indent <= MAX_NEST_INDENT:
            # continuation of a multi-line PLAIN scalar (how YAML tools fold a long description):
            # text that could not itself be a key (no `: `, no ` #`, no trailing colon, no
            # leading indicator, no quote), so no reader finds a key or a hook in it.
            why = _scalar_problem(stripped)
            if why is None and stripped[0] in "\"'":
                why = "quoted text on a plain scalar's continuation line"
            if why:
                fail(idx, why, line)
            continue                                    # a value: not searched for keys
        if indent > 0 or is_item:
            if mode != "nest" or indent > MAX_NEST_INDENT:
                fail(idx, "indented or `- ` line that does not follow a bare `key:`", line)
                continue
            why, key_part = _nest_problem(stripped)
            if why:
                fail(idx, why, line)
            else:
                sh.words(idx, key_part)
            continue
        kv = _key_split(stripped)
        if kv is None:
            fail(idx, "line is not `key: value` (comment, flow, anchor, tag, `?` key, directive, "
                      "document marker or text)", line)
            mode = "top"
            continue
        key, rest = kv
        sh.words(idx, key)
        if key in seen:
            sh.bad(idx, "duplicate key")
        seen.add(key)
        rest = rest.strip(" ")
        mode = "top"
        if not rest:
            mode = "hooks" if key == "hooks" else "nest"
            continue
        if rest in _BLOCK_HEADERS:
            mode = "block"
            block_min = None
            continue
        why = _scalar_problem(rest)
        if why:
            fail(idx, why, line)
        elif rest[0] not in "\"'" and rest != "[]":
            mode = "plain"                              # may continue on indented lines
