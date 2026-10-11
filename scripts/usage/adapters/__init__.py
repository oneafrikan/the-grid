"""Harness adapters for the usage extractor.

The extractor (scripts/usage/extract.py) knows nothing about any harness's
log format. Each harness gets one adapter: a class with these members.

    name        str. Key under "harnesses" in the output file (e.g. "claude-code").
    available() -> bool. True when this harness's logs exist on this machine.
    events(since_day) -> iterator of normalised event dicts (no prompt text).
                since_day is "YYYY-MM-DD" or None; events on earlier days are skipped.
    wired()     -> {"skills": [names], "agents": [names]} as wired on this machine.
                A list the adapter cannot produce is simply left out of the dict
                (the extractor then keeps the previous snapshot of that list).
    stats       dict, optional. Filled while events() runs; the extractor prints
                it as a drift canary but never stores it.

Event shapes (day is the UTC "YYYY-MM-DD" of the event):

    {"day": D, "kind": "skill",   "name": "handoff"}
    {"day": D, "kind": "agent",   "name": "grid-qa-engineer"}
    {"day": D, "kind": "slash",   "name": "handoff"}
    {"day": D, "kind": "hook",    "name": "PreToolUse:Bash"}
    {"day": D, "kind": "listing", "skills": 187, "chars": 30002}
    {"day": D, "kind": "tokens",  "model": "claude-sonnet-5-5",
     "in": 2, "out": 680, "cache_read": 34972, "cache_write": 33172}

Contract: events() yields each logical event EXACTLY ONCE. De-duplication is the
adapter's job (the extractor only sums), and no event may carry prompt text,
paths, message ids, tool ids or uuids.

To add a harness: new module in this package + one line in REGISTRY below.
"""
from .claude_code import ClaudeCode

# Order is not significant; every adapter whose available() is True is run.
REGISTRY = [ClaudeCode]
