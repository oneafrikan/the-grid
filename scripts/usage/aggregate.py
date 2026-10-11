#!/usr/bin/env python3
"""aggregate.py - sum the per-host usage files into one picture (importable, no CLI).

    aggregate(dir, window_days) -> dict

`dir` holds one `<host>.json` per machine, written by scripts/usage/extract.py
(schema 1, see design.md section 3). The result is keyed by HARNESS name
(e.g. "claude-code"); each value holds

    skills / agents / slash / hooks   {name: count} summed over all hosts, over
                                      the WINDOW only (the last `window_days`
                                      days, ending at the latest day stored)
    tokens                            {"YYYY-MM": {model: {msgs, in, out,
                                      cache_read, cache_write}}} summed over all
                                      hosts and ALL stored days (months are the
                                      unit, so the window does not cut them)
    hosts                             number of host files that reported it
    first_day / last_day              earliest / latest day key across hosts
    coverage_days                     inclusive span first_day..last_day
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

SCHEMA = 1                      # the only schema this reader understands
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
    except (OSError, ValueError):          # unreadable, truncated, conflict markers
        return None
    if not isinstance(doc, dict) or doc.get("schema") != SCHEMA:
        return None
    if not isinstance(doc.get("harnesses"), dict):
        return None
    return doc


def _is_day(key) -> bool:
    try:
        datetime.date.fromisoformat(key)
        return True
    except (TypeError, ValueError):
        return False


def aggregate(dir, window_days):
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
                           for d in (data.get("days") or {}) if _is_day(d)})
        res = {"skills": {}, "agents": {}, "slash": {}, "hooks": {},
               "tokens": {}, "hosts": len(datas),
               "first_day": None, "last_day": None, "coverage_days": 0,
               "wired": {"skills": [], "agents": []}}
        if all_days:
            first = datetime.date.fromisoformat(all_days[0])
            last = datetime.date.fromisoformat(all_days[-1])
            res["first_day"], res["last_day"] = all_days[0], all_days[-1]
            res["coverage_days"] = (last - first).days + 1
            # The window ends at the latest day stored, not at "today", so a
            # report on stale data is still self-consistent.
            win_start = (last - datetime.timedelta(days=max(window_days, 1) - 1)).isoformat()
        else:
            win_start = ""

        wired = {"skills": set(), "agents": set()}
        for data in datas:
            for day, bucket in (data.get("days") or {}).items():
                if not _is_day(day) or not isinstance(bucket, dict):
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
                        wired[kind].update(n for n in w[kind] if isinstance(n, str))
        res["wired"] = {k: sorted(v) for k, v in wired.items()}
        # Zero counts (e.g. malformed values) are noise; drop them.
        for kind in COUNT_KINDS:
            res[kind] = {k: v for k, v in sorted(res[kind].items()) if v}
        out[harness] = res

    out["ignored"] = sorted(ignored)
    return out
