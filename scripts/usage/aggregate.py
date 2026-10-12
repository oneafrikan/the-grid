#!/usr/bin/env python3
"""aggregate.py - sum the per-host usage files into one picture (importable, no CLI).

    aggregate(dir, window_days) -> dict

`dir` holds one `<host>.json` per machine, written by scripts/usage/extract.py
(schema 1, see design.md section 3). The result is keyed by HARNESS name
(e.g. "claude-code"); each value holds

    skills / agents / slash / hooks   {name: count} summed over all hosts, over
                                      the WINDOW only (the last `window_days`
                                      days, ending at the latest valid day stored
                                      or today (UTC), whichever is earlier)
    tokens                            {"YYYY-MM": {model: {msgs, in, out,
                                      cache_read, cache_write}}} summed over all
                                      hosts and ALL stored days (months are the
                                      unit, so the window does not cut them)
    hosts                             number of host files that reported it
    first_day / last_day              earliest / latest day key across hosts
    coverage_days                     inclusive span first_day..last_day
    rejected_days                     stored day keys ignored (not a date, before
                                      2024-01-01 or after today + 1 day, UTC)
    active_days                       number of distinct valid day keys across hosts
                                      (a day exists only when something was recorded
                                      on it; the prune report's "enough history"
                                      measure; bucket contents are not read)
    window_start                      first day of the window ("" with no data)
    wired_first_seen                  {"skills": {name: day}, "agents": {...}}: the
                                      earliest day any host saw the name wired
    wired                             {"skills": [...], "agents": [...]} union of
                                      every host's latest wired snapshot

plus one extra top-level key, "ignored": the sorted file names of `*.json` files
that were skipped (do not parse, not a JSON object, unknown schema).

The prune report (prune_report.py) must NOT read `tokens` or `hooks`: they exist
for cost analysis only (recipe in docs/usage.md). Stdlib only.
"""
from __future__ import annotations

import datetime
import json
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from usage_schema import SCHEMA  # noqa: E402   the only schema this reader understands (one constant)
# Local copies of the adapter's filters (WP-059 consolidates the constants). ASCII-only
# and \Z-anchored: `$` matches before a trailing newline and `\d` matches other scripts' digits.
NAME_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9:_.-]{0,63}\Z", re.ASCII)
DAY_SHAPE = re.compile(r"[0-9]{4}-[0-9]{2}-[0-9]{2}\Z", re.ASCII)
MIN_DAY = datetime.date(2024, 1, 1)   # earlier days are bogus (same bound as the extractor)
MAX_WIRED_NAMES = 500                 # per list, per host file
TOKEN_FIELDS = ("msgs", "in", "out", "cache_read", "cache_write")
COUNT_KINDS = ("skills", "agents", "slash", "hooks")


def _int(value) -> int:
    """A count from a host file: anything but a non-negative int (and bool is not
    one) counts as 0, so a hand-edited file cannot poison the sums."""
    if isinstance(value, int) and not isinstance(value, bool) and value >= 0:
        return value
    return 0


def _load(path: str):
    """The parsed host file, or None when it must be ignored."""
    try:
        with open(path, encoding="utf-8") as fh:
            doc = json.load(fh)
    except (OSError, ValueError, RecursionError):   # unreadable, truncated, conflict markers, nested bomb
        return None
    if not isinstance(doc, dict) or doc.get("schema") != SCHEMA:
        return None
    if not isinstance(doc.get("harnesses"), dict):
        return None
    # Shape of the next two levels: a hand-edited or hostile file with a list where an
    # object belongs would crash the readers, so it is ignored (and listed) instead.
    for data in doc["harnesses"].values():
        if not isinstance(data, dict):
            return None
        if data.get("days") is not None and not isinstance(data["days"], dict):
            return None
    return doc


def _is_day(key, today) -> bool:
    """A real calendar day between MIN_DAY and today + 1 (UTC). One forged or
    clock-skewed future day would otherwise move the window end and make every
    skill read "never"."""
    if not isinstance(key, str) or not DAY_SHAPE.match(key):
        return False
    try:
        day = datetime.date.fromisoformat(key)
    except ValueError:
        return False
    return MIN_DAY <= day <= today + datetime.timedelta(days=1)


def aggregate(dir, window_days, today=None):
    if today is None:
        today = datetime.datetime.now(datetime.timezone.utc).date()
    ignored = []
    docs = []                               # (file name, parsed doc), sorted by name
    for fname in sorted(os.listdir(dir)) if os.path.isdir(dir) else []:
        # Only *.json is considered; a leftover `.host.json.tmp` or a README is not
        # a host file and is not worth reporting. Dotfiles are skipped too.
        if not fname.endswith(".json") or fname.startswith("."):
            continue
        doc = _load(os.path.join(dir, fname))
        if doc is None:
            ignored.append(fname)
        else:
            docs.append((fname, doc))

    # Pass 1: per harness, collect every host's data block.
    blocks = {}                             # harness -> [data dict, ...]
    for _, doc in docs:
        for harness, data in doc["harnesses"].items():
            if isinstance(data, dict):
                blocks.setdefault(harness, []).append(data)

    out = {}
    for harness, datas in sorted(blocks.items()):
        # All valid day keys across hosts: they fix first/last/coverage and the window.
        all_days = sorted({d for data in datas
                           for d in (data.get("days") or {}) if _is_day(d, today)})
        rejected = sum(1 for data in datas for d in (data.get("days") or {}) if not _is_day(d, today))
        # "Active" = a valid day key. The extractor creates a day only when it recorded an
        # event on it, so the key itself is the evidence. The bucket's CONTENT is not read:
        # the prune report must not depend on tokens or hooks.
        active = {d for data in datas
                  for d, b in (data.get("days") or {}).items()
                  if _is_day(d, today) and isinstance(b, dict)}
        res = {"skills": {}, "agents": {}, "slash": {}, "hooks": {},
               "tokens": {}, "hosts": len(datas),
               "first_day": None, "last_day": None, "coverage_days": 0,
               "rejected_days": rejected, "active_days": len(active), "window_start": "",
               "wired_first_seen": {"skills": {}, "agents": {}},
               "wired": {"skills": [], "agents": []}}
        if all_days:
            first = datetime.date.fromisoformat(all_days[0])
            last = datetime.date.fromisoformat(all_days[-1])
            res["first_day"], res["last_day"] = all_days[0], all_days[-1]
            res["coverage_days"] = (last - first).days + 1
            # The window ends at the latest valid day stored (so a report on stale data is
            # still self-consistent), but never later than today: a day in the future
            # cannot move it.
            anchor = min(last, today)
            win_start = (anchor - datetime.timedelta(days=max(window_days, 1) - 1)).isoformat()
        else:
            win_start = ""
        res["window_start"] = win_start

        wired = {"skills": set(), "agents": set()}
        for data in datas:
            for day, bucket in (data.get("days") or {}).items():
                if not _is_day(day, today) or not isinstance(bucket, dict):
                    continue
                # Counts: window only.
                if day >= win_start:
                    for kind in COUNT_KINDS:
                        counts = bucket.get(kind)
                        if not isinstance(counts, dict):
                            continue
                        for name, n in counts.items():
                            res[kind][name] = res[kind].get(name, 0) + _int(n)
                # Tokens: every stored day, bucketed by month.
                toks = bucket.get("tokens")
                if isinstance(toks, dict):
                    month = res["tokens"].setdefault(day[:7], {})
                    for model, fields in toks.items():
                        if not isinstance(fields, dict):
                            continue
                        slot = month.setdefault(model, {f: 0 for f in TOKEN_FIELDS})
                        for f in TOKEN_FIELDS:
                            slot[f] += _int(fields.get(f))
            w = data.get("wired")
            if isinstance(w, dict):
                for kind in ("skills", "agents"):
                    if isinstance(w.get(kind), list):
                        # Names come from a pulled file: keep only well-formed ones, and a
                        # bounded number, so no hostile name reaches the report.
                        wired[kind].update([n for n in w[kind] if isinstance(n, str)
                                            and NAME_RE.match(n)][:MAX_WIRED_NAMES])
            # Earliest day any host saw a name wired (only well-formed names and days).
            fs = data.get("wired_first_seen")
            if isinstance(fs, dict):
                for kind in ("skills", "agents"):
                    names = fs.get(kind)
                    for n, d in (names.items() if isinstance(names, dict) else ()):
                        if isinstance(n, str) and NAME_RE.match(n) and _is_day(d, today):
                            cur = res["wired_first_seen"][kind].get(n)
                            res["wired_first_seen"][kind][n] = d if cur is None else min(cur, d)
        res["wired"] = {k: sorted(v) for k, v in wired.items()}
        # Zero counts (e.g. malformed values) are noise; drop them.
        for kind in COUNT_KINDS:
            res[kind] = {k: v for k, v in sorted(res[kind].items()) if v}
        out[harness] = res

    out["ignored"] = sorted(ignored)
    return out
