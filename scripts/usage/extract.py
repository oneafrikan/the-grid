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
unusable (left untouched), 2 refused (bad host name, or --out inside the repo).
Output holds counts only: no prompt text, paths, project names or ids.
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

SCHEMA = 1
# Below this the transcripts may expire before a missed weekly run catches up.
MIN_RETENTION_DAYS = 45
TOKEN_FIELDS = ("in", "out", "cache_read", "cache_write")


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
    # Personal data never lands in the public repo.
    grid_dir = os.environ.get("GRID_DIR") or os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    if inside(args.out, grid_dir):
        die(2, "refusing --out %s: it is inside the repo (%s)" % (args.out, grid_dir))

    target = os.path.join(args.out, host + ".json")
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

    doc = json.loads(json.dumps(old)) if old else {"schema": SCHEMA, "host": host, "updated": None, "harnesses": {}}
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
        # Hidden temp name in the same directory: atomic rename, and a leftover
        # can never be mistaken for a host file.
        tmp = os.path.join(args.out, "." + host + ".json.tmp")
        with open(tmp, "w", encoding="utf-8") as fh:
            fh.write(json.dumps(doc, sort_keys=True, indent=2) + "\n")
        os.replace(tmp, target)
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
