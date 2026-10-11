#!/usr/bin/env python3
"""skill_frontmatter.py - read a SKILL.md's `name` and `description` (stdlib only).

Usage (run isolated, so a stray module in the cwd can never be imported):
    python3 -I scripts/lib/skill_frontmatter.py PATH/TO/SKILL.md          -> name<TAB>description
    python3 -I scripts/lib/skill_frontmatter.py --len PATH/TO/SKILL.md    -> name<TAB>len(description)

The description is printed with every newline folded to a single space, so the
output is always one line. Plain, single/double-quoted and `>` / `|` block scalars
(with optional chomping/indent indicators) are handled; that is all a SKILL.md
frontmatter uses for these two keys. Exit 1 when there is no leading `---` block
(missing file, no opening fence, or no closing fence).

Why not PyYAML: wire.sh must run on a bare machine with only python3. `--len`
exists so the caller gets a character count (not a locale-dependent byte count)
without a second interpreter start-up per skill.
"""
import re
import sys


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
        return unquote(value)
    return ""


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
    if len(args) != 1:
        print("usage: skill_frontmatter.py [--len] SKILL.md", file=sys.stderr)
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
