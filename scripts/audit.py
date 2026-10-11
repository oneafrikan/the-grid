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
restricted-YAML reader, which lives next to this file's lib/ directory) so the
scanner runs on a bare machine before any virtualenv exists.

Do NOT run this under `python3 -I`: isolated mode drops the script directory
and the sys.path insert below would not be enough for `import audit` in tests.
"""
import argparse
import hashlib
import json
import os
import re
import sys

# Make scripts/lib importable no matter where we are called from.
_HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(_HERE, "lib"))
import miniyaml  # noqa: E402  (needs the sys.path insert above)

# --------------------------------------------------------------------------
# Constants
# --------------------------------------------------------------------------

# Severity of each built-in check when the policy's `builtin:` map omits it.
DEFAULT_BUILTIN = {
    "hidden-unicode": "high",
    "symlink-escape": "high",
    "binary-exec": "low",
    "oversize-file": "low",
    "vendored-deps": "high",
    "source-not-allowed": "low",
    "source-uncurated": "low",
    "allow-unused": "low",
    "allow-stale": "low",
}

# Rules whose LOW findings `--quiet` still prints (the wire-time warning for a
# repo that only a machine overlay wires). Emitted by the source checks.
ALWAYS_PRINT_LOW = {"source-not-allowed", "source-uncurated"}

# Findings that describe a whole file/symlink/directory (no line number) and
# therefore carry a `sha256` that an allowlist entry can pin.
FILE_LEVEL_BUILTINS = {"hidden-unicode", "symlink-escape", "binary-exec",
                       "oversize-file", "vendored-deps"}

BUILTIN_MESSAGES = {
    "hidden-unicode": "invisible or bidirectional-control Unicode character",
    "symlink-escape": "symlink resolves outside the scanned tree (not followed)",
    "binary-exec": "executable binary (ELF/Mach-O/PE); not scanned",
    "oversize-file": "file larger than limits.max_file_bytes; not scanned",
    "vendored-deps": "vendored node_modules directory; not scanned",
    "allow-unused": "allowlist entry matched nothing in this run",
    "allow-stale": "hash-pinned allowlist entry no longer matches the file; entry inactive",
}

DOWNGRADE_CONTEXTS = ("test", "negation", "comment")
SHELL_FENCE_WORDS = {"bash", "sh", "zsh", "shell", "console"}
COMMENT_PREFIXES = ("#", "//", "*", "/*", "<!--")
EXCERPT_MAX = 120
BINARY_SNIFF = 8192

# Executable magic numbers (see _is_exec_binary). Fat Mach-O (0xCAFEBABE) is left
# out on purpose: it collides with Java class files.
_MACHO_MAGICS = (b"\xfe\xed\xfa\xce", b"\xfe\xed\xfa\xcf",
                 b"\xce\xfa\xed\xfe", b"\xcf\xfa\xed\xfe")


class UsageError(Exception):
    """Anything that must end the run with exit code 2."""


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
            or o == 0x180E)                                      # Mongolian vowel sep.


def _exempt(c, prev, at_file_start):
    """Legitimate uses of otherwise-flagged characters (see design rule 7)."""
    o = ord(c)
    if o == 0xFEFF and at_file_start:
        return True                      # a byte-order mark as the very first char
    if o in (0x200C, 0x200D) and prev is not None:
        p = ord(prev)
        # Joiners after Arabic/Indic/emoji-range characters, but not after
        # general punctuation/format characters (U+2000-U+206F).
        return p >= 0x0600 and not (0x2000 <= p <= 0x206F)
    if o == 0xFE0F and prev is not None:
        return ord(prev) >= 0x2190       # emoji presentation selector after a symbol
    return False


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
        ids = [r.id for r in self.rules]
        if len(ids) != len(set(ids)):
            raise UsageError("policy: duplicate rule id")
        # Every id an allowlist entry may name.
        self.known_ids = set(ids) | set(self.builtin)

    def file_class(self, rel_target, rel_root):
        """First class (policy order) with a glob matching either path; else 'other'."""
        for name, globs in self.classes:
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
            return (self.contains in f["_line"]
                    or self.contains in f["_line_escaped"])
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
        if os.path.isdir(real):
            self._walk(real, real, tier)
        else:
            self._scan_file(real, os.path.basename(real), tier)

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
                if e.name in self.policy.skip_dirs:
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

    def _scan_file(self, full, rel_target, tier):
        pol = self.policy
        self.files += 1
        rel_root = self._rel_root(full)
        display = self._display(full)
        name = os.path.basename(full)
        fclass = pol.file_class(rel_target, rel_root)

        size = os.lstat(full).st_size
        if size > pol.max_file_bytes:
            # An unscannable file that gets executed or loaded as an agent must
            # not pass silently, so those classes are high; prose stays low.
            sev = pol.builtin["oversize-file"]
            if (fclass in ("script", "hook", "config") or name == "SKILL.md"
                    or _is_agent_md(rel_target, rel_root, name)):
                sev = "high"
            self._add("oversize-file", sev, display, 0, fclass, tier,
                      BUILTIN_MESSAGES["oversize-file"], sha256=sha256_file(full))
            return

        with open(full, "rb") as fh:
            data = fh.read()
        head = data[:BINARY_SNIFF]
        if _is_exec_binary(head):
            self._add("binary-exec", pol.builtin["binary-exec"], display, 0, fclass, tier,
                      BUILTIN_MESSAGES["binary-exec"], sha256=sha256_bytes(data))
            return
        if b"\x00" in head:
            return                            # other binary content: skipped silently

        file_sha = sha256_bytes(data)
        # Lines split on \n ONLY, so U+2028/U+2029 never end a line.
        lines = data.decode("utf-8", errors="replace").split("\n")
        classes = self._line_classes(lines, fclass, name, rel_target, rel_root)
        for idx, raw in enumerate(lines):
            line = raw.rstrip("\r")
            if line == "":
                continue
            self._scan_line(line, idx + 1, classes[idx], display, tier, file_sha)

    def _line_classes(self, lines, fclass, name, rel_target, rel_root):
        """Class of each line: the file's class, except (1) frontmatter `hooks:`
        blocks of SKILL.md/agent .md are `hook`, and (2) lines inside untagged
        or shell-tagged fenced blocks of .md/.mdx doc files are `script`
        (design rule 1: prose negation must not excuse a copy-paste command)."""
        classes = [fclass] * len(lines)
        ext = os.path.splitext(name)[1].lower()

        # (1) frontmatter hooks
        if name == "SKILL.md" or _is_agent_md(rel_target, rel_root, name):
            first = lines[0].lstrip("﻿").rstrip("\r") if lines else ""
            if first == "---":
                in_hooks = False
                for i in range(1, len(lines)):
                    text = lines[i].rstrip("\r")
                    if text in ("---", "..."):
                        break                 # end of frontmatter
                    if re.match(r"hooks\s*:", text):
                        in_hooks = True
                        classes[i] = "hook"
                    elif in_hooks and (text == "" or text[0] in " \t-"):
                        classes[i] = "hook"
                    else:
                        in_hooks = False

        # (2) fenced code blocks in markdown docs
        if fclass == "doc" and ext in (".md", ".mdx"):
            fence = None                      # (char, length, is_shell) while inside one
            for i, raw in enumerate(lines):
                text = raw.rstrip("\r")
                m = re.match(r"^\s*(`{3,}|~{3,})(.*)$", text)
                if fence is None:
                    if not m:
                        continue
                    marker, info = m.group(1), m.group(2).strip()
                    if marker[0] == "`" and "`" in info:
                        continue              # inline code like ```x```, not a fence
                    words = info.split()
                    first_word = words[0].lower() if words else ""
                    fence = (marker[0], len(marker),
                             first_word == "" or first_word in SHELL_FENCE_WORDS)
                else:
                    char, length, shell = fence
                    # Closes at a line holding only the same fence char, at least as long.
                    if m and m.group(1)[0] == char and len(m.group(1)) >= length \
                            and m.group(2).strip() == "":
                        fence = None
                    elif shell:
                        classes[i] = "script"
        return classes

    def _scan_line(self, line, lineno, cls, display, tier, file_sha):
        pol = self.policy

        # Built-in: hidden Unicode. One finding per line however many characters.
        for pos, ch in enumerate(line):
            if not is_hidden_char(ch):
                continue
            prev = line[pos - 1] if pos > 0 else None
            if _exempt(ch, prev, at_file_start=(lineno == 1 and pos == 0)):
                continue
            sev, down = pol.builtin["hidden-unicode"], None
            if cls == "test" and sev == "high":
                sev, down = "low", "test"
            self._add("hidden-unicode", sev, display, lineno, cls, tier,
                      BUILTIN_MESSAGES["hidden-unicode"], excerpt=line,
                      downgraded=down, sha256=file_sha, raw_line=line)
            break

        # Policy rules.
        for rule in pol.rules:
            if rule.applies is not None and cls not in rule.applies:
                continue
            if not rule.regex.search(line):
                continue
            if rule.ignore is not None and rule.ignore.search(line):
                continue
            sev = rule.severity_by_class.get(cls, rule.severity)
            if tier == "owned" and rule.owned_severity:
                sev = rule.owned_severity
            down = None
            if sev == "high":
                down = self._downgrade_context(rule, line, cls)
                if down:
                    sev = "low"
            self._add(rule.id, sev, display, lineno, cls, tier, rule.message,
                      excerpt=line, downgraded=down, raw_line=line)

    def _downgrade_context(self, rule, line, cls):
        """Name of the first listed context that excuses a high finding, else None."""
        for ctx in rule.downgrade:
            if ctx == "test" and cls == "test":
                return ctx
            if (ctx == "negation" and self.policy.negation is not None
                    and cls in ("doc", "other") and self.policy.negation.search(line)):
                return ctx                    # prose only: a script cannot "warn" its way out
            if (ctx == "comment" and cls in ("script", "hook", "config")
                    and line.lstrip().startswith(COMMENT_PREFIXES)):
                return ctx
        return None


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
    p.add_argument("targets", metavar="TARGET", nargs="+",
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
    return p


def run(args):
    grid_dir = args.grid_dir or default_grid_dir()
    root = args.root or default_grid_dir()
    if not os.path.isdir(root):
        raise UsageError("--root %s is not a directory" % root)
    policy = Policy(args.policy or os.path.join(grid_dir, "policy.yaml"))
    allow_path = args.allow or os.path.join(grid_dir, "CURATION.md")
    entries = load_allowlist(allow_path, policy)

    for t in args.targets:                     # a missing target is an error, not a skip
        if not os.path.exists(t):
            raise UsageError("target does not exist: %s" % t)

    scan = Scan(policy, root)
    for t in args.targets:
        scan.scan_target(t)

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
    except UsageError as exc:
        sys.stderr.write("audit: error: %s\n" % exc)
        return 2


if __name__ == "__main__":
    sys.exit(main())
