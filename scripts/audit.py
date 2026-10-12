#!/usr/bin/env python3
"""audit.py - static, offline, deterministic vetting scan of skill/agent/rule/hook content.

What it does
  Reads policy.yaml (banned-pattern rules, file classes, limits), walks the
  directories/files given on the command line WITHOUT following symlinks, and
  reports every line that matches a rule, plus a handful of built-in structural
  checks (hidden Unicode, escaping symlinks, executable binaries, oversize
  files, vendored node_modules). Findings the operator has reviewed can be
  suppressed through the fenced `audit-allow` block of CURATION.md.

What it never does: write files, touch the network, call a model, or follow a
symlink. Same input + same policy => byte-identical output.

Exit codes: 0 no un-allowed high finding | 1 at least one high | 2 usage,
policy, allowlist or CURATION.md error (including a missing target).

Only the Python standard library is used (plus scripts/lib/miniyaml.py, the
restricted-YAML reader for the policy files, and scripts/lib/fmyaml.py, the YAML
structure scanner for SKILL.md / agent frontmatter; both live in lib/ next to this
file) so the scanner runs on a bare machine before any virtualenv exists.

Do NOT run this under `python3 -I`: isolated mode drops the script directory
and the sys.path insert below would not be enough for `import audit` in tests.
"""
import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
import time
import unicodedata
import urllib.parse

# Make scripts/lib importable no matter where we are called from.
_HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(_HERE, "lib"))
import miniyaml  # noqa: E402  (needs the sys.path insert above)
import fmyaml  # noqa: E402

# --------------------------------------------------------------------------
# Constants
# --------------------------------------------------------------------------

# Severity of each built-in check when the policy's `builtin:` map omits it.
DEFAULT_BUILTIN = {
    "hidden-unicode": "high",
    "symlink-escape": "high",
    "binary-exec": "low",
    "oversize-file": "low",
    "unscannable-file": "low",
    "vendored-deps": "high",
    "source-not-allowed": "low",
    "source-uncurated": "low",
    "allow-unused": "low",
    "allow-stale": "low",
}

# Rules whose LOW findings `--quiet` still prints: the wire-time warning for a
# repo that only a machine overlay wires (the source checks), and the files the
# scanner could not read as text (oversize, executable binary, NUL-bearing). A
# LOW "not scanned" must not be invisible to the operator that runs `--quiet`.
ALWAYS_PRINT_LOW = {"source-not-allowed", "source-uncurated",
                    "oversize-file", "binary-exec", "unscannable-file"}

# Findings that describe a whole file/symlink/directory (no line number) and
# therefore carry a `sha256` that an allowlist entry can pin.
FILE_LEVEL_BUILTINS = {"hidden-unicode", "symlink-escape", "binary-exec",
                       "oversize-file", "unscannable-file", "vendored-deps"}

BUILTIN_MESSAGES = {
    "hidden-unicode": "invisible or bidirectional-control Unicode character",
    "symlink-escape": "symlink resolves outside the scanned tree (not followed)",
    "binary-exec": "executable binary (ELF/Mach-O/PE); not scanned",
    "oversize-file": "file larger than limits.max_file_bytes; not scanned",
    "unscannable-file": "binary content (NUL byte) that is not a known non-text format; not scanned",
    "vendored-deps": "vendored node_modules directory; not scanned",
    "allow-unused": "allowlist entry matched nothing in this run",
    "allow-stale": "hash-pinned allowlist entry no longer matches the file; entry inactive",
}

DOWNGRADE_CONTEXTS = ("test", "negation", "negation-quoted", "comment")
# What starts a comment depends on the language, so a `comment` downgrade looks
# the prefixes up by file extension. `*` and `<!--` are never comment starters
# for executable text (`*)` is a shell case branch), and `//` is not one in shell
# (`//usr/bin/curl` is a path). Anything not listed (shell, python, ruby, yaml,
# powershell, markdown fences, frontmatter hooks, extensionless) uses `#` only;
# JSON has no comments at all.
COMMENT_PREFIXES_BY_EXT = {
    ".js": ("//", "/*"), ".mjs": ("//", "/*"), ".cjs": ("//", "/*"),
    ".ts": ("//", "/*"), ".json": (),
}
DEFAULT_COMMENT_PREFIXES = ("#",)
EXCERPT_MAX = 120
BINARY_SNIFF = 8192

# A line longer than LONG_LINE is matched in overlapping windows instead of in one
# regex pass, so one hostile minified line cannot make a rule's backtracking
# quadratic; WINDOW_STEP leaves a 512-char overlap so a payload shorter than that
# is whole in at least one window. Backslash/trailing-pipe continuations are joined
# up to MAX_JOIN physical lines.
LONG_LINE = 4096
WINDOW_STEP = LONG_LINE - 512
MAX_JOIN = 20
DEFAULT_MAX_SECONDS = 300

# Quote characters that must sit immediately around a phrase for a leading
# negation to excuse it (`negation-quoted`).
QUOTE_CHARS = frozenset("\"'`\u201c\u201d\u2018\u2019\u00ab\u00bb")

# Look-alike letters folded to ASCII before a `normalise: true` rule matches, so
# `\u0456gnore previous instructions` (Cyrillic i) is still the attack phrase.
_CONFUSABLES = str.maketrans({
    **{ord(a): b for a, b in zip(
        "\u0430\u0435\u043e\u0440\u0441\u0443\u0445\u0456\u0458\u0455\u0501\u051b\u051d\u04bb\u0475\u043a",
        "aeopcyxijsdqwhvk")},
    **{ord(a): b for a, b in zip(
        "\u0410\u0412\u0415\u041a\u041c\u041d\u041e\u0420\u0421\u0422\u0425\u0406\u0408\u0405\u0423",
        "ABEKMHOPCTXIJSY")},
    **{ord(a): b for a, b in zip(
        "\u03bf\u03b1\u03b5\u03b9\u03ba\u03bd\u03c1\u03c4\u03c5\u03c7",
        "oaeiknptux")},
    **{ord(a): b for a, b in zip(
        "\u0391\u0392\u0395\u0396\u0397\u0399\u039a\u039c\u039d\u039f\u03a1\u03a4\u03a5\u03a7",
        "ABEZHIKMNOPTYX")},
})

# Executable magic numbers (see _is_exec_binary). Fat Mach-O (0xCAFEBABE) is left
# out on purpose: it collides with Java class files.
_MACHO_MAGICS = (b"\xfe\xed\xfa\xce", b"\xfe\xed\xfa\xcf",
                 b"\xce\xfa\xed\xfe", b"\xcf\xfa\xed\xfe")


class UsageError(Exception):
    """Anything that must end the run with exit code 2."""


class BudgetExceeded(UsageError):
    """limits.max_seconds ran out; reported without the "error:" prefix."""


# --------------------------------------------------------------------------
# Small helpers
# --------------------------------------------------------------------------

def glob_to_regex(glob):
    """Translate a policy/allowlist glob into a compiled regex (not fnmatch:
    its `*` would cross `/`). `**/` = zero or more directories, `**` = anything,
    `*` = anything except `/`, `?` = one non-`/` character."""
    out = []
    i = 0
    while i < len(glob):
        if glob.startswith("**/", i):
            out.append("(?:.*/)?")
            i += 3
        elif glob.startswith("**", i):
            out.append(".*")
            i += 2
        elif glob[i] == "*":
            out.append("[^/]*")
            i += 1
        elif glob[i] == "?":
            out.append("[^/]")
            i += 1
        else:
            out.append(re.escape(glob[i]))
            i += 1
    return re.compile("".join(out) + r"\Z", re.DOTALL)


def is_hidden_char(c):
    """True for the invisible / bidi / tag / variation-selector code points that
    the `hidden-unicode` check flags (before the exemptions in _exempt)."""
    o = ord(c)
    return (0x202A <= o <= 0x202E or 0x2066 <= o <= 0x2069      # bidi controls
            or 0xE0000 <= o <= 0xE007F                           # tag characters
            or o in (0x200B, 0x200E, 0x200F)                     # zero-width, LRM/RLM
            or 0x2060 <= o <= 0x2064                             # invisible operators
            or o in (0x200C, 0x200D, 0xFEFF)                     # joiners, BOM/ZWNBSP
            or 0xFE00 <= o <= 0xFE0F or 0xE0100 <= o <= 0xE01EF  # variation selectors
            or o == 0x00AD                                       # soft hyphen
            or o in (0x2028, 0x2029)                             # line/para separators
            or o == 0x180E                                       # Mongolian vowel sep.
            or o == 0x061C                                       # Arabic letter mark (bidi)
            or 0x206A <= o <= 0x206F or o == 0x2065              # deprecated formatting controls
            or o in (0x3164, 0x115F, 0x1160, 0xFFA0)             # Hangul fillers (blank glyphs)
            or o == 0x034F                                       # combining grapheme joiner
            or 0x2000 <= o <= 0x200A                             # en/em/thin/hair... spaces
            or 0xFFF9 <= o <= 0xFFFB                             # interlinear annotation
            or 0x1D173 <= o <= 0x1D17A)                          # musical formatting controls


def _exempt(c, prev, nxt, at_file_start):
    """Legitimate uses of otherwise-flagged characters (see design rule 7).

    A joiner or selector is exempt only when it stands ALONE: a run of them
    (ZWJ ZWJ ZWNJ ..., FE0F FE0F ...) is a binary side channel, so a neighbour of
    the same family on either side withdraws the exemption. An emoji sequence
    like heart + FE0F + ZWJ + fire mixes the two families and stays clean."""
    o = ord(c)
    if o == 0xFEFF and at_file_start:
        return True                      # a byte-order mark as the very first char
    if o in (0x200C, 0x200D) and prev is not None:
        if prev in "\u200c\u200d" or (nxt is not None and nxt in "\u200c\u200d"):
            return False
        p = ord(prev)
        # Joiners after Arabic/Indic/emoji-range characters, but not after
        # general punctuation/format characters (U+2000-U+206F).
        return p >= 0x0600 and not (0x2000 <= p <= 0x206F)
    if o == 0xFE0F and prev is not None:
        if prev == "\ufe0f" or nxt == "\ufe0f":
            return False
        return ord(prev) >= 0x2190       # emoji presentation selector after a symbol
    return False


def _prep(rule, text):
    """The text a rule matches: for `normalise: true` rules NFKC-folded, with look-alike
    letters mapped to ASCII and invisible characters removed (they are their own
    finding), so an obfuscated spelling of the phrase still matches."""
    if not rule.normalise:
        return text
    text = unicodedata.normalize("NFKC", text).translate(_CONFUSABLES)
    return "".join(c for c in text if not is_hidden_char(c))


def _search(rx, text, tick=None):
    """(start, end) of the first match of `rx` in `text`, else None. Text longer than
    LONG_LINE is searched in overlapping windows (see LONG_LINE), calling `tick()`
    between windows so the time budget is honoured inside one huge line."""
    if len(text) <= LONG_LINE:
        m = rx.search(text)
        return (m.start(), m.end()) if m else None
    for off in range(0, len(text), WINDOW_STEP):
        if tick is not None:
            tick()
        m = rx.search(text[off:off + LONG_LINE])
        if m:
            return off + m.start(), off + m.end()
    return None


# A SKILL.md / agent .md frontmatter is READ AS YAML (scripts/lib/fmyaml.py), not scanned for
# lines: every `hooks` key at any depth (block or flow, quoted, under any parent, in an anchored
# mapping) is a hooks block, and the block is judged DENY BY DEFAULT. The only lines of a hooks
# block that are not findings are its own structure, decided from the parse tree below: the
# `hooks:` key, the event keys, and `matcher` / `type: command` / `statusMessage` / `timeout`
# pairs whose whole line is just that pair. EVERYTHING ELSE (any `command`, `run`, `exec`,
# `script`, `args`, `prompt`, `url`, flow mappings, anchors and aliases, unknown keys or hook
# types, a value on the next line, a trailing comment) is a `hook-declared` finding that an
# allowlist entry must pin by whole line. Deny-by-default on purpose: a pattern that names what
# is dangerous is always one spelling behind.
_HOOK_EVENTS = frozenset(("PreToolUse", "PostToolUse", "Stop", "SubagentStop", "UserPromptSubmit",
                          "SessionStart", "SessionEnd", "Notification", "PreCompact"))
# Whole-value patterns (fullmatch on a value the parser already isolated; single character
# classes, so linear). Nothing here can hold a shell metacharacter or a message with a command.
_SAFE_MATCHER = re.compile(r"[A-Za-z0-9_|*.:-]*")
_SAFE_STATUS = re.compile(r"[^\"'$`\\|;&<>]*")
_INTEGER = re.compile(r"[0-9]+")
MAX_STRUCTURAL_VALUE = 200          # a longer value is a finding whatever it says


def _plain_key(node):
    """The text of a plain, property-free scalar key, else None."""
    if node.kind == "scalar" and node.style == "plain" and not node.props:
        return node.value
    return None


class _HookStructure:
    """Which lines of one `hooks` block are pure structure, decided from the parse tree.

    `structural` holds file line indexes that are not findings; `content` holds the lines that
    are the inside of a multi-line scalar (a line there starting with `#` is text, not a YAML
    comment, so it is never skipped)."""

    def __init__(self, lines, base):
        self.lines = lines
        self.base = base
        self.structural = set()
        self.content = set()

    def _line(self, node_line):
        return self.lines[node_line + self.base].rstrip("\r")

    def _prefix_ok(self, text, key):
        # Only indentation and the `- ` markers of the sequence entries may precede the key.
        return set(text[:key.col]) <= {" ", "-"}

    def _bare_key_line(self, key, value, colon_line, colon_col):
        """`key:` with nothing after the colon on its line, and the value (if any) starting on
        a later line as a plain block collection."""
        if _plain_key(key) is None or key.line != colon_line:
            return False
        if value.kind != "null" and (value.flow or value.props or value.kind not in ("map", "seq")
                                     or value.line <= colon_line):
            return False
        text = self._line(colon_line)
        return self._prefix_ok(text, key) and text[colon_col + 1:].strip() == ""

    def _scalar_pair(self, key, value, colon_line, safe):
        """`key: value` filling its whole line, with `safe(value)` true."""
        if _plain_key(key) is None or value.kind != "scalar" or value.props:
            return False
        if not (key.line == value.line == value.end_line == colon_line):
            return False
        text = self._line(colon_line)
        if not self._prefix_ok(text, key) or len(text.rstrip()) != value.end_col:
            return False
        return len(value.value) <= MAX_STRUCTURAL_VALUE and safe(value)

    def mark_hooks_key(self, key, value, colon_line, colon_col):
        """The `hooks:` key line and, below it, the events -> entries -> hook entries."""
        if self._bare_key_line(key, value, colon_line, colon_col):
            self.structural.add(colon_line + self.base)
            if value.kind == "map":
                self._events(value)

    def _events(self, node):
        for key, value, cl, cc in node.pairs:
            if _plain_key(key) in _HOOK_EVENTS and self._bare_key_line(key, value, cl, cc):
                self.structural.add(cl + self.base)
                if value.kind == "seq":
                    for item in value.items:
                        if item.kind == "map" and not item.flow and not item.props:
                            self._entry(item)

    def _entry(self, node):
        for key, value, cl, cc in node.pairs:
            name = _plain_key(key)
            if name == "hooks":
                if self._bare_key_line(key, value, cl, cc):
                    self.structural.add(cl + self.base)
                    if value.kind == "seq":
                        for item in value.items:
                            if item.kind == "map" and not item.flow and not item.props:
                                self._entry(item)
                continue
            if name == "matcher":
                ok = self._scalar_pair(key, value, cl, lambda v: v.style in ("plain", "single", "double")
                                       and _SAFE_MATCHER.fullmatch(v.value))
            elif name == "type":
                ok = self._scalar_pair(key, value, cl, lambda v: v.style == "plain" and v.value == "command")
            elif name == "statusMessage":
                ok = self._scalar_pair(key, value, cl, lambda v: v.style in ("single", "double")
                                       and _SAFE_STATUS.fullmatch(v.value))
            elif name == "timeout":
                ok = self._scalar_pair(key, value, cl, lambda v: v.style == "plain"
                                       and _INTEGER.fullmatch(v.value))
            else:
                continue                                # any other key: a finding
            if ok:
                self.structural.add(cl + self.base)

    def collect_content(self, node, depth=0):
        """Lines that continue a multi-line scalar anywhere under `node`."""
        if node is None or depth > 100:
            return
        if node.kind == "scalar" and node.end_line > node.line:
            self.content.update(range(node.line + 1 + self.base, node.end_line + 1 + self.base))
        for item in node.items:
            self.collect_content(item, depth + 1)
        for key, value, _cl, _cc in node.pairs:
            self.collect_content(key, depth + 1)
            self.collect_content(value, depth + 1)


def _hook_regions(fm, lines):
    """[(first line index, last line index, _HookStructure)] for each outermost `hooks` key."""
    out = []
    for key, value, cl, cc in fm.hooks:
        st = _HookStructure(lines, fm.base)
        st.mark_hooks_key(key, value, cl, cc)
        st.collect_content(value)
        out.append((key.line + fm.base, max(value.end_line, key.line) + fm.base, st))
    return out


def _tool_list_item(line):
    """The tool name of a `- Read` / `- "Bash"` / `- Read  # note` list line, else None.
    String operations only: the regex this replaces backtracked quadratically on a line of
    blanks (a hostile frontmatter line must cost milliseconds, never minutes)."""
    s = line.lstrip()
    if len(s) < 2 or s[0] != "-" or not s[1].isspace():
        return None
    rest = s[1:].lstrip()
    if rest[:1] in ("'", '"'):
        rest = rest[1:]
    cut = len(rest)
    for ch in "\"'#":
        i = rest.find(ch)
        if i != -1 and i < cut:
            cut = i
    tail = rest[cut:]
    if tail[:1] in ("'", '"'):
        tail = tail[1:]
    tail = tail.lstrip()
    if tail and not tail.startswith("#"):
        return None
    return rest[:cut].strip()


def _frontmatter_tool_lists(lines):
    """{index of the key line: "allowed-tools: a, b"} for an `allowed-tools:` key written as
    a YAML block list in the frontmatter (`- Read` / `- Bash` on following lines). The
    scanner's rules read one line, so the list is folded into the one-line spelling for
    matching; findings still point at the key line and quote the folded line."""
    out = {}
    if not lines or lines[0].lstrip("\ufeff").rstrip("\r") != "---":
        return out
    i = 1
    while i < len(lines):
        text = lines[i].rstrip("\r")
        if text in ("---", "..."):
            break
        if re.match(r"""^["']?allowed-tools["']?\s*:\s*(#.*)?$""", text):
            items = []
            j = i + 1
            while j < len(lines):
                item = _tool_list_item(lines[j].rstrip("\r"))
                if item is None:
                    break
                items.append(item)
                j += 1
            if items:
                out[i] = "allowed-tools: " + ", ".join(items)
            i = j
            continue
        i += 1
    return out


def _logical_lines(lines, comment_prefixes=DEFAULT_COMMENT_PREFIXES):
    """[(first physical index, text, last physical index)] with backslash-continued
    lines and lines that end in a pipe joined to the following one (at most MAX_JOIN
    physical lines), so `curl ... \\` newline `| bash` is one command. A markdown table
    row (starts with `|`) is never joined on its trailing pipe, and a COMMENT line
    (first non-blank text is one of `comment_prefixes`) is never joined at all: a
    comment does not continue onto the next line in any language, so joining would let
    a trailing backslash turn a command into part of a comment. Consumed continuation
    lines are not scanned separately by the line rules (the `physical` rules are, see
    Rule); a finding is reported at the first physical line."""
    out = []
    i, n = 0, len(lines)
    while i < n:
        text = lines[i].rstrip("\r")
        joined, j = text, i
        is_comment = bool(comment_prefixes) and text.lstrip().startswith(comment_prefixes)
        while not is_comment and j + 1 < n and j - i < MAX_JOIN - 1:
            cur = joined.rstrip()
            if cur.endswith("\\") and not cur.endswith("\\\\"):
                joined = cur[:-1] + " " + lines[j + 1].strip()
            elif (cur.endswith("|") and not cur.endswith("||")
                  and not text.lstrip().startswith("|")):
                joined = cur + " " + lines[j + 1].strip()
            else:
                break
            j += 1
        out.append((i, joined, j))
        i = j + 1
    return out


def escape_text(s):
    """Render invisible / non-printable code points as \\uXXXX so a report can
    never itself carry bidi or zero-width text."""
    out = []
    for c in s:
        if is_hidden_char(c) or not (c.isprintable()):
            o = ord(c)
            out.append("\\u%04x" % o if o <= 0xFFFF else "\\U%08x" % o)
        else:
            out.append(c)
    return "".join(out)


def sha256_bytes(data):
    return hashlib.sha256(data).hexdigest()


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def sha256_dir(path):
    """Hash a directory (for `vendored-deps`): sha256 of the byte-sorted lines
    `<relpath>\\t<sha256 of file bytes>\\n` for every regular file under it
    (symlinks are not followed and not counted)."""
    lines = []
    for dirpath, dirnames, filenames in os.walk(path, followlinks=False):
        dirnames.sort()
        for name in filenames:
            full = os.path.join(dirpath, name)
            if os.path.islink(full) or not os.path.isfile(full):
                continue
            rel = os.path.relpath(full, path).replace(os.sep, "/")
            lines.append(("%s\t%s\n" % (rel, sha256_file(full))).encode("utf-8", "surrogateescape"))
    lines.sort()
    return sha256_bytes(b"".join(lines))


def _is_exec_binary(head):
    """ELF, Mach-O or PE magic at the start of a file."""
    if head.startswith(b"\x7fELF") or head[:4] in _MACHO_MAGICS:
        return True
    if head[:2] == b"MZ" and len(head) >= 0x40:
        # A real PE file has "PE\0\0" at the offset stored at 0x3C; bare "MZ"
        # at the start of a text file is not enough.
        off = int.from_bytes(head[0x3C:0x40], "little")
        return head[off:off + 4] == b"PE\x00\x00"
    return False


# Leading bytes of common non-text formats that legitimately carry NUL bytes
# (images, documents, archives, web fonts). Only these may skip the text scan
# silently; any other NUL-bearing file is an `unscannable-file` finding.
_KNOWN_BINARY_MAGICS = (b"\x89PNG\r\n\x1a\n", b"\xff\xd8\xff", b"GIF87a", b"GIF89a",
                        b"%PDF-", b"PK\x03\x04", b"PK\x05\x06", b"\x1f\x8b",
                        b"wOFF", b"wOF2")


def _plausible_utf16(data):
    """True when `data` really is UTF-16 text: a BOM (FF FE is not the UTF-32 LE BOM),
    an even length, a strict decode, no NUL character in the result and mostly ASCII
    (so a byte sequence merely STARTING with FF FE, which bash runs as a script, is not
    mistaken for UTF-16 and decoded into harmless-looking garbage). Real UTF-16 in a
    non-Latin script is therefore reported as unscannable, which fails closed."""
    if not data.startswith((b"\xff\xfe", b"\xfe\xff")) or data.startswith(b"\xff\xfe\x00\x00"):
        return False
    if len(data) % 2:
        return False
    try:
        text = data.decode("utf-16")
    except UnicodeDecodeError:
        return False
    if "\x00" in text or not text:
        return False
    return sum(1 for c in text if ord(c) < 0x80) >= 0.9 * len(text)


def _is_known_binary(head):
    """A file that starts with the magic number of a common non-text format."""
    return head.startswith(_KNOWN_BINARY_MAGICS)


# --------------------------------------------------------------------------
# Policy
# --------------------------------------------------------------------------

class Rule:
    """One compiled `rules:` entry from policy.yaml."""

    def __init__(self, d):
        rid = d.get("id")
        if not isinstance(rid, str) or not rid:
            raise UsageError("policy: a rule has no id")
        self.id = rid
        self.severity = d.get("severity")
        if self.severity not in ("high", "low"):
            raise UsageError("policy: rule %r: severity must be high or low" % rid)
        self.severity_by_class = d.get("severity_by_class") or {}
        self.owned_severity = d.get("owned_severity")
        for sev in list(self.severity_by_class.values()) + [self.owned_severity]:
            if sev is not None and sev not in ("high", "low"):
                raise UsageError("policy: rule %r: bad severity %r" % (rid, sev))
        self.message = d.get("message") or rid
        self.applies = d.get("applies")
        self.downgrade = d.get("downgrade") or []
        for ctx in self.downgrade:
            if ctx not in DOWNGRADE_CONTEXTS:
                raise UsageError("policy: rule %r: unknown downgrade context %r" % (rid, ctx))
        self.regex = self._compile(rid, "regex", d.get("regex"), required=True)
        self.ignore = self._compile(rid, "ignore_regex", d.get("ignore_regex"), required=False)
        # normalise: match on NFKC-folded, confusable-folded text (prompt-injection).
        # window: 2 also matches a phrase split over this line and the next.
        self.normalise = bool(d.get("normalise", False))
        self.window = d.get("window", 1)
        # physical: true also matches every physical line a continuation join swallowed
        # (anchored rules such as `^hooks:` would otherwise be hidden by a previous line
        # that ends in a backslash or a pipe).
        self.physical = bool(d.get("physical", False))
        if self.window not in (1, 2):
            raise UsageError("policy: rule %r: window must be 1 or 2" % rid)

    @staticmethod
    def _compile(rid, field, pattern, required):
        if pattern is None:
            if required:
                raise UsageError("policy: rule %r has no regex" % rid)
            return None
        try:
            return re.compile(pattern)
        except re.error as exc:
            raise UsageError("policy: rule %r: bad %s: %s" % (rid, field, exc))


class Policy:
    def __init__(self, path):
        try:
            with open(path, "rb") as fh:
                raw = fh.read()
        except OSError as exc:
            raise UsageError("cannot read policy %s: %s" % (path, exc))
        self.sha256 = sha256_bytes(raw)
        try:
            doc = miniyaml.loads(raw.decode("utf-8"))
        except miniyaml.ParseError as exc:
            raise UsageError("%s: %s" % (path, exc))
        except UnicodeDecodeError:
            raise UsageError("%s: not valid UTF-8" % path)
        if not isinstance(doc, dict):
            raise UsageError("%s: top level must be a map" % path)
        self.owned_roots = [str(x) for x in (doc.get("owned_roots") or [])]
        self.skip_dirs = set(str(x) for x in (doc.get("skip_dirs") or []))
        limits = doc.get("limits") or {}
        self.max_file_bytes = limits.get("max_file_bytes", 1048576)
        if not isinstance(self.max_file_bytes, int):
            raise UsageError("policy: limits.max_file_bytes must be an integer")
        self.max_seconds = limits.get("max_seconds", DEFAULT_MAX_SECONDS)
        if not isinstance(self.max_seconds, int) or self.max_seconds < 1:
            raise UsageError("policy: limits.max_seconds must be a positive integer")
        self.sources = doc.get("sources") or {}
        neg = doc.get("negation")
        try:
            self.negation = re.compile(neg) if neg else None
        except re.error as exc:
            raise UsageError("policy: bad negation regex: %s" % exc)
        self.builtin = dict(DEFAULT_BUILTIN)
        self.builtin.update(doc.get("builtin") or {})
        for k, v in self.builtin.items():
            if v not in ("high", "low"):
                raise UsageError("policy: builtin %r: severity must be high or low" % k)
        self.classes = []  # [(name, [compiled globs])] in policy order
        for c in doc.get("classes") or []:
            name = c.get("name")
            if not name:
                raise UsageError("policy: a class has no name")
            self.classes.append((name, [glob_to_regex(g) for g in c.get("globs") or []]))
        self.rules = [Rule(r) for r in (doc.get("rules") or [])]
        self.physical_rules = [r for r in self.rules if r.physical]
        ids = [r.id for r in self.rules]
        if len(ids) != len(set(ids)):
            raise UsageError("policy: duplicate rule id")
        # Every id an allowlist entry may name.
        self.known_ids = set(ids) | set(self.builtin)

    def file_class(self, rel_target, rel_root):
        """First class (policy order) with a glob matching either path; else 'other'.

        The `test` class is special-cased because it lowers severity and its
        trigger is a path the content's author chooses: it is matched against the
        target-relative path only (a directory called `test` ABOVE the scan target
        proves nothing), and a file the agent loads or the harness reads
        (SKILL.md, an agent .md, .mcp.json, hooks.json) is never `test`."""
        base = rel_target.rsplit("/", 1)[-1]
        loaded = base in ("SKILL.md", ".mcp.json", "hooks.json") or _is_agent_md(rel_target, rel_root, base)
        for name, globs in self.classes:
            if name == "test":
                if loaded:
                    continue
                if any(rx.match(rel_target) for rx in globs):
                    return name
                continue
            for rx in globs:
                if rx.match(rel_target) or (rel_root is not None and rx.match(rel_root)):
                    return name
        return "other"


# --------------------------------------------------------------------------
# Allowlist (the fenced `audit-allow` block of CURATION.md)
# --------------------------------------------------------------------------

class AllowEntry:
    def __init__(self, index, d, policy):
        """`index` is 1-based and is what error messages and allow-* findings name."""
        self.index = index
        where = "allowlist entry %d" % index
        if not isinstance(d, dict):
            raise UsageError("%s: not a map" % where)
        self.rule = d.get("rule")
        if not isinstance(self.rule, str) or self.rule not in policy.known_ids:
            raise UsageError("%s: unknown or missing rule %r" % (where, self.rule))
        self.path = d.get("path")
        if not isinstance(self.path, str) or not self.path:
            raise UsageError("%s: missing path" % where)
        reason = d.get("reason")
        if not isinstance(reason, str) or len(reason.strip()) < 10:
            raise UsageError("%s: reason is required (at least 10 characters)" % where)
        self.contains = d.get("contains")
        # Default: `contains` must equal the whole line (surrounding whitespace
        # ignored), so a reviewed line cannot carry an appended payload. The
        # legacy substring match is an explicit, per-entry opt-in.
        self.contains_substring = d.get("contains_substring", False)
        if not isinstance(self.contains_substring, bool):
            raise UsageError("%s: contains_substring must be true or false" % where)
        if self.contains_substring and d.get("contains") is None:
            raise UsageError("%s: contains_substring needs `contains`" % where)
        self.sha256 = d.get("sha256")
        is_builtin = self.rule in policy.builtin
        if self.contains is not None:
            if not isinstance(self.contains, str) or not self.contains:
                raise UsageError("%s: contains must be a non-empty string" % where)
        else:
            # A contains-less entry exempts a whole file, so it is only allowed
            # for a builtin check and is pinned to the file's exact bytes.
            if not is_builtin:
                raise UsageError("%s: rule %s needs `contains` (only built-in checks may omit it)"
                                 % (where, self.rule))
            if any(ch in self.path for ch in "*?["):
                raise UsageError("%s: an entry without `contains` needs a literal path (no glob)" % where)
            if not (isinstance(self.sha256, str) and re.fullmatch(r"[0-9a-f]{64}", self.sha256)):
                raise UsageError("%s: an entry without `contains` needs a 64-hex `sha256`" % where)
        self.path_rx = glob_to_regex(self.path)
        self.used = False

    def matches(self, f):
        """Does finding `f` fall under this entry? (Stale-hash handling is separate.)"""
        if f["rule"] != self.rule or not self.path_rx.match(f["path"]):
            return False
        if self.contains is not None:
            if self.contains_substring:
                return (self.contains in f["_line"]
                        or self.contains in f["_line_escaped"])
            want = self.contains.strip()
            return want in (f["_line"].strip(), f["_line_escaped"].strip())
        return f["sha256"] == self.sha256


def load_allowlist(path, policy):
    """Parse every ```yaml audit-allow block of CURATION.md. Missing file = empty."""
    if not path or not os.path.isfile(path):
        return []
    with open(path, "r", encoding="utf-8", errors="replace") as fh:
        lines = fh.read().split("\n")
    raw_entries = []
    i = 0
    while i < len(lines):
        if lines[i].rstrip("\r") == "```yaml audit-allow":
            start = i + 1
            j = start
            while j < len(lines) and lines[j].rstrip("\r") != "```":
                j += 1
            if j >= len(lines):
                raise UsageError("%s:%d: unterminated audit-allow block" % (path, i + 1))
            try:
                doc = miniyaml.loads("\n".join(lines[start:j]))
            except miniyaml.ParseError as exc:
                # Report the line in CURATION.md, not within the block.
                raise UsageError("%s:%d: audit-allow: %s" % (path, start + exc.line, exc.msg))
            if doc is not None:
                if not isinstance(doc, list):
                    raise UsageError("%s:%d: audit-allow block must be a list" % (path, start))
                raw_entries.extend(doc)
            i = j
        i += 1
    return [AllowEntry(n, d, policy) for n, d in enumerate(raw_entries, 1)]


# --------------------------------------------------------------------------
# Scanning
# --------------------------------------------------------------------------

def _is_agent_md(rel_target, rel_root, name):
    """A `.md` file that Claude loads as an agent: has an `agents` path component."""
    if not name.lower().endswith(".md"):
        return False
    for rel in (rel_target, rel_root):
        if rel and "agents" in rel.split("/")[:-1]:
            return True
    return False


class Scan:
    """Walks targets and collects findings. All reporting paths are root-relative."""

    def __init__(self, policy, root):
        self.policy = policy
        self.root = os.path.realpath(root)
        self.findings = []
        self.targets = 0
        self.files = 0
        # Wall-clock budget for the whole run (limits.max_seconds): one pathological
        # input must stall the gate for seconds, not hours.
        self.deadline = time.monotonic() + policy.max_seconds
        self._current = ""                # display path of the file being scanned
        # Names <n> of every repos/<n> upstream submodule a target resolves under
        # (feeds the source checks; a library repo with no target never appears).
        self.repos = set()

    # -- reporting helpers ---------------------------------------------------

    def _rel_root(self, real_path):
        """Path relative to --root with '/' separators, or None if outside it."""
        rel = os.path.relpath(real_path, self.root)
        if rel == ".." or rel.startswith(".." + os.sep):
            return None
        return rel.replace(os.sep, "/")

    def _tier(self, real_target):
        rel = self._rel_root(real_target)
        if rel is not None:
            top = rel.split("/")[0]
            if top in self.policy.owned_roots and rel != ".":
                return "owned"
        return "upstream"

    def _add(self, rule, severity, path, line, cls, tier, message, excerpt="",
             downgraded=None, sha256=None, raw_line=""):
        self.findings.append({
            "rule": rule, "severity": severity, "path": path, "line": line,
            "class": cls, "tier": tier, "message": message,
            "excerpt": escape_text(excerpt.strip(" \t")[:EXCERPT_MAX]),
            "allowed": False, "downgraded": downgraded, "sha256": sha256,
            # private fields used for allowlist matching; stripped before output
            "_line": raw_line, "_line_escaped": escape_text(raw_line),
        })

    # -- traversal -----------------------------------------------------------

    def scan_target(self, target):
        real = os.path.realpath(target)
        self.targets += 1
        tier = self._tier(real)
        rel = self._rel_root(real)
        parts = rel.split("/") if rel is not None else []
        if len(parts) >= 2 and parts[0] == "repos":
            self.repos.add(parts[1])          # target is repos/<name> or below it
        if os.path.isdir(real):
            self._walk(real, real, tier)
        else:
            self._scan_file(real, os.path.basename(real), tier)

    def _tick(self, path=None):
        """Abort the run (exit 2) when the time budget is spent. Names the file being
        scanned (`self._current`) unless a path is given."""
        if time.monotonic() > self.deadline:
            raise BudgetExceeded("time budget exceeded at %s" % (path or self._current))

    def _display(self, real_path):
        rel = self._rel_root(real_path)
        return rel if rel is not None else real_path.replace(os.sep, "/")

    def _walk(self, top, directory, tier):
        """Depth-first, name-sorted, symlinks never followed."""
        try:
            entries = sorted(os.scandir(directory), key=lambda e: e.name)
        except OSError as exc:
            raise UsageError("cannot read directory %s: %s" % (directory, exc))
        for e in entries:
            full = os.path.join(directory, e.name)
            rel_target = os.path.relpath(full, top).replace(os.sep, "/")
            if e.is_symlink():
                resolved = os.path.realpath(full)
                if not (resolved == top or resolved.startswith(top + os.sep)):
                    self._symlink_escape(full, rel_target, tier)
                continue                      # never followed, escaping or not
            if e.is_dir(follow_symlinks=False):
                # skip_dirs names the scan target's OWN bookkeeping (its repo
                # metadata directory); a same-named directory deeper down is
                # content like any other and is scanned.
                if e.name in self.policy.skip_dirs and directory == top:
                    continue
                if e.name == "node_modules":
                    self._vendored(full, rel_target, tier)
                    continue
                self._walk(top, full, tier)
            elif e.is_file(follow_symlinks=False):
                self._scan_file(full, rel_target, tier)

    def _symlink_escape(self, full, rel_target, tier):
        rel_root = self._rel_root(full)
        cls = self.policy.file_class(rel_target, rel_root)
        self._add("symlink-escape", self.policy.builtin["symlink-escape"],
                  self._display(full), 0, cls, tier, BUILTIN_MESSAGES["symlink-escape"],
                  sha256=sha256_bytes(os.fsencode(os.readlink(full))))

    def _vendored(self, full, rel_target, tier):
        self._add("vendored-deps", self.policy.builtin["vendored-deps"],
                  self._display(full), 0, "other", tier, BUILTIN_MESSAGES["vendored-deps"],
                  sha256=sha256_dir(full))

    # -- one file ------------------------------------------------------------

    def _not_scanned_severity(self, rule, fclass, name, rel_target, rel_root):
        """Severity of a finding that says "this file was NOT scanned" (oversize,
        executable binary, NUL-bearing). Content that gets executed, loaded as an
        agent or read as configuration must not pass quietly, so script/hook/config
        class, SKILL.md and agent .md are high; prose and assets stay at the policy
        default (low), which `--quiet` still prints (ALWAYS_PRINT_LOW)."""
        if self._exec_class(fclass, name, rel_target, rel_root):
            return "high"
        return self.policy.builtin[rule]

    @staticmethod
    def _exec_class(fclass, name, rel_target, rel_root):
        """Content that is executed, loaded as an agent or read as configuration."""
        return (fclass in ("script", "hook", "config") or name == "SKILL.md"
                or _is_agent_md(rel_target, rel_root, name))

    def _scan_file(self, full, rel_target, tier):
        pol = self.policy
        self.files += 1
        rel_root = self._rel_root(full)
        display = self._display(full)
        self._current = display
        name = os.path.basename(full)
        fclass = pol.file_class(rel_target, rel_root)

        st = os.lstat(full)
        size = st.st_size
        oversize = size > pol.max_file_bytes
        with open(full, "rb") as fh:
            head = fh.read(BINARY_SNIFF)
            data = None if oversize else head + fh.read()
        # A file the extension globs call `other` but that is executable or starts
        # with a shebang is run as a script whatever its name.
        if fclass == "other" and (head.startswith(b"#!") or st.st_mode & 0o111):
            fclass = "script"

        if oversize:
            self._add("oversize-file",
                      self._not_scanned_severity("oversize-file", fclass, name, rel_target, rel_root),
                      display, 0, fclass, tier, BUILTIN_MESSAGES["oversize-file"],
                      sha256=sha256_file(full))
            return

        if _is_exec_binary(head):
            self._add("binary-exec",
                      self._not_scanned_severity("binary-exec", fclass, name, rel_target, rel_root),
                      display, 0, fclass, tier, BUILTIN_MESSAGES["binary-exec"],
                      sha256=sha256_bytes(data))
            return

        text = None
        stripped_view = None
        # A NUL ANYWHERE in the file counts (not just the first BINARY_SNIFF bytes): bash
        # drops NULs, so `cu<NUL>rl ... | ba<NUL>sh` placed after a long padding still runs.
        if b"\x00" in data:
            nul_in_head = b"\x00" in head
            exec_class = self._exec_class(fclass, name, rel_target, rel_root)
            if _plausible_utf16(data):
                # Plausibly UTF-16 with a BOM: decode it and scan the text. "Plausible" can be
                # forged (a NUL-free first line, aligned UTF-16 padding, then a plain ASCII
                # payload that bash runs after dropping the NULs), so executable classes ALSO
                # get the NUL-stripped view below. For real UTF-16 that view equals the decoded
                # text and its findings are de-duplicated.
                text = data.decode("utf-16")
                if exec_class:
                    # (without the two BOM bytes, so line 1 reads the same in both views)
                    stripped_view = data[2:].replace(b"\x00", b"").decode("utf-8", errors="replace")
            elif nul_in_head and _is_known_binary(head) and not exec_class:
                # An image/archive/font: nothing to scan. Never for executable classes:
                # a magic-number first line is trivially forged in front of a script
                # (fail closed; a genuine binary there is allowlisted by hash).
                return
            else:
                self._add("unscannable-file",
                          self._not_scanned_severity("unscannable-file", fclass, name, rel_target, rel_root),
                          display, 0, fclass, tier, BUILTIN_MESSAGES["unscannable-file"],
                          sha256=sha256_bytes(data))
                if nul_in_head and not exec_class:
                    return                    # genuine binary content
                # Executable content, or text with a stray NUL deep inside: ALSO scan the
                # bytes as bash would see them (NULs dropped), so the finding above is not
                # the only signal.
                text = data.replace(b"\x00", b"").decode("utf-8", errors="replace")

        file_sha = sha256_bytes(data)
        # Lines split on \n ONLY, so U+2028/U+2029 never end a line.
        if text is None:
            text = data.decode("utf-8", errors="replace")
        self._scan_text(text, fclass, name, rel_target, rel_root, display, tier, file_sha)
        if stripped_view is not None:
            before = len(self.findings)
            known = {(f["rule"], f["severity"], f["excerpt"]) for f in self.findings
                     if f["path"] == display}
            self._scan_text(stripped_view, fclass, name, rel_target, rel_root, display, tier, file_sha)
            # Drop only a finding the decoded view already reported IDENTICALLY (same rule,
            # severity and text). Never key on the line number: the two views number lines
            # differently, and a LOW decoy on the same number must not hide a HIGH payload.
            self.findings[before:] = [f for f in self.findings[before:]
                                      if (f["rule"], f["severity"], f["excerpt"]) not in known]

    def _hook_block_findings(self, lines, display, tier, file_sha, fm):
        """Default-deny over the frontmatter's hooks blocks (see _HookStructure): every non-blank
        line of a block that is not pure structure is a `hook-declared` finding, reported at its
        own line so an allowlist entry pins that exact line. Two fail-closed extras: a frontmatter
        that could not be read is itself a finding, and so is the token `hooks:` anywhere in a
        frontmatter whose parse found no hooks key (the parser and the consumer may disagree)."""
        rule = next((r for r in self.policy.rules if r.id == "hook-declared"), None)
        if rule is None or fm is None:
            return
        have = {(f["rule"], f["line"]) for f in self.findings if f["path"] == display}
        sev = rule.owned_severity if (tier == "owned" and rule.owned_severity) else rule.severity

        def flag(idx, raw):
            if ("hook-declared", idx + 1) in have:
                return
            have.add(("hook-declared", idx + 1))
            self._add("hook-declared", sev, display, idx + 1, "hook", tier, rule.message,
                      excerpt=raw, raw_line=raw)

        if fm.error is not None:
            idx, msg = fm.error
            flag(min(idx, len(lines) - 1), "frontmatter not parsed: " + msg)
        for first, last, st in _hook_regions(fm, lines):
            for idx in range(first, min(last, len(lines) - 1) + 1):
                self._tick(display)
                raw = lines[idx].rstrip("\r")
                body = raw.strip()
                if not body or idx in st.structural:
                    continue
                if body.startswith("#") and idx not in st.content:
                    continue                            # a real YAML comment
                flag(idx, raw)
        if not fm.hooks:
            for idx in fm.token_lines:
                flag(idx, lines[idx].rstrip("\r"))

    def _scan_text(self, text, fclass, name, rel_target, rel_root, display, tier, file_sha):
        """Run the line rules over one text view of a file."""
        loaded_md = name == "SKILL.md" or _is_agent_md(rel_target, rel_root, name)
        if loaded_md:
            # YAML (and so Claude's frontmatter reader) breaks lines on CRLF and on a lone CR
            # as well as LF; split the way it does so a CR cannot hide a key from the scan.
            text = text.replace("\r\n", "\n").replace("\r", "\n")
        lines = text.split("\n")
        fm = fmyaml.analyse(lines) if loaded_md else None
        classes = self._line_classes(lines, fclass, name, rel_target, rel_root, fm)
        ext = os.path.splitext(name)[1].lower()
        logical = _logical_lines(lines, COMMENT_PREFIXES_BY_EXT.get(ext, DEFAULT_COMMENT_PREFIXES))
        tool_lists = _frontmatter_tool_lists(lines) if loaded_md else {}
        for k, (idx, line, last) in enumerate(logical):
            if line == "":
                continue
            self._tick(display)
            nxt = logical[k + 1][1] if k + 1 < len(logical) else ""
            if idx in tool_lists:
                # List-form allowed-tools: scan (and quote, and let an allowlist entry pin) the
                # folded one-line spelling, so a changed tool list re-flags.
                line = tool_lists[idx]
            self._scan_line(line, idx + 1, classes[idx], display, tier, file_sha, ext, nxt)
            for p in range(idx + 1, last + 1):         # lines the join swallowed
                self._scan_line(lines[p].rstrip("\r"), p + 1, classes[p], display, tier,
                                file_sha, ext, only_physical=True)
        if loaded_md:
            self._hook_block_findings(lines, display, tier, file_sha, fm)

    def _line_classes(self, lines, fclass, name, rel_target, rel_root, fm=None):
        """Class of each line: the file's class, except (1) frontmatter `hooks:`
        blocks of SKILL.md/agent .md are `hook`, and (2) lines inside ANY fenced
        block of .md/.mdx doc files are `script`, whatever its info string (a
        fence tagged `python` or `text` is still copy-pasted; design rule 1:
        prose negation must not excuse a command)."""
        classes = [fclass] * len(lines)
        ext = os.path.splitext(name)[1].lower()

        # (1) frontmatter hooks blocks
        if fm is not None:
            for first, last, _st in _hook_regions(fm, lines):
                for i in range(first, min(last, len(lines) - 1) + 1):
                    classes[i] = "hook"

        # (2) fenced code blocks in markdown docs
        if fclass == "doc" and ext in (".md", ".mdx"):
            fence = None                      # (char, length) while inside one
            for i, raw in enumerate(lines):
                text = raw.rstrip("\r")
                m = re.match(r"^\s*(`{3,}|~{3,})(.*)$", text)
                if fence is None:
                    if not m:
                        continue
                    marker, info = m.group(1), m.group(2).strip()
                    if marker[0] == "`" and "`" in info:
                        continue              # inline code like ```x```, not a fence
                    fence = (marker[0], len(marker))
                else:
                    char, length = fence
                    # Closes at a line holding only the same fence char, at least as long.
                    if m and m.group(1)[0] == char and len(m.group(1)) >= length \
                            and m.group(2).strip() == "":
                        fence = None
                    else:
                        classes[i] = "script"
        return classes

    def _scan_line(self, line, lineno, cls, display, tier, file_sha, ext="", next_line="",
                   only_physical=False):
        pol = self.policy
        if only_physical:
            if not pol.physical_rules:
                return
        rules = pol.physical_rules if only_physical else pol.rules

        # Built-in: hidden Unicode. One finding per line however many characters.
        for pos, ch in enumerate([] if only_physical else line):
            if not is_hidden_char(ch):
                continue
            prev = line[pos - 1] if pos > 0 else None
            nxt = line[pos + 1] if pos + 1 < len(line) else None
            if _exempt(ch, prev, nxt, at_file_start=(lineno == 1 and pos == 0)):
                continue
            sev, down = pol.builtin["hidden-unicode"], None
            if cls == "test" and sev == "high":
                sev, down = "low", "test"
            self._add("hidden-unicode", sev, display, lineno, cls, tier,
                      BUILTIN_MESSAGES["hidden-unicode"], excerpt=line,
                      downgraded=down, sha256=file_sha, raw_line=line)
            break

        # Policy rules.
        for rule in rules:
            if rule.applies is not None and cls not in rule.applies:
                continue
            hit = self._rule_match(rule, line, next_line)
            if hit is None:
                continue
            text, span = hit
            sev = rule.severity_by_class.get(cls, rule.severity)
            if tier == "owned" and rule.owned_severity:
                sev = rule.owned_severity
            down = None
            if sev == "high":
                down = self._downgrade_context(rule, text, cls, ext, span)
                if down:
                    sev = "low"
            self._add(rule.id, sev, display, lineno, cls, tier, rule.message,
                      excerpt=line, downgraded=down, raw_line=line)

    def _rule_match(self, rule, line, next_line):
        """(text matched, (start, end)) when `rule` fires on `line`, else None. A rule
        with `window: 2` also fires on a phrase that starts on this line and ends on
        the next (whitespace collapsed); a match wholly inside the next line is that
        line's own business, so only a match that crosses the boundary counts."""
        text = _prep(rule, line)
        span = _search(rule.regex, text, self._tick)
        if span is None and rule.window >= 2 and next_line.strip():
            first = " ".join(text.split())
            joined = first + " " + " ".join(_prep(rule, next_line).split())
            crossing = _search(rule.regex, joined, self._tick)
            if crossing and crossing[0] < len(first) < crossing[1]:
                text, span = joined, crossing
        if span is None:
            return None
        if rule.ignore is not None and _search(rule.ignore, text, self._tick) is not None:
            return None
        return text, span

    def _downgrade_context(self, rule, line, cls, ext="", span=(0, 0)):
        """Name of the first listed context that excuses a high finding, else None.

        Each context is something the AUTHOR of the scanned text could otherwise
        pick to make a command look harmless, so each is narrow:
          test      the file is in the test class (the policy keeps it off the
                    exec/exfil rules; see `downgrade:` in policy.yaml)
          negation  prose only (class doc), and only when the negation word comes
                    BEFORE the match on the same line ("never run `...`")
          negation-quoted
                    as negation, and the matched phrase must also sit directly
                    inside quote characters (it is being quoted, not said)
          comment   the line starts with this file type's own comment marker"""
        for ctx in rule.downgrade:
            if ctx == "test" and cls == "test":
                return ctx
            if (ctx in ("negation", "negation-quoted") and self.policy.negation is not None
                    and cls == "doc" and self.policy.negation.search(line[:span[0]])):
                if ctx == "negation":
                    return ctx
                before = line[span[0] - 1] if span[0] > 0 else ""
                after = line[span[1]] if span[1] < len(line) else ""
                if before in QUOTE_CHARS and after in QUOTE_CHARS:
                    return ctx
            if (ctx == "comment" and cls in ("script", "hook", "config")
                    and line.lstrip().startswith(
                        COMMENT_PREFIXES_BY_EXT.get(ext, DEFAULT_COMMENT_PREFIXES))):
                # `/* note */ code(...)`: a block comment that is CLOSED before the match
                # does not cover it, so the match is code, not comment.
                off = len(line) - len(line.lstrip())
                close = line.find("*/", off + 2) if line.startswith("/*", off) else -1
                if close != -1 and close + 2 <= span[0]:
                    continue
                return ctx
        return None


# --------------------------------------------------------------------------
# Source and curation checks (vetting group 2)
# --------------------------------------------------------------------------

def baseline_repos(path):
    """Repo names a wiring manifest (baseline-submodules.txt) names, as a set.

    Same line normalisation as wire.sh `load_manifest`: strip `#...` and ALL
    whitespace. Then skip blank lines, subtractions (leading `-`) and every typed
    `<kind>:<name>` entry. A typed entry is detected structurally (a `:` before
    the first `/`), NOT by a list of known kinds, so a future kind such as
    `hook:` or `rules:` never turns into a phantom repo. The repo is the text
    before the first `/` (`anthropic/pdf` -> `anthropic`)."""
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            lines = fh.read().split("\n")
    except OSError as exc:
        raise UsageError("cannot read baseline %s: %s" % (path, exc))
    repos = set()
    for line in lines:
        line = "".join(line.split("#", 1)[0].split())
        if not line or line.startswith("-"):
            continue
        head = line.split("/", 1)[0]
        if ":" in head:
            continue
        repos.add(head)
    return repos


# Host and owner/repo name characters. Deliberately narrower than what git
# accepts: a source URL that needs anything else is not a GitHub-style clone URL.
_HOST_RE = r"[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?"
_NAME_RE = r"[A-Za-z0-9_.-]+"
_HTTPS_URL_RE = re.compile(r"https://(%s)(?::\d{1,5})?/(%s)/(%s)/?" % (_HOST_RE, _NAME_RE, _NAME_RE))
_SSH_URL_RE = re.compile(r"ssh://(?:git@)?(%s)(?::\d{1,5})?/(%s)/(%s)/?" % (_HOST_RE, _NAME_RE, _NAME_RE))
_SCP_URL_RE = re.compile(r"(?:git@)?(%s):(%s)/(%s)/?" % (_HOST_RE, _NAME_RE, _NAME_RE))
# Anything outside printable ASCII, plus the characters that move the real
# authority away from where a loose pattern reads it: `#` `?` backslash `%`.
_URL_REJECT_RE = re.compile(r"[^\x21-\x7e]|[#?\\%]")


def normalise_repo_url(url):
    """(host, 'owner/repo') lowercased for the URL forms used on GitHub, or None
    when the form is not recognised. Accepted: scp-style `[git@]host:o/r(.git)`,
    `ssh://[git@]host[:port]/o/r(.git)` and `https://host[:port]/o/r(.git)`, with
    an optional trailing slash. Plain `http://`, `git://` and `file:` are
    deliberately not recognised (unencrypted or local), so they can never match
    the allowlist.

    The allowlist must judge the SAME host git and curl will contact, so this is
    an exact grammar behind a reject-list, not a permissive parse. Any character
    outside printable ASCII, and any of `#`, `?`, backslash and `%`, is refused:
    `https://evil.invalid#@github.com/o/r` contacts evil.invalid although a loose
    userinfo pattern reads github.com. An https URL carries NO userinfo (a clone
    URL needs none, and `user:pw@` must fail); `git@` is the only userinfo, for
    the ssh and scp forms. For `://` forms the host is cross-checked against
    urllib's reading of the same string."""
    url = url.strip()
    if _URL_REJECT_RE.search(url):
        return None
    if url.startswith("https://"):
        m = _HTTPS_URL_RE.fullmatch(url)
    elif url.startswith("ssh://"):
        m = _SSH_URL_RE.fullmatch(url)
    elif "://" in url:
        return None
    else:
        m = _SCP_URL_RE.fullmatch(url)
    if not m:
        return None
    host, owner, repo = m.group(1).lower(), m.group(2), m.group(3)
    if "://" in url:
        try:
            parts = urllib.parse.urlsplit(url)
            if parts.hostname != host or parts.password is not None:
                return None
        except ValueError:
            return None
    if repo.lower().endswith(".git"):
        repo = repo[:-4]
    if owner in (".", "..") or repo in ("", ".", ".."):
        return None
    return host, ("%s/%s" % (owner, repo)).lower()


def check_url(policy, url):
    """(ok, reason) for a source URL against policy `sources` (host AND owner/repo)."""
    norm = normalise_repo_url(url)
    if norm is None:
        return False, "not a recognised https/ssh repository URL: %s" % escape_text(url)
    host, repo = norm
    hosts = [str(h).lower() for h in (policy.sources.get("allowed_hosts") or [])]
    repos = [str(r).lower() for r in (policy.sources.get("allowed_repos") or [])]
    if host not in hosts:
        return False, "host %s is not in sources.allowed_hosts" % host
    if repo not in repos:
        return False, "repository %s is not in sources.allowed_repos" % repo
    return True, "%s on %s is allowed" % (repo, host)


def _parse_gitmodules_text(path):
    """Line-based fallback reader (used only when git itself is not available)."""
    sections = []                      # one dict per section: path, url, url_line
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            lines = fh.read().split("\n")
    except OSError as exc:
        raise UsageError("cannot read %s: %s" % (path, exc))
    for n, raw in enumerate(lines, 1):
        text = raw.strip()
        if not text or text[0] in "#;":
            continue
        if text.startswith("["):
            sections.append({})
            continue
        key, sep, value = text.partition("=")
        if not sep or not sections:
            continue
        key, value = key.strip().lower(), value.strip().strip('"')
        if key == "path":
            sections[-1]["path"] = value
        elif key == "url":
            sections[-1]["url"], sections[-1]["url_line"] = value, n
    return {s["path"]: (s["url"], s["url_line"])
            for s in sections if "path" in s and "url" in s}


def parse_gitmodules(path):
    """{submodule path: (url, line number of its `url` line)} from a modules file.

    Read by git itself (`git config -f <file> --get-regexp`), the same reader the
    client uses, so every spelling git accepts (a section header and its first key
    on ONE line, quoting, comments) is understood the same way here. A homemade line
    parser disagreed with git on those spellings and then saw no submodules at all.
    The line number is found by searching the file for the url text (0 if absent);
    without git the line-based reader is the fallback. A section missing `path` or
    `url` is ignored (nothing to look up)."""
    try:
        proc = subprocess.run(
            ["git", "config", "-f", path, "--get-regexp", r"^submodule\..*\.(path|url)$"],
            env=dict(os.environ, LC_ALL="C"), stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            encoding="utf-8", errors="replace")
    except OSError:
        return _parse_gitmodules_text(path)       # git is not installed
    if proc.returncode not in (0, 1):             # 1 = no match; anything else = unreadable
        raise UsageError("cannot read %s: %s" % (path, proc.stderr.strip() or "git config failed"))
    sections = {}
    for row in proc.stdout.splitlines():
        key, _, value = row.partition(" ")
        name, _, field = key[len("submodule."):].rpartition(".")
        sections.setdefault(name, {})[field.lower()] = value.strip()
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            lines = fh.read().split("\n")
    except OSError as exc:
        raise UsageError("cannot read %s: %s" % (path, exc))
    out = {}
    for sec in sections.values():
        if "path" not in sec or "url" not in sec:
            continue
        url_line = 0
        for n, raw in enumerate(lines, 1):
            if sec["url"] in raw and re.search(r"\burl\b", raw, re.I):
                url_line = n
                break
        out[sec["path"]] = (sec["url"], url_line)
    return out


def curated_repos(path):
    """Names with a `### repos/<name>` heading in CURATION.md (missing file = none)."""
    if not path or not os.path.isfile(path):
        return set()
    with open(path, "r", encoding="utf-8", errors="replace") as fh:
        return set(re.findall(r"^###[ \t]+repos/(\S+)[ \t]*$", fh.read(), re.M))


def lock_sources(root):
    """Source names (directory names under repos/) recorded in <root>/grid.lock.
    A missing or unreadable lock is the empty set: it vouches for nothing."""
    try:
        with open(os.path.join(root, "grid.lock"), "r", encoding="utf-8") as fh:
            doc = json.load(fh)
        return {e["source"] for e in doc["entries"]
                if isinstance(e, dict) and isinstance(e.get("source"), str)}
    except (OSError, ValueError, KeyError, TypeError):
        return set()


def source_checks(scan, root, curation_path, baseline):
    """One `source-not-allowed` / `source-uncurated` finding per upstream repo that
    a target lives under, reported at `.gitmodules:<line of its url>`. Severity is
    `high` for a repo named in the baseline, else the policy's (low) default, so an
    overlay-only repo warns where a baseline repo blocks. No .gitmodules at all
    means nothing to check, and neither does one that declares no submodule at
    all (a checkout that does not use submodules). Otherwise a repo with no entry
    in .gitmodules is a plain directory nobody vetted the source of: it is
    `source-not-allowed` at `repos/<name>` too, unless grid.lock records it as an
    install source."""
    modules_file = os.path.join(root, ".gitmodules")
    if not os.path.isfile(modules_file) or not scan.repos:
        return
    modules = parse_gitmodules(modules_file)
    if not modules:
        return
    curated = curated_repos(curation_path)
    base = {b.lower() for b in baseline or ()}
    locked = lock_sources(root)
    for name in sorted(scan.repos):
        entry = modules.get("repos/" + name)
        if entry is None:
            if name not in locked:
                msg = ("repos/%s is not listed in .gitmodules and grid.lock has no source for it"
                       % name)
                sev = "high" if name.lower() in base else scan.policy.builtin["source-not-allowed"]
                scan._add("source-not-allowed", sev, "repos/" + name, 0, "other", "upstream",
                          msg, raw_line="repos/" + name)
            continue
        url, line = entry
        ok, why = check_url(scan.policy, url)
        for rule, bad, msg in (
                ("source-not-allowed", not ok, "submodule source not allowed: " + why),
                ("source-uncurated", name not in curated,
                 "repos/%s has no `### repos/%s` heading in CURATION.md" % (name, name))):
            if bad:
                sev = "high" if name.lower() in base else scan.policy.builtin[rule]
                scan._add(rule, sev, ".gitmodules", line, "other", "upstream", msg,
                          excerpt="url = " + url, raw_line="url = " + url)


# --------------------------------------------------------------------------
# Allowlist application, ordering, output
# --------------------------------------------------------------------------

def apply_allowlist(scan, entries, allow_display):
    """Mark suppressed findings, then add allow-unused / allow-stale notes."""
    pol = scan.policy
    for f in scan.findings:
        for e in entries:
            if e.matches(f):
                f["allowed"] = True
                e.used = True
    extra = []
    for e in entries:
        if e.used:
            continue
        stale = None
        if e.contains is None:
            # A hash-pinned entry whose file changed: the finding is at its real
            # severity again (it was never marked allowed) and we say why.
            for f in scan.findings:
                if f["rule"] == e.rule and f["path"] == e.path and f["sha256"] != e.sha256:
                    stale = f
                    break
        if stale is not None:
            extra.append(("allow-stale", stale["path"], 0, stale["class"], stale["tier"],
                          "allowlist entry %d (%s) no longer matches: file content changed"
                          % (e.index, e.rule)))
        else:
            extra.append(("allow-unused", allow_display, 0, "other", "owned",
                          "allowlist entry %d (%s %s) matched nothing in this run"
                          % (e.index, e.rule, e.path)))
    for rule, path, line, cls, tier, msg in extra:
        scan._add(rule, pol.builtin[rule], path, line, cls, tier, msg)


def sort_findings(findings):
    return sorted(findings, key=lambda f: (0 if f["severity"] == "high" else 1,
                                           f["path"], f["line"], f["rule"], f["excerpt"]))


def public(f):
    """A finding without the private matching fields, in the documented key order."""
    keys = ("rule", "severity", "path", "line", "class", "tier", "message",
            "excerpt", "allowed", "downgraded", "sha256")
    return {k: f[k] for k in keys}


def render_text(findings, counts, scan, quiet, show_allowed):
    lines = []
    shown = []
    for f in findings:
        if f["allowed"] and not show_allowed:
            continue
        if quiet and f["severity"] == "low" and not f["allowed"]:
            keep = (f["rule"] in ALWAYS_PRINT_LOW
                    or (f["tier"] == "upstream" and f["downgraded"] is not None))
            if not keep:
                continue
        shown.append(f)
    width = max([len(f["rule"]) for f in shown] or [0])
    for f in shown:
        label = "ALLOW" if f["allowed"] else f["severity"].upper()
        loc = escape_text(f["path"]) + (":%d" % f["line"] if f["line"] else "")
        msg = f["message"]
        if f["downgraded"]:
            msg += " (downgraded: %s)" % f["downgraded"]
        lines.append("%-5s %-*s  %s  %s" % (label, width, f["rule"], loc, msg))
        if f["excerpt"]:
            lines.append("      " + f["excerpt"])
    verdict = "BLOCKED" if counts["high"] else "ok"
    lines.append("audit: %d targets, %d files, %d high, %d low, %d allowed -> %s"
                 % (scan.targets, scan.files, counts["high"], counts["low"],
                    counts["allowed"], verdict))
    return "\n".join(lines) + "\n"


def default_grid_dir():
    return os.environ.get("GRID_DIR") or os.path.dirname(_HERE)


def build_parser():
    p = argparse.ArgumentParser(
        prog="audit.py", description="Static vetting scan of skills, agents, rules and hooks.")
    p.add_argument("targets", metavar="TARGET", nargs="*",
                   help="a directory (scanned recursively) or a single file")
    p.add_argument("--root", help="base for reported paths, allowlist globs and owned/upstream "
                                  "tiering (default: $GRID_DIR, else this script's repo)")
    p.add_argument("--grid-dir", help="where policy.yaml and CURATION.md are read from "
                                      "(default: $GRID_DIR, else this script's repo)")
    p.add_argument("--policy", help="override <grid-dir>/policy.yaml")
    p.add_argument("--allow", help="override <grid-dir>/CURATION.md (missing = empty allowlist)")
    p.add_argument("--format", choices=("text", "json"), default="text")
    p.add_argument("--quiet", action="store_true", help="text mode: hide LOW findings")
    p.add_argument("--show-allowed", action="store_true", help="include allowlisted findings")
    p.add_argument("--baseline", help="wiring manifest; repos it names get source-not-allowed and "
                                      "source-uncurated at high instead of low")
    p.add_argument("--check-url", metavar="URL",
                   help="no scan: exit 0 if URL's host and owner/repo are allowed by policy "
                        "`sources`, else 1 (prints why)")
    return p


def run(args):
    grid_dir = args.grid_dir or default_grid_dir()
    root = args.root or default_grid_dir()
    if not os.path.isdir(root):
        raise UsageError("--root %s is not a directory" % root)
    policy = Policy(args.policy or os.path.join(grid_dir, "policy.yaml"))
    if args.check_url is not None:                 # source-policy query, no scan
        ok, why = check_url(policy, args.check_url)
        sys.stdout.write("%s: %s\n" % ("ok" if ok else "not allowed", why))
        return 0 if ok else 1
    if not args.targets:
        raise UsageError("no TARGET given")
    allow_path = args.allow or os.path.join(grid_dir, "CURATION.md")
    entries = load_allowlist(allow_path, policy)

    for t in args.targets:                     # a missing target is an error, not a skip
        if not os.path.exists(t):
            raise UsageError("target does not exist: %s" % t)

    scan = Scan(policy, root)
    for t in args.targets:
        scan.scan_target(t)

    baseline = baseline_repos(args.baseline) if args.baseline else None
    source_checks(scan, scan.root, allow_path, baseline)

    allow_rel = scan._rel_root(os.path.realpath(allow_path))
    apply_allowlist(scan, entries, allow_rel if allow_rel is not None else "CURATION.md")

    findings = sort_findings(scan.findings)
    counts = {
        "high": sum(1 for f in findings if f["severity"] == "high" and not f["allowed"]),
        "low": sum(1 for f in findings if f["severity"] == "low" and not f["allowed"]),
        "allowed": sum(1 for f in findings if f["allowed"]),
    }
    visible = [f for f in findings if args.show_allowed or not f["allowed"]]

    if args.format == "json":
        doc = {"version": 1, "policy_sha256": policy.sha256,
               "targets": scan.targets, "files": scan.files, "counts": counts,
               "findings": [public(f) for f in visible]}
        sys.stdout.write(json.dumps(doc, indent=2) + "\n")   # ensure_ascii: stays escaped
    else:
        sys.stdout.write(render_text(findings, counts, scan, args.quiet, args.show_allowed))
    return 1 if counts["high"] else 0


def main(argv=None):
    try:
        args = build_parser().parse_args(argv)   # argparse exits 2 on bad usage
        return run(args)
    except BudgetExceeded as exc:
        sys.stderr.write("audit: %s\n" % exc)
        return 2
    except UsageError as exc:
        sys.stderr.write("audit: error: %s\n" % exc)
        return 2
    except Exception as exc:                     # noqa: BLE001 - deliberate catch-all
        # An unexpected crash (unreadable file, pathological input) must not look
        # like exit 1 ("a high finding"): that is the code a caller treats as a
        # verdict. 2 is "the scan did not complete".
        sys.stderr.write("audit: internal error: %s: %s\n" % (type(exc).__name__, exc))
        return 2


if __name__ == "__main__":
    sys.exit(main())
