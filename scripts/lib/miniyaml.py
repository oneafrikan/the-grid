"""miniyaml - a restricted-YAML reader (Python 3 stdlib only).

Why this exists: PyYAML is not in the standard library, and the vetting scanner
(scripts/audit.py) has to run on a bare machine, in CI and at install time,
before any virtualenv exists. policy.yaml and the `audit-allow` block of
CURATION.md are therefore written in a small, strict subset of YAML that this
module reads. Anything outside the subset is a hard ParseError that names the
line; it is never silently mis-parsed.

Supported
  * `#` comments (a whole line, or after whitespace outside quotes); blank lines
  * block maps    `key: value`, or `key:` followed by a more-indented block
  * block lists   `- scalar`, or `- key: value` opening a map item whose other
                  keys are indented to line up under the first key
  * inline lists  `[a, 'b c']` and inline maps `{k: v}` (one line, may nest;
                  quotes are respected when splitting on commas)
  * scalars       single-quoted ('' is an escaped quote, backslashes are literal,
                  which is why every regex in policy.yaml is single-quoted),
                  double-quoted (JSON escapes), true/false, integers, bare strings
  * indentation by spaces only, any consistent width

Rejected (ParseError)
  anchors/aliases, tags, block scalars (| and >), flow collections spanning
  lines, tab indentation, duplicate keys, floats/null/yes/no (bare words whose
  meaning differs between YAML versions), bare strings containing ': '.
  The governing rule: if PyYAML would read a bare scalar as a different value
  (True/FALSE, 010, 0x1F, 1_0, +1, 1:30, 2026-10-11, .inf ...) or fail on it
  (`<<`, `- ` inside a value, `#` inside a flow collection, TAB before `#`), it
  is a ParseError here too. Quote the value to get a string. Likewise refused: document
  markers (`---`, `...`), a line break other than LF/CRLF (lone CR, NEL, U+2028/9, VT, FF),
  a bracket inside a bare inline value, a bare inline-map key touching its colon (`{a:b}`)
  and a non-scalar inline-map key. Padding is ASCII space and TAB only. Also: nesting that
  is too deep, or an integer too long to convert, is a ParseError (callers
  catch only ParseError); a leading UTF-8 BOM is ignored, as PyYAML does.

API
  loads(text) -> dict | list | None (None for an empty document)
  ParseError(line, msg)   .line is 1-based, str() is "line N: msg"
"""
import json
import re


class ParseError(Exception):
    """A syntax error, with the 1-based line number it occurred on."""

    def __init__(self, line, msg):
        super().__init__("line %d: %s" % (line, msg))
        self.line = line
        self.msg = msg


# Bare words PyYAML would turn into non-strings (null, booleans other than
# true/false, floats). Reading them as strings would make this reader disagree
# with PyYAML, so they are refused instead. Quote them to get a string.
# `=` and `<<` are YAML 1.1 value/merge tags PyYAML has no constructor for.
_AMBIGUOUS_WORDS = {"null", "~", "yes", "no", "on", "off", "=", "<<"}
# [0-9], never \d: \d also matches Arabic-Indic and other Unicode digits, which
# PyYAML reads as strings.
_FLOAT_RE = re.compile(r"[-+]?(?:[0-9][0-9_]*\.[0-9_]*|\.[0-9_]+)(?:[eE][-+]?[0-9]+)?$|[-+]?[0-9][0-9_]*[eE][-+]?[0-9]+$")
_INT_RE = re.compile(r"-?(?:0|[1-9][0-9]*)$")  # the only integer spelling both readers agree on
# Words PyYAML reads as a number or date but _INT_RE does not accept: leading zero
# (octal), `_` separators, a leading `+`, 0x/0o/0b prefixes, sexagesimal (1:30),
# dates and timestamps, .inf/.nan. Refused rather than read as strings.
_NUMBERISH_RES = (
    re.compile(r"[-+]?[0-9][0-9_]*$"),
    re.compile(r"[-+]?0[xXoObB]"),
    re.compile(r"[-+]?[0-9][0-9_]*(?::[0-9]+)+(?:\.[0-9_]*)?$"),
    re.compile(r"[0-9]{4}-[0-9]{1,2}-[0-9]{1,2}(?:[Tt ].*)?$"),
    re.compile(r"[-+]?\.(?:inf|nan)$", re.I),
)
# Line breaks. Only LF and CRLF end a line here; PyYAML also ends one at a lone CR, NEL (U+0085),
# U+2028 and U+2029 (and rejects VT/FF), so any of those is refused rather than read as text
# (a comment could otherwise swallow the lines PyYAML sees after it).
_LINE_BREAK_RE = re.compile("\r(?!\n)|[\x0b\x0c\x85\u2028\u2029]")
# First characters that start YAML features this reader does not implement.
_BAD_START = {
    "&": "anchors are not supported",
    "*": "aliases are not supported",
    "!": "tags are not supported",
    "|": "block scalars are not supported",
    ">": "block scalars are not supported",
    "@": "'@' cannot start a bare scalar (quote it)",
    "`": "'`' cannot start a bare scalar (quote it)",
    "%": "'%' cannot start a bare scalar (quote it)",
    # Flow indicators: PyYAML refuses a plain scalar that starts with one.
    "]": "']' cannot start a bare scalar (quote it)",
    "}": "'}' cannot start a bare scalar (quote it)",
    ",": "',' cannot start a bare scalar (quote it)",
}
# Characters PyYAML refuses anywhere in a stream (its reader allows TAB, LF, CR, printable
# ASCII and most of the rest); C0 controls, DEL, the C1 block (U+0085 is a line break, handled
# above), lone surrogates and U+FFFE/U+FFFF. VT and FF are caught by the line-break check.
_NONPRINTABLE_RE = re.compile("[\x00-\x08\x0e-\x1f\x7f-\x84\x86-\x9f\ud800-\udfff\ufffe\uffff]")


# Padding is ASCII space and TAB only. str.strip() also removes NBSP, U+3000, U+2003 ...,
# which PyYAML keeps as data (`k: 1<NBSP>` is the string '1\xa0', not the integer 1).
_WS = " \t"

# --- scalar helpers ----------------------------------------------------------

def _read_single_quoted(text, pos, lineno):
    """text[pos] is the opening '. Return (string, index just past the closing ')."""
    out = []
    i = pos + 1
    while i < len(text):
        c = text[i]
        if c == "'":
            if text[i + 1:i + 2] == "'":  # '' is an escaped quote
                out.append("'")
                i += 2
                continue
            return "".join(out), i + 1
        out.append(c)
        i += 1
    raise ParseError(lineno, "unterminated single-quoted string")


def _read_double_quoted(text, pos, lineno):
    """text[pos] is the opening ". Return (string, index just past the closing ")."""
    i = pos + 1
    while i < len(text):
        c = text[i]
        if c == "\\":
            i += 2
            continue
        if c == '"':
            token = text[pos:i + 1]
            try:
                return json.loads(token), i + 1  # JSON escapes, as documented
            except ValueError:
                raise ParseError(lineno, "bad escape in double-quoted string")
        i += 1
    raise ParseError(lineno, "unterminated double-quoted string")


def _bare_scalar(raw, lineno):
    """Resolve an unquoted scalar: true/false, integer, or a plain string."""
    s = raw.strip(_WS)
    if s == "":
        raise ParseError(lineno, "empty value")
    if s[0] in _BAD_START:
        raise ParseError(lineno, _BAD_START[s[0]])
    if s in ("true", "false"):
        return s == "true"
    if s.lower() in ("true", "false"):
        # PyYAML reads True/FALSE as booleans; returning the string would disagree.
        raise ParseError(lineno, "ambiguous bare value %r (write true/false, or quote it)" % s)
    if s in ("-", "?") or s.startswith(("- ", "? ")):
        # A nested sequence entry or a complex-key indicator: PyYAML builds a
        # collection (or fails) where this reader would keep a string.
        raise ParseError(lineno, "a '- ' or '? ' indicator is not allowed inside a value")
    if _INT_RE.match(s):
        # Same limit as CPython 3.11+ (4300 digits), enforced here so older Pythons
        # (3.9 parses any length) reject exactly the same inputs: one answer everywhere.
        if len(s.lstrip("+-")) > 4300:
            raise ParseError(lineno, "integer too long")
        try:
            return int(s)
        except ValueError:  # more digits than int() converts (4300 by default)
            raise ParseError(lineno, "integer too long")
    if (s.lower() in _AMBIGUOUS_WORDS or _FLOAT_RE.match(s)
            or any(rx.match(s) for rx in _NUMBERISH_RES)):
        raise ParseError(lineno, "ambiguous bare value %r (quote it to get a string)" % s)
    if ": " in s or s.endswith(":"):
        raise ParseError(lineno, "bare string contains ': ' (quote it)")
    return s


def _strip_comment(text, lineno=None):
    """Cut a trailing ` # comment` from a BARE text (no quotes involved).

    With `lineno`, a TAB before the `#` is a ParseError: PyYAML does not end a
    plain scalar there (it is an error or part of the scalar), so cutting would
    disagree. Callers that only look for emptiness pass no lineno.
    """
    if lineno is not None and "\t#" in text:
        raise ParseError(lineno, "TAB before '#': use a space to start a comment")
    m = re.search(r"(?:^|[ \t])#", text)
    return text[:m.start()] if m else text


def _only_comment_left(rest, lineno):
    """After a quoted or flow value the remainder must be blank or a comment."""
    rest = rest.strip(_WS)
    if rest and not rest.startswith("#"):
        raise ParseError(lineno, "unexpected text after value: %r" % rest[:30])


# --- flow (inline) collections -----------------------------------------------

def _skip_ws(text, i):
    while i < len(text) and text[i] in " \t":
        i += 1
    return i


def _flow_value(text, i, lineno, closers):
    """Parse one flow value starting at text[i]. Return (value, next index).

    `closers` is the set of characters that end a BARE scalar here (',' plus the
    enclosing bracket; ':' as well when reading a map key).
    """
    i = _skip_ws(text, i)
    if i >= len(text):
        raise ParseError(lineno, "flow collection spans lines or is unterminated")
    c = text[i]
    if c == "'":
        return _read_single_quoted(text, i, lineno)
    if c == '"':
        return _read_double_quoted(text, i, lineno)
    if c == "[":
        return _flow_list(text, i, lineno)
    if c == "{":
        return _flow_map(text, i, lineno)
    start = i
    while i < len(text) and text[i] not in closers:
        i += 1
    if i >= len(text):
        raise ParseError(lineno, "flow collection spans lines or is unterminated")
    raw = text[start:i]
    if re.search(r"[\[\]{}]", raw):
        # `[a:{}]`, `{a: x]}`: PyYAML nests or fails here; a bare scalar never holds a bracket.
        raise ParseError(lineno, "a bracket or brace inside an inline value (quote it)")
    if raw.startswith((":", "?")):
        # PyYAML reads a flow `?x` as a one-key map and rejects `:x`.
        raise ParseError(lineno, "an inline value cannot start with ':' or '?' (quote it)")
    if re.search(r"(?:^|[ \t])#", raw):
        # PyYAML ends or rejects a flow collection at a comment; reading it as part
        # of the scalar would disagree.
        raise ParseError(lineno, "'#' comment inside an inline collection")
    return _bare_scalar(raw, lineno), i


def _flow_list(text, i, lineno):
    """text[i] == '['. Return (list, index just past the closing ])."""
    items = []
    i = _skip_ws(text, i + 1)
    if text[i:i + 1] == "]":
        return items, i + 1
    while True:
        val, i = _flow_value(text, i, lineno, ",]")
        items.append(val)
        i = _skip_ws(text, i)
        c = text[i:i + 1]
        if c == ",":
            i += 1
        elif c == "]":
            return items, i + 1
        else:
            raise ParseError(lineno, "expected ',' or ']' in inline list")


def _flow_map(text, i, lineno):
    """text[i] == '{'. Return (dict, index just past the closing })."""
    out = {}
    i = _skip_ws(text, i + 1)
    if text[i:i + 1] == "}":
        return out, i + 1
    while True:
        key_at = _skip_ws(text, i)
        key, i = _flow_value(text, i, lineno, ":,}")
        if isinstance(key, (list, dict)):  # unhashable: `{[]: v}`, `{{a: b}: v}`
            raise ParseError(lineno, "an inline map key must be a scalar")
        i = _skip_ws(text, i)
        if text[i:i + 1] != ":":
            raise ParseError(lineno, "expected ':' in inline map")
        if text[key_at:key_at + 1] not in ("'", '"') and text[i + 1:i + 2] not in (" ", "\t"):
            # `{a:true}`: PyYAML reads the key as the whole word `a:true`. Only a quoted key
            # may touch its colon (JSON style).
            raise ParseError(lineno, "a bare inline map key needs a space after its ':'")
        val, i = _flow_value(text, i + 1, lineno, ",}")
        if key in out:
            raise ParseError(lineno, "duplicate key %r" % key)
        out[key] = val
        i = _skip_ws(text, i)
        c = text[i:i + 1]
        if c == ",":
            i += 1
        elif c == "}":
            return out, i + 1
        else:
            raise ParseError(lineno, "expected ',' or '}' in inline map")


def _parse_value(text, lineno):
    """Parse the text after `key:` or `- ` (a scalar or an inline collection)."""
    text = text.lstrip(_WS)
    c = text[:1]
    if c == "'":
        val, end = _read_single_quoted(text, 0, lineno)
        _only_comment_left(text[end:], lineno)
        return val
    if c == '"':
        val, end = _read_double_quoted(text, 0, lineno)
        _only_comment_left(text[end:], lineno)
        return val
    if c == "[":
        val, end = _flow_list(text, 0, lineno)
        _only_comment_left(text[end:], lineno)
        return val
    if c == "{":
        val, end = _flow_map(text, 0, lineno)
        _only_comment_left(text[end:], lineno)
        return val
    return _bare_scalar(_strip_comment(text, lineno), lineno)


# --- block structure ---------------------------------------------------------

def _no_tab_after_colon(rest, lineno):
    """PyYAML refuses a TAB in the padding between a key's colon and its value."""
    if "\t" in rest[:len(rest) - len(rest.lstrip(_WS))]:
        raise ParseError(lineno, "tab after ':' (use a space)")


def _split_key(text, lineno):
    """If `text` is `key: rest` (or `key:`) return (key, rest); else None."""
    c = text[:1]
    if c in "'\"":
        reader = _read_single_quoted if c == "'" else _read_double_quoted
        key, end = reader(text, 0, lineno)
        after = text[end:]
        if after.startswith(":") and (len(after) == 1 or after[1] in " \t"):
            _no_tab_after_colon(after[1:], lineno)
            return key, after[1:]
        return None
    if c in "[{":
        return None  # an inline collection, never a key
    bare = _strip_comment(text)
    m = re.search(r":(?:[ \t]|$)", bare)
    if not m:
        return None
    key = bare[:m.start()].strip(_WS)
    if key == "":
        raise ParseError(lineno, "empty key")
    if key[0] in _BAD_START:
        raise ParseError(lineno, _BAD_START[key[0]])
    if key == "<<":
        raise ParseError(lineno, "merge keys ('<<') are not supported")
    # PyYAML types a bare key like a value (`1:` is an int key, `true:` a bool),
    # this reader always keeps a string: refuse any key that would not be one.
    if not isinstance(_bare_scalar(key, lineno), str):
        raise ParseError(lineno, "ambiguous bare key %r (quote it to get a string)" % key)
    # Whatever follows the colon, including a trailing comment, is the value text.
    _no_tab_after_colon(text[m.start() + 1:], lineno)
    return key, text[m.start() + 1:]


class _Parser:
    def __init__(self, text):
        if text.startswith("\ufeff"):
            text = text[1:]  # one leading BOM, as PyYAML (Windows editors add it)
        m = _LINE_BREAK_RE.search(text)
        if m:
            raise ParseError(text.count("\n", 0, m.start()) + 1,
                             "line break character %r is not supported (use LF or CRLF)" % m.group())
        m = _NONPRINTABLE_RE.search(text)
        if m:
            raise ParseError(text.count("\n", 0, m.start()) + 1,
                             "control character %r is not allowed" % m.group())
        self.lineno = 1  # line being parsed, for errors raised far from it (RecursionError)
        # lines: [lineno, indent, text] with blanks and comment-only lines dropped.
        self.lines = []
        for n, raw in enumerate(text.split("\n"), 1):
            raw = raw[:-1] if raw.endswith("\r") else raw  # the CR of a CRLF
            # Document markers: PyYAML starts a document there (`--- {a: b}` is a map).
            if raw[:3] in ("---", "...") and raw[3:4] in ("", " ", "\t"):
                raise ParseError(n, "document markers (--- and ...) are not supported")
            stripped = raw.lstrip(" \t")
            if stripped == "" or stripped.startswith("#"):
                continue
            lead = raw[:len(raw) - len(stripped)]
            if "\t" in lead:
                raise ParseError(n, "tab in indentation (use spaces)")
            self.lines.append([n, len(lead), stripped.rstrip(_WS)])
        self.pos = 0

    def parse_document(self):
        if not self.lines:
            return None
        value = self.parse_block(self.lines[0][1])
        if self.pos < len(self.lines):
            n, _, _ = self.lines[self.pos]
            raise ParseError(n, "unexpected indentation")
        return value

    def parse_block(self, indent):
        """Parse the block starting at self.pos, whose lines sit at `indent`."""
        text = self.lines[self.pos][2]
        if text == "-" or text.startswith("- "):
            return self.parse_list(indent)
        return self.parse_map(indent)

    def parse_map(self, indent):
        out = {}
        while self.pos < len(self.lines):
            n, ind, text = self.lines[self.pos]
            self.lineno = n
            if ind < indent:
                break
            if ind > indent:
                raise ParseError(n, "unexpected indentation")
            if text == "-" or text.startswith("- "):
                raise ParseError(n, "list item where a 'key: value' was expected")
            kv = _split_key(text, n)
            if kv is None:
                raise ParseError(n, "expected 'key: value'")
            key, rest = kv
            if key in out:
                raise ParseError(n, "duplicate key %r" % key)
            self.pos += 1
            if _strip_comment(rest).strip(_WS) == "":
                # `key:` alone: a more-indented block follows, or the value is empty.
                if self.pos < len(self.lines) and self.lines[self.pos][1] > indent:
                    out[key] = self.parse_block(self.lines[self.pos][1])
                else:
                    out[key] = None
            else:
                out[key] = _parse_value(rest, n)
        return out

    def parse_list(self, indent):
        out = []
        while self.pos < len(self.lines):
            n, ind, text = self.lines[self.pos]
            self.lineno = n
            if ind < indent:
                break
            if ind > indent:
                raise ParseError(n, "unexpected indentation")
            if not (text == "-" or text.startswith("- ")):
                break  # a sibling key of the enclosing map; the caller reports it
            rest = text[1:]
            body = rest.lstrip(" ")
            if body == "" or body.startswith("#"):
                raise ParseError(n, "a bare '-' item with a nested block is not supported")
            child_indent = indent + 1 + (len(rest) - len(body))
            if _split_key(body, n) is not None:
                # `- key: value`: re-seat the line as the first key of a map whose
                # other keys must be indented to the same column.
                self.lines[self.pos] = [n, child_indent, body]
                out.append(self.parse_map(child_indent))
            else:
                self.pos += 1
                out.append(_parse_value(body, n))
        return out


def loads(text):
    """Parse restricted YAML text. Raises ParseError(line, msg) on anything else."""
    parser = _Parser(text)
    try:
        return parser.parse_document()
    except RecursionError:
        # Pathologically nested flow collections / blocks: a parse error like any
        # other, not an interpreter traceback (callers expect ParseError only).
        raise ParseError(parser.lineno, "nesting too deep")
