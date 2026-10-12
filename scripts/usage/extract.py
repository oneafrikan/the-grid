#!/usr/bin/env python3
"""Usage extractor: scan every available harness adapter and merge the counts
into <out>/<host>.json (one file per host, written only by that host).

    python3 scripts/usage/extract.py [--out DIR] [--host NAME] [--since-day YYYY-MM-DD]
                                     [--registry MODULE:ATTR]

The extractor knows nothing about transcript formats; adapters (see
adapters/__init__.py) yield normalised events and this script only sums them.

Merge rule (idempotent and retention-safe): every scan is a de-duplicated SUBSET
of history (old transcripts expire, today is half finished), so for each day and
each leaf count the stored value becomes max(old, new). Max never loses data and
never double counts across overlapping weekly scans. It cannot repair an
inflated value, which is why the adapter's de-duplication must be right.

Exit codes: 0 ok (including "no adapters available"), 1 existing host file is
unusable (left untouched), 2 refused (bad host name or --since-day, --out inside
the repo, or --out / the host file is a symlink).
Output holds counts only: no prompt text, paths, project names or ids.

Writes: the document is REBUILT from a whitelist (schema, host, updated,
harnesses.<name>.{days,listing,wired}); anything else in an existing host file
(extra keys, strings, odd names) is dropped with one stderr note, so a tampered or
hand-edited file self-heals instead of being re-published. Adding a new field to the
output therefore needs an edit to `sanitize_old` below. The file is written through a
unique temp file (mkstemp, O_EXCL) and renamed over the target, never through a
fixed name that a planted symlink could redirect.
"""
from __future__ import annotations

import argparse
import datetime
import importlib
import json
import os
import re
import socket
import sys
import tempfile

# Never leave __pycache__ in the checkout (set before the adapters are imported).
sys.dont_write_bytecode = True

SCHEMA = 1
# Below this the transcripts may expire before a missed weekly run catches up.
MIN_RETENTION_DAYS = 45
TOKEN_FIELDS = ("in", "out", "cache_read", "cache_write")

# Shapes a stored name/day may have. Duplicated from adapters/claude_code.py on
# purpose (this script knows nothing about adapters); they are the whitelist applied
# to an EXISTING host file, so keep them in step with the adapter's own filters.
NAME_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9:_.-]{0,63}")
HOOK_NAME_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9:_.|*()-]{0,127}")
DAY_RE = re.compile(r"[0-9]{4}-[0-9]{2}-[0-9]{2}")
DEFAULT_AGENT = "(default)"  # the adapter's name for an Agent call with no subagent_type


def die(code, msg):
    print("usage-extract: " + msg, file=sys.stderr)
    sys.exit(code)


def pick_host(arg):
    """--host, else GRID_HOST, else hostname -s; sanitised; refuse empty/localhost.

    Two machines sharing a name would share one file, which breaks the
    one-writer rule and silently max-merges two hosts together."""
    raw = arg or os.environ.get("GRID_HOST") or socket.gethostname().split(".")[0]
    host = re.sub(r"[^A-Za-z0-9._-]", "_", raw)
    if not host or host.lower() == "localhost":
        die(2, "refusing host name %r (empty or localhost); pass --host or set GRID_HOST" % raw)
    # "." and ".." would escape the host-file namespace; a leading "." makes a file the
    # aggregator skips as hidden, so the data would silently never be read.
    if host.startswith("."):
        die(2, "refusing host name %r (starts with '.'); pass --host or set GRID_HOST" % raw)
    return host


def inside(path, parent):
    """True when path resolves to parent or something below it."""
    path, parent = os.path.realpath(path), os.path.realpath(parent)
    return path == parent or path.startswith(parent + os.sep)


def load_registry(spec):
    """Import MODULE:ATTR (default adapters:REGISTRY) and return the class list.
    --registry exists so tests can substitute a fake adapter."""
    mod_name, _, attr = spec.partition(":")
    # The adapters package sits next to this file.
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    return getattr(importlib.import_module(mod_name), attr)


def merge_max(old, new):
    """Leaf-wise max of two nested dicts of ints (new keys are added)."""
    if isinstance(old, dict) and isinstance(new, dict):
        out = dict(old)
        for k, v in new.items():
            out[k] = merge_max(old[k], v) if k in old else v
        return out
    if (isinstance(old, int) and isinstance(new, int)
            and not isinstance(old, bool) and not isinstance(new, bool)):
        return max(old, new)
    return new


def _is_count(v):
    return isinstance(v, int) and not isinstance(v, bool) and v >= 0


def sanitize_old(old, host, drops):
    """Rebuild an existing host file from the whitelist; `drops` (a one-item list)
    counts every entry left out. Only day keys, non-negative int counts and names
    that pass the filters survive. A valid-looking but inflated count cannot be told
    from a real one (max-merge keeps it); only the shape is enforced here."""
    def counts(m, name_re, extra=()):
        out = {}
        if not isinstance(m, dict):
            drops[0] += 1
            return out
        for k, v in m.items():
            if isinstance(k, str) and (name_re.fullmatch(k) or k in extra) and _is_count(v):
                out[k] = v
            else:
                drops[0] += 1
        return out

    def day_bucket(b):
        out = {}
        if not isinstance(b, dict):
            drops[0] += 1
            return out
        for key, val in b.items():
            if key in ("skills", "slash"):
                c = counts(val, NAME_RE)
            elif key == "agents":
                c = counts(val, NAME_RE, (DEFAULT_AGENT,))
            elif key == "hooks":
                c = counts(val, HOOK_NAME_RE)
            elif key == "tokens":
                c = {}
                for model, tok in (val.items() if isinstance(val, dict) else ()):
                    if isinstance(model, str) and NAME_RE.fullmatch(model) and isinstance(tok, dict):
                        t = {f: v for f, v in tok.items() if f in TOKEN_FIELDS + ("msgs",) and _is_count(v)}
                        drops[0] += len(tok) - len(t)
                        c[model] = t
                    else:
                        drops[0] += 1
            else:
                drops[0] += 1
                continue
            if c:
                out[key] = c
        return out

    updated = old.get("updated")
    clean = {"schema": SCHEMA, "host": host,
             "updated": updated if isinstance(updated, str) and DAY_RE.fullmatch(updated) else None,
             "harnesses": {}}
    drops[0] += len(set(old) - set(clean))
    harnesses = old.get("harnesses")
    for name, blk in (harnesses.items() if isinstance(harnesses, dict) else ()):
        if not (isinstance(name, str) and NAME_RE.fullmatch(name) and isinstance(blk, dict)):
            drops[0] += 1
            continue
        h = {"days": {}, "listing": {}}
        drops[0] += len(set(blk) - {"days", "listing", "wired"})
        days = blk.get("days")
        for day, b in (days.items() if isinstance(days, dict) else ()):
            if isinstance(day, str) and DAY_RE.fullmatch(day):
                cb = day_bucket(b)
                if cb:
                    h["days"][day] = cb
            else:
                drops[0] += 1
        listing = blk.get("listing")
        for day, ls in (listing.items() if isinstance(listing, dict) else ()):
            if (isinstance(day, str) and DAY_RE.fullmatch(day) and isinstance(ls, dict)
                    and set(ls) <= {"skills", "chars"} and all(_is_count(v) for v in ls.values())):
                h["listing"][day] = dict(ls)
            else:
                drops[0] += 1
        wired = blk.get("wired")
        if isinstance(wired, dict):
            w = {}
            for kind, names in wired.items():
                if kind in ("skills", "agents") and isinstance(names, list):
                    w[kind] = [n for n in names if isinstance(n, str) and NAME_RE.fullmatch(n)]
                    drops[0] += len(names) - len(w[kind])
                else:
                    drops[0] += 1
            if w:
                h["wired"] = w
        clean["harnesses"][name] = h
    return clean


def sum_events(events):
    """Fold events into {"days": {...}, "listing": {...}} (the adapter already
    de-duplicated, so every event is one occurrence)."""
    days, listing = {}, {}
    count = 0
    for ev in events:
        count += 1
        day, kind = ev["day"], ev["kind"]
        # A listing alone does not create a "days" entry (it has its own map).
        d = days.setdefault(day, {}) if kind != "listing" else None
        if kind in ("skill", "agent", "hook", "slash"):
            bucket = {"skill": "skills", "agent": "agents", "hook": "hooks", "slash": "slash"}[kind]
            counts = d.setdefault(bucket, {})
            counts[ev["name"]] = counts.get(ev["name"], 0) + 1
        elif kind == "tokens":
            tok = d.setdefault("tokens", {}).setdefault(
                ev["model"], {"msgs": 0, "in": 0, "out": 0, "cache_read": 0, "cache_write": 0})
            tok["msgs"] += 1  # one event per unique message
            for f in TOKEN_FIELDS:
                tok[f] += ev.get(f, 0)
        elif kind == "listing":
            # A day can see several session starts; keep the largest.
            cur = listing.get(day, {"skills": 0, "chars": 0})
            listing[day] = {"skills": max(cur["skills"], ev["skills"]),
                            "chars": max(cur["chars"], ev["chars"])}
    return {"days": days, "listing": listing}, count


def retention_warning():
    """Return a warning string when cleanupPeriodDays is unset or too low."""
    path = os.environ.get("CLAUDE_SETTINGS") or os.path.expanduser("~/.claude/settings.json")
    value = None
    try:
        with open(path, encoding="utf-8") as fh:
            value = json.load(fh).get("cleanupPeriodDays")
    except (OSError, ValueError, AttributeError):
        pass
    if isinstance(value, bool) or not isinstance(value, int) or value < MIN_RETENTION_DAYS:
        return ('WARNING: cleanupPeriodDays is %s in the Claude Code settings; transcripts expire '
                'before a missed weekly run catches up. Recommended: "cleanupPeriodDays": 60'
                % ("unset" if value is None else value))
    return None


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    default_out = os.path.join(os.environ.get("GRID_PRIVATE_DIR") or os.path.expanduser("~/.the-grid-private"), "usage")
    ap.add_argument("--out", default=default_out)
    ap.add_argument("--host")
    ap.add_argument("--since-day")
    ap.add_argument("--registry", default="adapters:REGISTRY")
    args = ap.parse_args()

    host = pick_host(args.host)
    if args.since_day is not None and not DAY_RE.fullmatch(args.since_day):
        die(2, "--since-day %r is not a YYYY-MM-DD date" % args.since_day)
    # Personal data never lands in the public repo. Check against BOTH this script's own
    # repo root and $GRID_DIR: a stale or wrong $GRID_DIR must not disarm the guard.
    own_root = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    for root in sorted({own_root, os.environ.get("GRID_DIR") or own_root}):
        if inside(args.out, root):
            die(2, "refusing --out %s: it is inside the repo (%s)" % (args.out, root))
    # A symlinked --out or host file would redirect the write somewhere else.
    if os.path.islink(args.out):
        die(2, "refusing --out %s: it is a symlink" % args.out)

    target = os.path.join(args.out, host + ".json")
    if os.path.islink(target):
        die(2, "refusing %s: the host file is a symlink" % target)
    old = None
    if os.path.exists(target):
        # Never overwrite a file we cannot read: the previous good copy is in git.
        try:
            with open(target, encoding="utf-8") as fh:
                old = json.load(fh)
        except (OSError, ValueError):
            old = None
        if not isinstance(old, dict) or old.get("schema") != SCHEMA:
            die(1, "existing %s is unparseable or has an unknown schema; left untouched" % target)

    adapters = [cls() for cls in load_registry(args.registry)]
    adapters = [a for a in adapters if a.available()]
    if not adapters:
        print("usage-extract: no adapters available; nothing to do")
        return 0

    if old:
        drops = [0]
        doc = sanitize_old(old, host, drops)
        if drops[0]:
            print("usage-extract: dropped %d unexpected entries from the existing %s" % (drops[0], target),
                  file=sys.stderr)
    else:
        doc = {"schema": SCHEMA, "host": host, "updated": None, "harnesses": {}}
    harnesses = doc.setdefault("harnesses", {})
    total, notes, warnings = 0, [], []
    for a in adapters:
        scan, n = sum_events(a.events(args.since_day))
        total += n
        h = harnesses.setdefault(a.name, {})
        h["days"] = merge_max(h.get("days", {}), scan["days"])
        h["listing"] = merge_max(h.get("listing", {}), scan["listing"])
        # wired: replace only the lists this scan produced (a missing dir keeps the old one).
        wired = a.wired() or {}
        if wired:
            h.setdefault("wired", {}).update(wired)
        st = getattr(a, "stats", None)
        if st:
            notes.append("%s %s" % (a.name, " ".join("%s=%s" % kv for kv in st.items())))
            # Drift canary: a parser that recognises nothing looks like "nothing was used".
            if (st.get("lines", 0) > 0 and st.get("assistant", 0) == 0) or st.get("bad_lines", 0) * 20 > st.get("lines", 0):
                warnings.append("WARNING: transcript format may have changed (%s); counts may be too low" % notes[-1])

    if doc == old:
        status = "unchanged"
    else:
        doc["updated"] = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d")
        os.makedirs(args.out, exist_ok=True)
        # Unique hidden temp name in the same directory (mkstemp opens it O_EXCL, so a
        # planted file or symlink is never opened and two runs never share one): atomic
        # rename, and a leftover can never be mistaken for a host file.
        fd, tmp = tempfile.mkstemp(dir=args.out, prefix="." + host + ".json.")
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as fh:
                fh.write(json.dumps(doc, sort_keys=True, indent=2) + "\n")
            os.replace(tmp, target)
        finally:
            try:
                os.unlink(tmp)   # still there only when the write or the rename failed
            except FileNotFoundError:
                pass
        status = "written"

    print("usage-extract: host=%s adapters=%s events=%d %s %s%s"
          % (host, ",".join(a.name for a in adapters), total, status, target,
             " [" + "; ".join(notes) + "]" if notes else ""))
    for w in warnings:
        print(w, file=sys.stderr)
    w = retention_warning()
    if w:
        print(w, file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
