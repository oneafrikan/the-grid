#!/usr/bin/env python3
"""skill_frontmatter.py - read a SKILL.md's `name` and `description` (stdlib only).

Usage (run isolated, so a stray module in the cwd can never be imported):
    python3 -I scripts/lib/skill_frontmatter.py PATH/TO/SKILL.md          -> name<TAB>description
    python3 -I scripts/lib/skill_frontmatter.py --len PATH/TO/SKILL.md    -> name<TAB>len(description)
    python3 -I scripts/lib/skill_frontmatter.py --claude-only PATH/TO/SKILL.md
        -> the top-level frontmatter keys that only Claude Code honours (see CLAUDE_ONLY_KEYS),
           one per line; empty output = none. Exit 1 without a frontmatter block.
    python3 -I scripts/lib/skill_frontmatter.py --escaping-links DIR
        -> exit 1 (naming the first link) when a symlink under DIR resolves outside DIR, else 0.

The description is printed with every newline folded to a single space, so the
output is always one line. Plain, single/double-quoted and `>` / `|` block scalars
(with optional chomping/indent indicators) are handled; that is all a SKILL.md
frontmatter uses for these two keys. Exit 1 when there is no leading `---` block
(missing file, no opening fence, or no closing fence).

Why not PyYAML: wire.sh must run on a bare machine with only python3. `--len`
exists so the caller gets a character count (not a locale-dependent byte count)
without a second interpreter start-up per skill.
"""
import os
import re
import sys

# Frontmatter keys that guard or scope a skill in Claude Code. A harness that does not know
# them would drop the guard, so a skill carrying one is not shared with other harnesses.
CLAUDE_ONLY_KEYS = ("disable-model-invocation", "allowed-tools", "hooks", "context")


def frontmatter_lines(path):
    """Return the lines between the opening and closing `---`, or None."""
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            text = fh.read()
    except OSError:
        return None
    lines = text.lstrip("﻿").splitlines()
    if not lines or lines[0].strip() != "---":
        return None
    for i in range(1, len(lines)):
        if lines[i].strip() == "---":
            return lines[1:i]
    return None


def scalar(lines, key):
    """Value of top-level `key:` with continuation lines folded to spaces."""
    for i, line in enumerate(lines):
        m = re.match(r"^" + re.escape(key) + r"\s*:(.*)$", line)
        if not m:
            continue
        parts = [m.group(1).strip()]
        # Continuation = the indented (or blank) lines that follow. A block scalar
        # indicator (>, |, optionally with +/- and an indent digit) carries no text
        # of its own: everything comes from the continuation lines.
        for nxt in lines[i + 1:]:
            if nxt.strip() and nxt[0] not in " \t":
                break
            parts.append(nxt.strip())
        if re.match(r"^[>|][+\-0-9]*$", parts[0]):
            parts = parts[1:]
        value = " ".join(p for p in parts if p)
        # An unquoted plain scalar ends at " #": `name: foo # comment` is the name foo. Quoted
        # scalars and block scalars (where # is literal text) are left alone.
        if value and value[0] not in "'\"" and not re.match(r"^[>|][+\-0-9]*$", m.group(1).strip()):
            value = re.sub(r"\s+#.*$", "", value)
        return unquote(value)
    return ""


def claude_only_keys(lines):
    """The CLAUDE_ONLY_KEYS present as TOP-LEVEL keys (column 0) of the frontmatter."""
    # A YAML key may be quoted ("hooks": x, 'allowed-tools': Bash); the quote must be the same
    # on both sides, so "hooks' is not a guard key. Unquoted is the common case.
    return [k for k in CLAUDE_ONLY_KEYS
            if any(re.match(r"^(?:" + re.escape(k) + r"|\"" + re.escape(k) + r"\"|'" + re.escape(k) + r"')\s*:", line)
                   for line in lines)]


def escaping_link(root):
    """Path of the first symlink under root whose target resolves outside root, or None."""
    real_root = os.path.realpath(root)
    for dirpath, dirnames, filenames in os.walk(root, followlinks=False):
        for name in dirnames + filenames:
            path = os.path.join(dirpath, name)
            if not os.path.islink(path):
                continue
            target = os.path.realpath(path)
            if target != real_root and not target.startswith(real_root + os.sep):
                return path
    return None


def unquote(value):
    """Strip one level of YAML quoting from an already-folded scalar."""
    if len(value) >= 2 and value[0] == value[-1] == "'":
        return value[1:-1].replace("''", "'")
    if len(value) >= 2 and value[0] == value[-1] == '"':
        inner = value[1:-1]
        # The few escapes that occur in prose; anything else is kept as written.
        return re.sub(r'\\(["\\/])', r"\1", inner).replace("\\n", " ").replace("\\t", " ")
    return value


def main(argv):
    show_len = False
    args = argv[1:]
    if args and args[0] == "--len":
        show_len, args = True, args[1:]
    if len(args) == 2 and args[0] == "--claude-only":
        fm = frontmatter_lines(args[1])
        if fm is None:
            return 1
        for key in claude_only_keys(fm):
            print(key)
        return 0
    if len(args) == 2 and args[0] == "--escaping-links":
        bad = escaping_link(args[1])
        if bad is not None:
            print(bad)
            return 1
        return 0
    if len(args) != 1:
        print("usage: skill_frontmatter.py [--len|--claude-only|--escaping-links] PATH", file=sys.stderr)
        return 2
    fm = frontmatter_lines(args[0])
    if fm is None:
        return 1
    name = scalar(fm, "name")
    # A TAB inside the description would break the two-column output.
    desc = scalar(fm, "description").replace("\t", " ")
    print("%s\t%s" % (name, len(desc) if show_len else desc))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
