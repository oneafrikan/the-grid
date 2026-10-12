"""fmyaml - a structure scanner for the YAML frontmatter of SKILL.md / agent .md files.

Python 3 standard library only. Why this exists: the vetting scanner (scripts/audit.py)
must decide where a `hooks` key sits in a frontmatter written by an UNTRUSTED upstream
author, on a bare machine (no PyYAML guaranteed, see audit.sh). A line-based text
heuristic for "where does the hooks block start and stop" was bypassed round after round
(block scalars containing `...` or `---`, flow mappings, anchors, CR line breaks), so this
module reads the frontmatter as YAML instead. It does not build Python values; it builds a
tree of nodes that remember the line each token sits on, which is all the scanner needs.

Not miniyaml: scripts/lib/miniyaml.py is a deliberately restricted reader for policy files
and refuses block scalars, anchors and multi-line flow collections, all of which real
frontmatter uses. This module accepts the YAML an author can write in a frontmatter
(block and flow collections, block scalars with indicators, quoted scalars with escapes and
line folding, multi-line plain scalars, anchors, aliases, tags, `?` complex keys, comments)
and FAILS CLOSED on anything it cannot read: the caller treats a FMError as a finding.

Safety budgets (a hostile input must cost seconds, never hours):
  * frontmatter text over MAX_BYTES is not parsed (fail closed)
  * nesting deeper than MAX_DEPTH, or more than MAX_NODES nodes, is an error
  * aliases are never expanded, so an alias bomb costs nothing; an anchored mapping that
    holds a `hooks` key is found where it is DEFINED, wherever it is aliased or merged
  * every regex here is linear (no adjacent unbounded quantifiers on the same characters)

Known limits (all fail closed, none silent): a plain scalar that continues over several
lines INSIDE a flow collection is an error, and so is a tab used for indentation.

API
  analyse(lines) -> Frontmatter | None   (None: the file has no frontmatter fence)
  Frontmatter.error   (line_index, message) when the frontmatter could not be read
  Frontmatter.hooks   [(key_node, value_node, colon_line, colon_col)] outermost `hooks` keys, any depth
  Frontmatter.token_lines   file line indexes holding the token `hooks` + colon
Line numbers in a Node are 0-based and relative to the frontmatter text (file line 1 is
frontmatter line 0); Frontmatter.base converts: file line index = node line + base.
"""
import bisect
import re

MAX_BYTES = 131072      # frontmatter text larger than this is not parsed (a real one is < 4 KiB)
MAX_DEPTH = 48          # nesting limit (also bounds recursion)
MAX_NODES = 20000       # node budget

# --- linear regexes ----------------------------------------------------------
_WSRUN = re.compile(r"[ \t]*")
# End of a plain scalar's key position in BLOCK context: a comment start (whitespace then #)
# or a colon followed by whitespace/end. Each alternative is one or two characters wide, so
# a long whitespace run costs O(n) in total, not O(n^2).
_KEY_END = re.compile(r"[ \t]#|:(?=[ \t\n]|\Z)")
# The same for a plain scalar inside a flow collection.
_FLOW_PLAIN_END = re.compile(r"[,\[\]{}\n]|[ \t]#|:(?=[ \t\n,\[\]{}]|\Z)")
_NAME = re.compile(r"[^\s,\[\]{}:]+")                  # anchor / alias name
_TAG = re.compile(r"!(?:<[^>\s]*>|[^\s,\[\]{}]*)")     # !, !!str, !e!x, !<verbatim>
_DQ_SPECIAL = re.compile(r'["\\]')
_DOCMARK_INSIDE = re.compile(r"\n(?:---|\.\.\.)(?=[ \t\n]|\Z)")
# The token the backstop looks for: `hooks` then optional quote, blanks, a colon.
_HOOKS_TOKEN = re.compile(r"hooks[\"']?[ \t]*:")
_HEX = frozenset("0123456789abcdefABCDEF")
_ESCAPES = {"0": "\0", "a": "\a", "b": "\b", "t": "\t", "\t": "\t", "n": "\n", "v": "\v",
            "f": "\f", "r": "\r", "e": "\x1b", " ": " ", '"': '"', "/": "/", "\\": "\\",
            "N": "\x85", "_": "\xa0", "L": " ", "P": " "}
_FLOW_IND = ",[]{}"


class FMError(Exception):
    """The frontmatter could not be read; `line` is 0-based within the frontmatter text."""

    def __init__(self, line, msg):
        super().__init__("line %d: %s" % (line + 1, msg))
        self.line = line
        self.msg = msg


class Node:
    """One YAML node. kind: scalar | null | alias | seq | map.

    scalar: style plain|single|double|block, value (decoded text; for a multi-line scalar a
            rough join, it is only ever compared for single-line scalars)
    seq:    items [Node];  map: pairs [(key Node, value Node, colon_line, colon_col)]
    flow:   True for a [..] / {..} collection;  props: True when an anchor or tag was written
    line/col: where the node starts; end_line/end_col: just past its last token (for a
    scalar that is the end of its text on end_line).
    """
    __slots__ = ("kind", "style", "line", "col", "end_line", "end_col", "value",
                 "props", "flow", "items", "pairs")

    def __init__(self, kind, line, col, end_line, end_col, style=None, value=None):
        self.kind = kind
        self.style = style
        self.line = line
        self.col = col
        self.end_line = end_line
        self.end_col = end_col
        self.value = value
        self.props = False
        self.flow = False
        self.items = []
        self.pairs = []


class Frontmatter:
    def __init__(self):
        self.base = 1            # file line index of frontmatter line 0
        self.end = None          # file line index of the closing fence (None: unterminated)
        self.error = None        # (file line index, message) when unreadable
        self.root = None
        self.hooks = []          # [(key Node, value Node, colon line, colon col)]
        self.token_lines = []    # file line indexes holding `hooks` + colon (backstop)


class _Parser:
    def __init__(self, text):
        self.s = text
        self.n = len(text)
        # starts[i] = offset of line i; the text always ends in "\n" so the last start == n.
        starts = [0]
        i = text.find("\n")
        while i != -1:
            starts.append(i + 1)
            i = text.find("\n", i + 1)
        self.starts = starts
        self.nodes = 0

    # -- positions ---------------------------------------------------------
    def line_of(self, pos):
        return bisect.bisect_right(self.starts, pos) - 1

    def col_of(self, pos):
        return pos - self.starts[self.line_of(pos)]

    def eol(self, pos):
        """Offset of the newline that ends the line holding `pos`."""
        li = self.line_of(pos)
        return self.starts[li + 1] - 1 if li + 1 < len(self.starts) else self.n

    def err(self, pos, msg):
        raise FMError(self.line_of(min(pos, max(self.n - 1, 0))), msg)

    def new(self, kind, pos, end_pos, **kw):
        self.nodes += 1
        if self.nodes > MAX_NODES:
            self.err(pos, "too many nodes")
        sl = self.line_of(pos)
        el = self.line_of(max(end_pos - 1, pos)) if end_pos > pos else sl
        end_col = end_pos - self.starts[el] if end_pos > pos else self.col_of(pos)
        return Node(kind, sl, pos - self.starts[sl], el, end_col, **kw)

    def at_docmarker(self, pos):
        """`---` or `...` at column 0 followed by blank/end: a YAML document marker."""
        s = self.s
        if pos != self.starts[self.line_of(pos)]:
            return False
        return s[pos:pos + 3] in ("---", "...") and (pos + 3 >= self.n or s[pos + 3] in " \t\n")

    # -- skipping ----------------------------------------------------------
    def skip_inline(self, pos):
        return _WSRUN.match(self.s, pos).end()

    def is_blank_or_comment_at(self, q):
        """After inline whitespace: end of line or a comment (a `#` that follows whitespace)."""
        s = self.s
        return q >= self.n or s[q] == "\n" or (s[q] == "#" and (q == 0 or s[q - 1] in " \t\n"))

    def skip_to_content(self, pos, flow=False):
        """Next offset holding real content, past blanks, newlines and comments. In block
        context a tab in the indentation of a content line is an error (YAML forbids it)."""
        s, n = self.s, self.n
        crossed = pos == 0 or s[pos - 1] == "\n"
        while pos < n:
            pos = self.skip_inline(pos)
            if pos >= n:
                break
            c = s[pos]
            if c == "\n":
                pos += 1
                crossed = True
                continue
            if c == "#" and (pos == 0 or s[pos - 1] in " \t\n"):
                pos = self.eol(pos) + 1
                crossed = True
                continue
            if crossed and not flow:
                ls = self.starts[self.line_of(pos)]
                if "\t" in s[ls:pos]:
                    self.err(pos, "tab character in indentation")
            return pos
        return n

    def is_seq_start(self, pos):
        s = self.s
        return s[pos] == "-" and (pos + 1 >= self.n or s[pos + 1] in " \t\n")

    # -- properties, scalars -------------------------------------------------
    def skip_prop(self, pos):
        s = self.s
        if s[pos] == "&":
            m = _NAME.match(s, pos + 1)
            if not m:
                self.err(pos, "anchor without a name")
            return m.end()
        m = _TAG.match(s, pos)
        if not m:
            self.err(pos, "bad tag")
        return m.end()

    def read_quoted(self, pos):
        """(Node, end offset) for a '...' or "..." scalar at `pos`; may span lines."""
        s = self.s
        q = s[pos]
        if q == "'":
            out = []
            p = pos + 1
            while True:
                j = s.find("'", p)
                if j == -1:
                    self.err(pos, "unterminated single-quoted string")
                out.append(s[p:j])
                if s[j + 1:j + 2] == "'":
                    out.append("'")
                    p = j + 2
                    continue
                end = j + 1
                break
            style, value = "single", "".join(out)
        else:
            out = []
            p = pos + 1
            while True:
                m = _DQ_SPECIAL.search(s, p)
                if not m:
                    self.err(pos, "unterminated double-quoted string")
                out.append(s[p:m.start()])
                if m.group() == '"':
                    end = m.end()
                    break
                e = s[m.end():m.end() + 1]
                if e == "\n":                       # escaped line break: joins the lines
                    p = self.skip_inline(m.end() + 1)
                    continue
                if e in _ESCAPES:
                    out.append(_ESCAPES[e])
                    p = m.end() + 1
                    continue
                width = {"x": 2, "u": 4, "U": 8}.get(e)
                digits = s[m.end() + 1:m.end() + 1 + (width or 0)]
                if not width or len(digits) != width or not set(digits) <= _HEX:
                    self.err(m.start(), "bad escape in double-quoted string")
                try:
                    out.append(chr(int(digits, 16)))
                except (ValueError, OverflowError):
                    self.err(m.start(), "bad escape in double-quoted string")
                p = m.end() + 1 + width
            style, value = "double", "".join(out)
        if "\n" in s[pos:end] and _DOCMARK_INSIDE.search(s, pos, end):
            self.err(pos, "document marker inside a quoted scalar")
        return self.new("scalar", pos, end, style=style, value=value), end

    def plain_line(self, a, e):
        """Content end of a plain scalar line s[a:e]; a `: ` inside is an error (YAML does
        not allow a mapping value here), a ` #` starts a comment."""
        m = _KEY_END.search(self.s, a, e)
        if m is None:
            return len(self.s[a:e].rstrip(" \t")) + a
        if self.s[m.start()] == ":":
            self.err(m.start(), "mapping values are not allowed here")
        return a + len(self.s[a:m.start()].rstrip(" \t"))

    def parse_plain(self, pos, parent_indent):
        """A (possibly multi-line) plain scalar in block context."""
        s = self.s
        e = self.eol(pos)
        cend = self.plain_line(pos, e)
        parts = [s[pos:cend]]
        end = cend
        while True:
            q = self.skip_inline(end)
            if q < e and s[q] != "#":
                self.err(q, "unexpected text after a plain scalar")
            if q < e:                                   # trailing comment ends the scalar
                break
            r = e + 1                                   # look at the following lines
            while r < self.n:
                r2 = self.skip_inline(r)
                if r2 < self.n and s[r2] == "\n":
                    r = r2 + 1
                    continue
                break
            if r >= self.n:
                break
            r2 = self.skip_inline(r)
            ind = r2 - self.starts[self.line_of(r2)]
            if r2 >= self.n or ind <= parent_indent or s[r2] == "#" or self.at_docmarker(r2):
                break
            e = self.eol(r2)
            cend = self.plain_line(r2, e)
            parts.append(s[r2:cend])
            end = cend
        return self.new("scalar", pos, end, style="plain", value=" ".join(parts)), end

    def parse_block_scalar(self, pos, parent_indent):
        """`|` / `>` header and its indented content. Content lines are opaque text."""
        s = self.s
        e = self.eol(pos)
        q = pos + 1
        digit = None
        for _ in range(2):
            if q < e and s[q] in "+-":
                q += 1
            elif q < e and s[q] in "123456789" and digit is None:
                digit = int(s[q])
                q += 1
        q = self.skip_inline(q)
        if q < e and not (s[q] == "#" and s[q - 1] in " \t"):
            self.err(q, "bad block scalar header")
        indent = None
        if digit is not None:
            indent = (parent_indent if parent_indent >= 0 else 0) + digit
        li = self.line_of(pos) + 1
        last = self.line_of(pos)
        starts, text = self.starts, s
        while li < len(starts) - 1:
            a, b = starts[li], starts[li + 1] - 1
            line = text[a:b]
            if line.strip(" \t") == "":
                li += 1
                continue
            ind = len(line) - len(line.lstrip(" "))
            if self.at_docmarker(a):
                break
            if indent is None:
                if ind <= parent_indent:
                    break
                indent = ind
            elif ind < indent:
                break
            last = li
            li += 1
        end = starts[last + 1] - 1 if last > self.line_of(pos) else e
        node = self.new("scalar", pos, end, style="block", value="")
        node.end_line = last
        node.end_col = end - starts[last]
        return node, end

    # -- flow collections ----------------------------------------------------
    def skip_flow_ws(self, p):
        p = self.skip_to_content(p, flow=True)
        if p >= self.n:
            self.err(self.n - 1, "unterminated flow collection")
        if self.at_docmarker(p):
            self.err(p, "document marker inside a flow collection")
        return p

    def flow_item(self, p, depth):
        s = self.s
        props = False
        while s[p] in "&!":
            p = self.skip_flow_ws(self.skip_prop(p))
            props = True
        c = s[p]
        if c in "[{":
            node, end = self.parse_flow(p, depth + 1)
        elif c in "'\"":
            node, end = self.read_quoted(p)
        elif c == "*":
            m = _NAME.match(s, p + 1)
            if not m:
                self.err(p, "alias without a name")
            node, end = self.new("alias", p, m.end(), value=m.group()), m.end()
        elif c in _FLOW_IND or c == ":":
            self.err(p, "unexpected %r in a flow collection" % c)
        else:
            m = _FLOW_PLAIN_END.search(s, p)
            e = m.start() if m else self.n
            text = s[p:e].rstrip(" \t")
            if text == "" or text[0] in "%@`|>":
                self.err(p, "bad flow scalar")
            node, end = self.new("scalar", p, p + len(text), style="plain", value=text), p + len(text)
        if props:
            node.props = True
        return node, end

    def parse_flow(self, pos, depth):
        if depth > MAX_DEPTH:
            self.err(pos, "nesting too deep")
        s = self.s
        is_map = s[pos] == "{"
        closer = "}" if is_map else "]"
        node = self.new("map" if is_map else "seq", pos, pos + 1)
        node.flow = True
        p = pos + 1
        while True:
            p = self.skip_flow_ws(p)
            if s[p] == closer:
                p += 1
                break
            first, p = self.flow_item(p, depth)
            p = self.skip_flow_ws(p)
            if s[p] == ":":
                p = self.skip_flow_ws(p + 1)
                if s[p] in ",]}":
                    val = self.new("null", p, p)
                else:
                    val, p = self.flow_item(p, depth)
                    p = self.skip_flow_ws(p)
                pair = (first, val, first.end_line, first.end_col)
                if is_map:
                    node.pairs.append(pair)
                else:                                   # `[a: b]` is a one-pair mapping
                    one = Node("map", first.line, first.col, val.end_line, val.end_col)
                    one.flow = True
                    one.pairs.append(pair)
                    node.items.append(one)
            elif is_map:
                node.pairs.append((first, self.new("null", p, p), first.line, first.end_col))
            else:
                node.items.append(first)
            if s[p] == ",":
                p += 1
            elif s[p] != closer:
                self.err(p, "expected ',' or %r in a flow collection" % closer)
        node.end_line = self.line_of(p - 1)
        node.end_col = p - self.starts[node.end_line]
        return node, p

    # -- keys ----------------------------------------------------------------
    def read_key(self, pos, depth):
        """If an implicit (or `?`) key starts at `pos`, return (key Node, offset of its
        colon or None); otherwise None. Properties on the key are consumed."""
        s = self.s
        props = False
        p = pos
        while s[p] in "&!":
            p2 = self.skip_inline(self.skip_prop(p))
            if self.is_blank_or_comment_at(p2):
                return None                             # props on their own line: not a key line
            props = True
            p = p2
        c = s[p]
        if (c == "?" or c == "-") and (p + 1 >= self.n or s[p + 1] in " \t\n"):
            return None                                 # `- ` entry / `? ` key: handled by the callers
        node = None
        if c in "'\"":
            node, end = self.read_quoted(p)
        elif c in "[{":
            node, end = self.parse_flow(p, depth + 1)
        elif c == "*":
            m = _NAME.match(s, p + 1)
            if not m:
                self.err(p, "alias without a name")
            node, end = self.new("alias", p, m.end(), value=m.group()), m.end()
        elif c in ",]}%@`|>":
            return None
        else:
            e = self.eol(p)
            m = _KEY_END.search(s, p, e)
            if m is None or s[m.start()] != ":":
                return None
            text = s[p:m.start()].rstrip(" \t")
            if text == "":
                self.err(p, "empty key")
            node = self.new("scalar", p, p + len(text), style="plain", value=text)
            end = p + len(text)
        q = self.skip_inline(end)
        if q < self.n and s[q] == ":" and (q + 1 >= self.n or s[q + 1] in " \t\n"):
            if props:
                node.props = True
            return node, q
        return None

    # -- block structure -----------------------------------------------------
    def parse_node(self, pos, parent_indent, depth, same_line_block_ok):
        """Parse one node starting at `pos` (first non-blank character). `parent_indent`
        is the indent of the enclosing collection (-1 at the root). Block collections that
        start on the SAME line as their parent key are not allowed (`k: a: b` is invalid)
        unless `same_line_block_ok` (a sequence entry may start a compact mapping)."""
        if depth > MAX_DEPTH:
            self.err(pos, "nesting too deep")
        s = self.s
        props = False
        block_ok = same_line_block_ok
        while True:
            kp = self.read_key(pos, depth)              # a key (with its own properties) here?
            if kp is not None or s[pos] not in "&!":
                break
            p2 = self.skip_inline(self.skip_prop(pos))
            props = True
            if self.is_blank_or_comment_at(p2):         # properties alone on a line: node follows
                nxt = self.skip_to_content(p2)
                if nxt >= self.n or self.col_of(nxt) <= parent_indent or self.at_docmarker(nxt):
                    node = self.new("null", pos, p2)
                    node.props = True
                    return node, p2
                pos, block_ok = nxt, True
            else:
                pos = p2
        col = self.col_of(pos)
        c = s[pos]
        if kp is not None:
            if not block_ok:
                self.err(pos, "mapping values are not allowed here")
            node, end = self.parse_map(pos, col, depth, kp)
        elif self.is_seq_start(pos):
            if not block_ok:
                self.err(pos, "a block sequence is not allowed here")
            node, end = self.parse_seq(pos, col, depth)
        elif c == "?" and (pos + 1 >= self.n or s[pos + 1] in " \t\n"):
            if not block_ok:
                self.err(pos, "a mapping key is not allowed here")
            node, end = self.parse_map(pos, col, depth, None)
        elif c in "|>":
            node, end = self.parse_block_scalar(pos, parent_indent)
        elif c in ",]}%@`":
            self.err(pos, "unexpected %r" % c)
        elif c in "'\"":
            node, end = self.read_quoted(pos)
        elif c in "[{":
            node, end = self.parse_flow(pos, depth + 1)
        elif c == "*":
            m = _NAME.match(s, pos + 1)
            if not m:
                self.err(pos, "alias without a name")
            node, end = self.new("alias", pos, m.end(), value=m.group()), m.end()
        else:
            node, end = self.parse_plain(pos, parent_indent)
        if props:
            node.props = True
        return node, end

    def parse_value(self, colon, col, depth):
        """The value after the colon at offset `colon` of a block mapping entry at `col`."""
        q = self.skip_inline(colon + 1)
        if self.is_blank_or_comment_at(q):
            nxt = self.skip_to_content(q)
            if nxt < self.n and not self.at_docmarker(nxt):
                c2 = self.col_of(nxt)
                if c2 > col:
                    return self.parse_node(nxt, col, depth + 1, True)
                if c2 == col and self.is_seq_start(nxt):    # `key:` then `- x` at the same indent
                    return self.parse_seq(nxt, col, depth + 1)
            return self.new("null", colon, colon), colon + 1
        return self.parse_node(q, col, depth + 1, False)

    def parse_map(self, pos, col, depth, first):
        if depth > MAX_DEPTH:
            self.err(pos, "nesting too deep")
        s = self.s
        node = self.new("map", pos, pos + 1)
        last_end = pos
        while True:
            if first is not None:
                knode, colon = first
                first = None
            elif s[pos] == "?" and (pos + 1 >= self.n or s[pos + 1] in " \t\n"):
                # explicit key: `? key` then optionally `: value` at the same indent
                q = self.skip_inline(pos + 1)
                if self.is_blank_or_comment_at(q):
                    nxt = self.skip_to_content(q)
                    if nxt >= self.n or self.col_of(nxt) <= col:
                        self.err(pos, "empty explicit key")
                    q = nxt
                knode, end = self.parse_node(q, col, depth + 1, True)
                nxt = self.skip_to_content(end)
                if nxt < self.n and self.col_of(nxt) == col and s[nxt] == ":" \
                        and (nxt + 1 >= self.n or s[nxt + 1] in " \t\n"):
                    colon = nxt
                else:
                    node.pairs.append((knode, self.new("null", end, end), knode.line, knode.end_col))
                    node.end_line, node.end_col = knode.end_line, knode.end_col
                    last_end = end
                    pos = self.next_entry(nxt, col)
                    if pos is None:
                        return node, last_end
                    continue
            else:
                kp = self.read_key(pos, depth)
                if kp is None:
                    self.err(pos, "expected 'key: value'")
                knode, colon = kp
            vnode, end = self.parse_value(colon, col, depth)
            node.pairs.append((knode, vnode, self.line_of(colon), self.col_of(colon)))
            node.end_line, node.end_col = max((vnode.end_line, vnode.end_col),
                                              (self.line_of(colon), self.col_of(colon) + 1))
            last_end = end
            nxt = self.skip_to_content(end)
            pos = self.next_entry(nxt, col)
            if pos is None:
                return node, last_end

    def next_entry(self, nxt, col):
        """Offset of the next entry of the block mapping at `col`, or None when it ends."""
        if nxt >= self.n or self.at_docmarker(nxt):
            return None
        c2 = self.col_of(nxt)
        if c2 < col:
            return None
        if c2 > col:
            self.err(nxt, "unexpected indentation")
        if self.is_seq_start(nxt):
            self.err(nxt, "a block sequence entry where a mapping key was expected")
        return nxt

    def parse_seq(self, pos, col, depth):
        if depth > MAX_DEPTH:
            self.err(pos, "nesting too deep")
        node = self.new("seq", pos, pos + 1)
        while True:
            q = self.skip_inline(pos + 1)
            if self.is_blank_or_comment_at(q):
                nxt = self.skip_to_content(q)
                if nxt < self.n and not self.at_docmarker(nxt) and self.col_of(nxt) > col:
                    item, end = self.parse_node(nxt, col, depth + 1, True)
                else:
                    item, end = self.new("null", pos, pos + 1), pos + 1
            else:
                item, end = self.parse_node(q, col, depth + 1, True)
            node.items.append(item)
            node.end_line, node.end_col = item.end_line, item.end_col
            nxt = self.skip_to_content(end)
            if nxt >= self.n or self.at_docmarker(nxt):
                return node, end
            c2 = self.col_of(nxt)
            if c2 < col:
                return node, end
            if c2 > col:
                self.err(nxt, "unexpected indentation")
            if not self.is_seq_start(nxt):
                return node, end                        # a sibling key of the enclosing mapping
            pos = nxt

    def parse_document(self):
        pos = self.skip_to_content(0)
        if pos >= self.n:
            return None
        if self.at_docmarker(pos):
            self.err(pos, "document marker inside the frontmatter")
        node, end = self.parse_node(pos, -1, 0, True)
        nxt = self.skip_to_content(end)
        if nxt < self.n:
            if self.at_docmarker(nxt) and self.s[nxt] == "." and self.skip_to_content(nxt + 3) >= self.n:
                return node
            self.err(nxt, "unexpected content after the document")
        return node


def _find_hooks(node, out, depth=0):
    """Outermost `hooks` keys anywhere under `node` (block or flow, any parent)."""
    if node is None or depth > 2 * MAX_DEPTH + 16:
        return
    if node.kind == "map":
        for knode, vnode, cl, cc in node.pairs:
            if knode.kind == "scalar" and knode.value == "hooks":
                out.append((knode, vnode, cl, cc))
                continue                                # its subtree is judged as a whole
            _find_hooks(knode, out, depth + 1)
            _find_hooks(vnode, out, depth + 1)
    elif node.kind == "seq":
        for item in node.items:
            _find_hooks(item, out, depth + 1)


def analyse(lines):
    """Read the frontmatter of a file given as a list of LF-split lines (CR already
    normalised by the caller). None when the first line is not a `---` fence."""
    if not lines or lines[0].lstrip("﻿").strip() != "---":
        return None
    fm = Frontmatter()
    close = None
    for i in range(1, len(lines)):
        t = lines[i].rstrip("\r")
        # Claude's own extraction: a `---` at column 0, blanks allowed after it. An indented
        # `---` or any `...` is content (it can sit inside a block scalar).
        if t.startswith("---") and t[3:].strip(" \t") == "":
            close = i
            break
    fm.end = close
    body = lines[1:close] if close is not None else lines[1:]
    text = "\n".join(b.rstrip("\r") for b in body) + "\n"
    # Backstop (independent of the parse): every line that spells `hooks` + colon.
    base_nl = [0]
    for b in body:
        base_nl.append(base_nl[-1] + len(b.rstrip("\r")) + 1)
    seen = set()
    for m in _HOOKS_TOKEN.finditer(text):
        li = bisect.bisect_right(base_nl, m.start()) - 1
        if li not in seen and len(seen) < 64:
            seen.add(li)
            fm.token_lines.append(li + 1)
    if close is None:
        fm.error = (len(lines) - 1, "frontmatter has no closing --- fence")
    if len(text) > MAX_BYTES:
        fm.error = (1, "frontmatter larger than %d bytes is not parsed" % MAX_BYTES)
        return fm
    parser = _Parser(text)
    try:
        fm.root = parser.parse_document()
    except FMError as exc:
        fm.error = (exc.line + 1, exc.msg)
    except RecursionError:
        fm.error = (1, "nesting too deep")
    if fm.root is not None:
        _find_hooks(fm.root, fm.hooks)
    return fm
