"""Claude Code adapter: turns ~/.claude/projects/**/*.jsonl transcripts into
normalised usage events (see adapters/__init__.py for the contract).

The transcript format is undocumented and changes without notice, so this file
only reads the handful of fields it needs and never copies free text out.

Why de-duplication matters here: resumed sessions copy their history into a new
transcript file (keeping the original timestamps), and one assistant message is
streamed as several records that share a message id. Counts are later
max-merged by the extractor, which can never repair an inflated value, so every
count below must be right the first time.
"""
from __future__ import annotations

import json
import os
import re

# Names we are willing to store. Anything else (paths, pasted prose,
# "<synthetic>") is dropped, so free text can never reach the output file.
NAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9:_.-]{0,63}$")
# Hook names are "<event>" or "<event>:<matcher>"; a matcher may be a regex such
# as "Edit|Write", so allow a few more characters than NAME_RE (still no "/" or
# whitespace). The hook *command* (which holds paths) is never read.
HOOK_NAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9:_.|*()-]{0,127}$")
DAY_RE = re.compile(r"^\d{4}-\d{2}-\d{2}$")
# A slash command is only a message that STARTS with <command-name> (optionally
# after one <command-message>..</command-message>). No "leading /token" fallback.
SLASH_RE = re.compile(
    r"^\s*(?:<command-message>.*?</command-message>\s*)?"
    r"<command-name>\s*(.*?)\s*</command-name>",
    re.DOTALL,
)
DEFAULT_AGENT = "(default)"  # Agent/Task call with no subagent_type


def _count(value):
    """A token count: non-int, bool or negative values count as 0."""
    if isinstance(value, bool) or not isinstance(value, int) or value < 0:
        return 0
    return value


def _day(record):
    """UTC day from the record timestamp, or None when missing/malformed."""
    ts = record.get("timestamp")
    if isinstance(ts, str) and DAY_RE.match(ts[:10]):
        return ts[:10]
    return None


def _list_names(path, strip_md=False):
    """Sorted visible entry names of a directory, or None when it is missing."""
    try:
        names = os.listdir(path)
    except OSError:
        return None
    out = []
    for n in names:
        if n.startswith("."):
            continue
        if strip_md:
            if not n.endswith(".md"):
                continue
            n = n[:-3]
        out.append(n)
    return sorted(out)


class ClaudeCode:
    name = "claude-code"

    def __init__(self):
        self.projects = os.environ.get("CLAUDE_PROJECTS_DIR") or os.path.expanduser("~/.claude/projects")
        self._reset_stats()

    def _reset_stats(self):
        # Drift canary: the extractor warns when these look wrong (e.g. many
        # lines but no assistant records). Never written to the output file.
        self.stats = {"files": 0, "lines": 0, "bad_lines": 0,
                      "assistant": 0, "no_day": 0, "no_id": 0}

    def available(self):
        return os.path.isdir(self.projects)

    def wired(self):
        skills = _list_names(os.environ.get("SKILLS_DIR") or os.path.expanduser("~/.claude/skills"))
        agents = _list_names(os.environ.get("AGENTS_DIR") or os.path.expanduser("~/.claude/agents"),
                             strip_md=True)
        out = {}
        # A missing directory yields no key, so the merge keeps the old snapshot.
        if skills is not None:
            out["skills"] = skills
        if agents is not None:
            out["agents"] = agents
        return out

    def _files(self):
        """Every *.jsonl under the projects dir, in a stable order.
        Yields (path, is_subagent_file)."""
        for root, dirs, files in os.walk(self.projects):
            dirs.sort()
            for f in sorted(files):
                if f.endswith(".jsonl"):
                    path = os.path.join(root, f)
                    rel = os.path.relpath(path, self.projects).split(os.sep)
                    yield path, "subagents" in rel[:-1]

    def events(self, since_day=None):
        self._reset_stats()
        st = self.stats
        # De-duplication state. tool ids / uuids are kept in one set per kind;
        # tokens keep one small max-record per message id (~8k per 30 days).
        seen_tools, seen_slash, seen_hooks, seen_listing = set(), set(), set(), set()
        messages = {}  # message id -> [day, model|None, in, out, cache_read, cache_write]

        def wanted(day):
            return since_day is None or day >= since_day

        for path, is_sub in self._files():
            st["files"] += 1
            try:
                fh = open(path, "r", encoding="utf-8", errors="replace")
            except OSError:
                st["bad_lines"] += 1  # unreadable file: count it, move on
                continue
            with fh:
                for line in fh:  # streamed: never hold a whole file
                    if not line.strip():
                        continue
                    st["lines"] += 1
                    try:
                        rec = json.loads(line)
                    except ValueError:
                        rec = None
                    if not isinstance(rec, dict):
                        st["bad_lines"] += 1
                        continue
                    rtype = rec.get("type")
                    if rtype == "assistant":
                        st["assistant"] += 1
                    day = _day(rec)
                    if day is None:
                        st["no_day"] += 1
                        continue
                    if rtype == "assistant":
                        yield from self._assistant(rec, day, seen_tools, messages, wanted)
                    elif rtype == "user" and not is_sub:
                        # Slash commands come from top-level files only.
                        ev = self._slash(rec, day, seen_slash, wanted)
                        if ev:
                            yield ev
                    elif rtype == "attachment":
                        ev = self._attachment(rec, day, seen_hooks, seen_listing, wanted)
                        if ev:
                            yield ev

        # Tokens are yielded after the scan: a message's value is the field-wise
        # max over its streamed chunks and its day the earliest chunk day.
        for _mid, (day, model, tin, tout, cr, cw) in sorted(messages.items(), key=lambda kv: (kv[1][0], kv[0])):
            if model is None or not wanted(day):
                continue
            yield {"day": day, "kind": "tokens", "model": model,
                   "in": tin, "out": tout, "cache_read": cr, "cache_write": cw}

    def _assistant(self, rec, day, seen_tools, messages, wanted):
        msg = rec.get("message")
        if not isinstance(msg, dict):
            return
        # Tool calls (skills / agents), keyed by the tool_use block id.
        content = msg.get("content")
        for block in content if isinstance(content, list) else []:
            if not isinstance(block, dict) or block.get("type") != "tool_use":
                continue
            tool_id, tool = block.get("id"), block.get("name")
            inp = block.get("input") if isinstance(block.get("input"), dict) else {}
            if not isinstance(tool_id, str) or tool_id in seen_tools:
                continue
            if tool == "Skill":
                name = inp.get("skill")
                if not isinstance(name, str) or not NAME_RE.match(name):
                    continue  # missing/odd skill name: dropped
                kind = "skill"
            elif tool in ("Agent", "Task"):
                name = inp.get("subagent_type", DEFAULT_AGENT)
                if name != DEFAULT_AGENT and (not isinstance(name, str) or not NAME_RE.match(name)):
                    continue
                kind = "agent"
            else:
                continue
            seen_tools.add(tool_id)
            if wanted(day):
                yield {"day": day, "kind": kind, "name": name}

        # Tokens, keyed by message.id; buffered, yielded after the scan.
        usage = msg.get("usage")
        if not isinstance(usage, dict):
            return
        mid = msg.get("id")
        if not isinstance(mid, str) or not mid:
            self.stats["no_id"] += 1  # uuid is NOT a fallback: it is unique per chunk
            return
        vals = [_count(usage.get("input_tokens")), _count(usage.get("output_tokens")),
                _count(usage.get("cache_read_input_tokens")),
                _count(usage.get("cache_creation_input_tokens"))]
        cur = messages.get(mid)
        if cur is None:
            model = msg.get("model")
            if isinstance(model, str):
                model = re.sub(r"\[[^\]]*\]$", "", model)  # drop "[1m]"-style suffix
            # None marks a model we will not store (e.g. "<synthetic>").
            model = model if isinstance(model, str) and NAME_RE.match(model) else None
            messages[mid] = [day, model] + vals
        else:
            cur[0] = min(cur[0], day)
            for i, v in enumerate(vals):
                cur[2 + i] = max(cur[2 + i], v)

    def _slash(self, rec, day, seen_slash, wanted):
        msg = rec.get("message")
        content = msg.get("content") if isinstance(msg, dict) else None
        if isinstance(content, list):
            texts = [b.get("text") for b in content if isinstance(b, dict) and isinstance(b.get("text"), str)]
            content = texts[0] if texts else None
        if not isinstance(content, str):
            return None
        m = SLASH_RE.match(content)
        uid = rec.get("uuid")
        if not m or not isinstance(uid, str) or uid in seen_slash:
            return None
        name = m.group(1).lstrip("/")
        if not NAME_RE.match(name):
            return None  # e.g. a pasted path
        seen_slash.add(uid)
        return {"day": day, "kind": "slash", "name": name} if wanted(day) else None

    def _attachment(self, rec, day, seen_hooks, seen_listing, wanted):
        att = rec.get("attachment")
        if not isinstance(att, dict):
            return None
        atype = att.get("type")
        uid = rec.get("uuid")
        if isinstance(atype, str) and atype.startswith("hook_"):
            # Name only: command / stdout / stderr / toolUseID are never read.
            hname = att.get("hookName")
            if not isinstance(hname, str) or not HOOK_NAME_RE.match(hname):
                return None
            if not isinstance(uid, str) or uid in seen_hooks:
                return None
            seen_hooks.add(uid)
            return {"day": day, "kind": "hook", "name": hname} if wanted(day) else None
        if atype == "skill_listing" and att.get("isInitial") is True:
            content = att.get("content")
            count = att.get("skillCount")
            if not isinstance(content, str) or isinstance(count, bool) or not isinstance(count, int):
                return None
            if isinstance(uid, str):
                if uid in seen_listing:
                    return None
                seen_listing.add(uid)
            return ({"day": day, "kind": "listing", "skills": count, "chars": len(content)}
                    if wanted(day) else None)
        return None
