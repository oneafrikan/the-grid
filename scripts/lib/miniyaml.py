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
_AMBIGUOUS_WORDS = {"null", "~", "yes", "no", "on", "off"}
_FLOAT_RE = re.compile(r"[-+]?(?:\d+\.\d*|\.\d+)(?:[eE][-+]?\d+)?$|[-+]?\d+[eE][-+]?\d+$")
_INT_RE = re.compile(r"-?\d+$")
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
}


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
    s = raw.strip()
    if s == "":
        raise ParseError(lineno, "empty value")
    if s[0] in _BAD_START:
        raise ParseError(lineno, _BAD_START[s[0]])
    if s in ("true", "false"):
        return s == "true"
    if _INT_RE.match(s):
        return int(s)
    if s.lower() in _AMBIGUOUS_WORDS or _FLOAT_RE.match(s):
        raise ParseError(lineno, "ambiguous bare value %r (quote it to get a string)" % s)
    if ": " in s or s.endswith(":"):
        raise ParseError(lineno, "bare string contains ': ' (quote it)")
    return s


def _strip_comment(text):
    """Cut a trailing ` # comment` from a BARE text (no quotes involved)."""
    m = re.search(r"(?:^|\s)#", text)
    return text[:m.start()] if m else text


def _only_comment_left(rest, lineno):
    """After a quoted or flow value the remainder must be blank or a comment."""
    rest = rest.strip()
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
    return _bare_scalar(text[start:i], lineno), i


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
        key, i = _flow_value(text, i, lineno, ":,}")
        i = _skip_ws(text, i)
        if text[i:i + 1] != ":":
            raise ParseError(lineno, "expected ':' in inline map")
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
    text = text.lstrip()
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
    return _bare_scalar(_strip_comment(text), lineno)


# --- block structure ---------------------------------------------------------

def _split_key(text, lineno):
    """If `text` is `key: rest` (or `key:`) return (key, rest); else None."""
    c = text[:1]
    if c in "'\"":
        reader = _read_single_quoted if c == "'" else _read_double_quoted
        key, end = reader(text, 0, lineno)
        after = text[end:]
        if after.startswith(":") and (len(after) == 1 or after[1] in " \t"):
            return key, after[1:]
        return None
    if c in "[{":
        return None  # an inline collection, never a key
    bare = _strip_comment(text)
    m = re.search(r":(?:\s|$)", bare)
    if not m:
        return None
    key = bare[:m.start()].strip()
    if key == "":
        raise ParseError(lineno, "empty key")
    if key[0] in _BAD_START:
        raise ParseError(lineno, _BAD_START[key[0]])
    # Whatever follows the colon, including a trailing comment, is the value text.
    return key, text[m.start() + 1:]


class _Parser:
    def __init__(self, text):
        # lines: [lineno, indent, text] with blanks and comment-only lines dropped.
        self.lines = []
        for n, raw in enumerate(text.split("\n"), 1):
            raw = raw.rstrip("\r")
            stripped = raw.lstrip(" \t")
            if stripped == "" or stripped.startswith("#"):
                continue
            lead = raw[:len(raw) - len(stripped)]
            if "\t" in lead:
                raise ParseError(n, "tab in indentation (use spaces)")
            self.lines.append([n, len(lead), stripped.rstrip()])
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
            if _strip_comment(rest).strip() == "":
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
    try:
        return _Parser(text).parse_document()
    except RecursionError:
        # Pathologically nested flow collections / blocks: a parse error like any
        # other, not an interpreter traceback (callers expect ParseError only).
        raise ParseError(0, "nesting too deep")
