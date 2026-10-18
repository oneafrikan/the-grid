#!/usr/bin/env python3
"""instincts weekly analyser (openspec change `instincts`, group 3).

    python3 -I analyse.py analyse [--all | --project ID] [--dry-run] [--force] [--no-sync]
    python3 -I analyse.py status  [--project ID]
    python3 -I analyse.py sync

Run through scripts/instincts.sh (`instincts.sh analyse`, `status`, `sync`).

What `analyse` does, per opted-in project (a local observation dir exists):

  1. DIGEST  Build a compact, scrubbed summary of the week's observations in
             plain Python. The program does the counting; no model is involved.
  2. CALL    One isolated, tool-less, budget-capped `claude -p` call. The
             versioned prompt (prompts/analyse-v1.md) is the system prompt and
             the digest alone is stdin.
  3. CHECK   Parse the reply (a JSON array, nothing else) and validate every
             item against the digest it was shown (ids, citations, sessions).
  4. MERGE   Apply deterministic confidence rules and write this host's
             instinct file in the private store. Confidence is NEVER read from
             model text.
  5. RECORD  status.json (machine-local funnel + idempotency marker) and one
             run-record line per project.
  6. SYNC    Unless --dry-run or --no-sync: pull, commit and push this host's
             instincts in the private repo (run_sync; best effort, never fatal).

Why the funnel is counted (ret / valid / kept): a prior system captured 10,557
observations and produced 0 instincts with no way to tell "the model saw no
habit" from "the validator rejected everything" from "nothing was new". Those
are three different failures and `status` keeps them apart.

Everything here follows design.md of the change (sections Digest, Invocation,
Output validation, Confidence rules, Weekly job, Funnel visibility).

Stdlib only. No network except the one model call. All data is written outside
the repo (lib.py's path helpers refuse a path inside the repo tree).

Exit codes: 0 ok (skips included), 1 at least one project errored, 2 usage.
"""
from __future__ import annotations

import sys

# `python3 -I` drops the script directory from sys.path, so add it by hand to
# import lib. Never write bytecode: a __pycache__ here would land in the repo.
sys.dont_write_bytecode = True
from pathlib import Path  # noqa: E402

sys.path.insert(0, str(Path(__file__).resolve().parent))

import argparse  # noqa: E402
import datetime as dt  # noqa: E402
import fcntl  # noqa: E402
import hashlib  # noqa: E402
import json  # noqa: E402
import math  # noqa: E402
import os  # noqa: E402
import re  # noqa: E402
import shutil  # noqa: E402
import signal  # noqa: E402
import subprocess  # noqa: E402
import tempfile  # noqa: E402
import time  # noqa: E402
from collections import defaultdict  # noqa: E402

import lib  # noqa: E402

# --------------------------------------------------------------------------
# Constants (code defaults; each overridable by an INSTINCTS_* env var)
# --------------------------------------------------------------------------

# The prompt version in force. A published prompt is never edited: a change is a
# new file (analyse-v2.md) and this constant moves.
PROMPT_FILE = "analyse-v1.md"
PROMPT_DIR = Path(__file__).resolve().parent / "prompts"

# Digest caps: (max items, max characters) per section, plus the total cap.
# Budgets sum to 15500, under TOTAL_CAP, so the sum can never overflow.
CAPS = {"P": (40, 6000), "C": (30, 2500), "F": (20, 2800), "E": (20, 1000), "K": (40, 3000)}
META_BUDGET = 200
TOTAL_CAP = 16000

MAX_ITEMS_OUT = 8           # model items beyond the 8th are dropped (over-cap)
RETENTION_DAYS = 28         # local observation files older than this are deleted
KEEP_RUNS = 8               # run history kept per project in status.json
MAX_REPLY_BYTES = 1024 * 1024        # a longer model reply is `not-json`, never held in memory
MAX_OBS_BYTES = 4 * 1024 * 1024      # observation bytes read per week file (a partial last line is dropped)
# The `claude` child sees only these variables (+ LC_*, + names in INSTINCTS_PASS_ENV): the call
# is tool-less, so cloud, git and agent tokens in the parent environment have no business there.
CHILD_ENV_ALLOW = frozenset([
    "PATH", "HOME", "LANG", "TERM", "ANTHROPIC_API_KEY", "CLAUDE_CODE_OAUTH_TOKEN", "CLAUDE_CONFIG_DIR",
    "HTTP_PROXY", "HTTPS_PROXY", "NO_PROXY", "http_proxy", "https_proxy", "no_proxy"])
FILE_TOOLS = frozenset(["Edit", "Write", "MultiEdit", "NotebookEdit"])
OUTPUT_KEYS = frozenset(["kind", "id", "trigger", "action", "domain", "evidence"])

# Confidence rules (design: Confidence rules).
CONF_NEW = 0.3
CONF_STEP = 0.15
CONF_MAX = 0.9
CONF_MIN = 0.3            # below this an instinct is retired
DECAY_AFTER_MISSES = 4
DECAY_STEP = 0.1
CONTRADICT_STEP = 0.3     # a contradict demotes; the < CONF_MIN rule retires

# Ordering hint only (design: Digest): a likely correction or stated preference.
CORR_RE = re.compile(r"\b(instead|rather than|not|don'?t|never|always|stop|wrong|again|i said|prefer)\b", re.I)

# Fixed funnel WARN thresholds (design: Funnel visibility).
WARN_UNANALYSED = 200


def _env_int(name: str, default: int) -> int:
    try:
        return int(os.environ[name])
    except (KeyError, ValueError):
        return default


def _env_float(name: str, default: float) -> float:
    """Float env override; a missing, malformed or non-finite value (nan/inf defeat every
    comparison and cap built on it) falls back to the default."""
    try:
        v = float(os.environ[name])
    except (KeyError, ValueError):
        return default
    return v if math.isfinite(v) else default


def min_obs() -> int:
    return _env_int("INSTINCTS_MIN_OBS", 40)


def max_projects() -> int:
    return max(1, _env_int("INSTINCTS_MAX_PROJECTS", 5))      # a negative cap must not slice from the end


# --------------------------------------------------------------------------
# Time (INSTINCTS_NOW lets tests simulate later weeks)
# --------------------------------------------------------------------------

def now_utc() -> dt.datetime:
    """Current time, or INSTINCTS_NOW (`YYYY-MM-DD` or `YYYY-MM-DDTHH:MM:SSZ`)."""
    raw = os.environ.get("INSTINCTS_NOW", "").strip()
    if raw:
        try:
            if len(raw) == 10:
                return dt.datetime.combine(dt.date.fromisoformat(raw), dt.time(12, 0))
            return dt.datetime.fromisoformat(raw.replace("Z", "+00:00")).replace(tzinfo=None)
        except ValueError:
            pass
    return dt.datetime.now(dt.timezone.utc).replace(tzinfo=None)


def iso_week(d: dt.date) -> str:
    y, w, _ = d.isocalendar()
    return f"{y}-W{w:02d}"


def week_end(week: str) -> dt.date | None:
    """Sunday of an ISO `YYYY-Www` week, or None when it does not parse."""
    m = re.fullmatch(r"(\d{4})-W(\d{2})", week)
    if not m:
        return None
    try:
        return dt.date.fromisocalendar(int(m.group(1)), int(m.group(2)), 7)
    except ValueError:
        return None


# --------------------------------------------------------------------------
# Small IO helpers
# --------------------------------------------------------------------------

def atomic_write(path: Path, text: str) -> None:
    """Write via a temp file in the same dir, then rename: never a half-written file."""
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=str(path.parent), prefix=".tmp-" + path.name + ".")
    try:
        # errors="replace": a lone surrogate that slipped through must never turn into a crash mid-write
        with os.fdopen(fd, "w", encoding="utf-8", errors="replace") as fh:
            fh.write(text)
        os.chmod(tmp, 0o600)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def read_jsonl(path: Path, max_bytes: int | None = None) -> list:
    """Parsed objects of a JSONL file; unreadable file -> []; bad lines are skipped.

    With max_bytes only the first max_bytes are read and a line cut by the limit is dropped,
    so a huge (or tampered) file cannot exhaust memory or time.
    """
    out = []
    try:
        if max_bytes is None:
            text = path.read_text(encoding="utf-8", errors="replace")
        else:
            with open(path, "rb") as fh:
                raw = fh.read(max_bytes + 1)
            if len(raw) > max_bytes:
                raw = raw[:max_bytes]
                raw = raw[:raw.rfind(b"\n") + 1]        # drop the partial last line
            text = raw.decode("utf-8", errors="replace")
    except OSError:
        return out
    for ln in text.splitlines():
        try:
            out.append(json.loads(ln))
        except ValueError:
            continue
    return out


PROJECT_DIR_RE = re.compile(r"^[0-9a-f]{12}$")


def project_dirs() -> list[str]:
    """Project ids that have a local observation dir (= opted in on this machine)."""
    base = lib.instincts_state_dir()
    if not base.is_dir():
        return []
    return sorted(p.name for p in base.iterdir() if p.is_dir() and PROJECT_DIR_RE.fullmatch(p.name))


def enabled_state(pid: str) -> str:
    """`enabled`, `not-enabled` (no machine-local marker) or `opt-out` (the flag is off everywhere now).

    The marker is written by the emitter (deploy_hooks.py) and lists the checkout roots, so the
    analyser can re-read `learning:` there: a project switched off since still has a marker
    until the emitter is re-run, and must not be sent to a model. It is enabled while ANY listed
    checkout that still exists has the flag on; roots that no longer exist cannot be checked
    and, when none exists, the project counts as enabled (the marker is the operator's own act).
    """
    roots = lib.marker_roots(pid)
    if roots is None:
        return "not-enabled"
    existing = [r for r in roots if Path(r).is_dir()]
    if not existing:
        return "enabled"
    for r in existing:
        try:
            text = (Path(r) / ".grid" / "project.yaml").read_text(encoding="utf-8")
        except (OSError, UnicodeDecodeError):
            continue
        if lib.read_learning_flag(text):
            return "enabled"
    return "opt-out"


def obs_files(pid: str) -> list[Path]:
    return sorted((lib.instincts_state_dir() / pid).glob("obs-*.jsonl"))


def load_observations(pid: str, since_ts: str | None) -> list[dict]:
    """Observation events of a project in file order, oldest first.

    since_ts: only events with ts > since_ts (the window since the last analysis);
    None means every retained file (first run, or --force).
    Malformed lines and events without a usable `ev` are skipped.
    """
    events: list[dict] = []
    for f in obs_files(pid):
        for o in read_jsonl(f, MAX_OBS_BYTES):
            if not isinstance(o, dict) or o.get("ev") not in ("tool", "prompt"):
                continue
            if not isinstance(o.get("in"), str):
                continue
            if o["ev"] == "tool" and not isinstance(o.get("tool"), str):
                continue          # a list or dict here would crash the builders (unhashable)
            ts = o.get("ts") if isinstance(o.get("ts"), str) else ""
            if since_ts is not None and ts <= since_ts:
                continue
            events.append(o)
    # ISO timestamps sort lexically; sorted() is stable so equal ts keep file order.
    events.sort(key=lambda o: o.get("ts") if isinstance(o.get("ts"), str) else "")
    return events


# --------------------------------------------------------------------------
# Store (private repo): per-host instinct files and the read-time merge
# --------------------------------------------------------------------------

def project_store(pid: str) -> Path:
    return lib.store_dir() / pid


def host_file(pid: str) -> Path:
    return project_store(pid) / f"{lib.host_name()}.jsonl"


def read_host_lines(path: Path) -> list:
    """This host's file as a list of validated dicts or raw strings.

    A line that does not validate (tampered, or written by a newer version) is
    kept VERBATIM as a string so a rewrite never destroys data it does not
    understand; it simply takes no part in the view.
    """
    out: list = []
    try:
        text = path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return out
    for ln in text.splitlines():
        if not ln.strip():
            continue
        try:
            obj = lib.validate_instinct(json.loads(ln))
        except (ValueError, TypeError, RecursionError):
            obj = None
        out.append(obj if obj is not None else ln)
    return out


def merged_view(pid: str) -> tuple[dict[str, dict], int]:
    """(active instincts by id, retired count) merged across every host's file.

    Design (Merge across hosts): group by id, take the max confidence and latest
    last_seen among active lines; an id is retired when some host's line for it
    is retired with last_seen >= the latest last_seen of every active line.
    """
    by_id: dict[str, list[dict]] = defaultdict(list)
    d = project_store(pid)
    if d.is_dir():
        for f in sorted(d.glob("*.jsonl")):
            for entry in read_host_lines(f):
                if isinstance(entry, dict):
                    by_id[entry["id"]].append(entry)
    active: dict[str, dict] = {}
    retired = 0
    for iid, lines in by_id.items():
        act = [x for x in lines if x.get("status", "active") != "retired"]
        ret = [x for x in lines if x.get("status") == "retired"]
        latest = max((x.get("last_seen", "") for x in act), default="")
        if act and not any(r.get("last_seen", "") >= latest for r in ret):
            best = dict(max(act, key=lambda x: (x.get("confidence", 0), x.get("last_seen", ""))))
            best["last_seen"] = latest
            best["weeks_seen"] = max(x.get("weeks_seen", 0) for x in act)
            active[iid] = best
        else:
            retired += 1
    return active, retired


# --------------------------------------------------------------------------
# Digest
# --------------------------------------------------------------------------

_SEGMENT_SPLIT = re.compile(r"\s*(?:\|\||\||&&|;)\s*")
# Digit runs become N, but only standalone ones (`pytest -n 5` -> `-n N`); a digit
# glued to a word (`python3`) stays, matching the design's own digest examples.
_DIGITS = re.compile(r"\b\d+\b")


def clean(text: str) -> str:
    """Scrub then flatten to one plain line (defence in depth: capture already scrubs)."""
    return lib.sanitize(lib.scrub(text))


def safe(text: str) -> str:
    """Digest input rule (D40): rewrite absolute paths, drop every line that holds a secret
    keyword with a value, a long token-like run, an email, host, IP, SSN or card number, then
    scrub and flatten. "" when nothing is left, and the caller then sends nothing."""
    kept = lib.drop_sensitive_lines(lib.outside_paths(text))
    return clean(kept) if kept.strip() else ""


def strip_delims(text: str) -> str:
    """Remove the digest delimiters from item text so it cannot imitate a real line.

    Every `<`, `>` and the word digest (any case) becomes a space, in ONE pass, and whitespace
    is re-collapsed. One substitution cannot rebuild a delimiter out of its own leftovers (the old
    three sequential removals turned `DIGDIGESTEST>>DIGEST>` back into `DIGEST>>>`).
    """
    t = re.sub(r"[<>]|digest", " ", text, flags=re.I)
    return re.sub(r"\s+", " ", t).strip()


def prompt_stems(text: str) -> str:
    """A correction reduced to keyword stems; "" for any prompt that is not a correction.

    Only correction prompts (CORR_RE) reach the digest, and as the correction words plus up to
    8 plain lowercase words of 3-20 letters (no digits, no punctuation inside): the sentence the
    developer typed is never sent, so free text (names, secrets in prose) cannot ride along.
    """
    low = safe(text).lower()
    if not low or not CORR_RE.search(low):
        return ""
    kws: list[str] = []
    for k in CORR_RE.findall(low):
        k = k.lower()
        if k not in kws:
            kws.append(k)
    words: list[str] = []
    for w in low.split():
        w = w.strip(".,;:!?()[]{}\"'")
        if re.fullmatch(r"[a-z]{3,20}", w) and w not in kws and w not in words:
            words.append(w)
        if len(words) >= 8:
            break
    return " ".join(kws + words)


def norm_cmd(text: str, max_len: int = 120) -> str:
    """Command normalisation: first segment only, digits to N, long tokens to <long>.

    "" for a command that passes a value to `-p`/`-w` of an unlisted tool (lib.unlisted_secret_flag):
    capture already refuses those, this covers observation files written before the rule existed.
    """
    if lib.unlisted_secret_flag(text):
        return ""
    seg = strip_delims(_SEGMENT_SPLIT.split(safe(text), maxsplit=1)[0])
    seg = _DIGITS.sub("N", seg)
    # The `<long>` marker is added AFTER the delimiter strip (which blanks every `<` and `>`);
    # it is always its own space-separated token, so it can never join a delimiter.
    seg = " ".join("<long>" if len(tok) > 40 else tok for tok in seg.split())
    return seg[:max_len]


def norm_path(text: str) -> str:
    return strip_delims(safe(text))[:200]


class Item:
    """One digest item: text, program-computed counts, and the sessions behind it."""

    __slots__ = ("text", "n", "sids", "last", "corr")

    def __init__(self, text: str):
        self.text = text
        self.n = 0
        self.sids: set[str] = set()
        self.last = ""
        self.corr = False

    def add(self, sid: str, ts: str) -> None:
        self.n += 1
        self.sids.add(sid)
        if ts > self.last:
            self.last = ts


def _merge(pairs) -> dict[str, Item]:
    """pairs of (text, sid, ts) -> merged Items keyed by text (identical text merged)."""
    items: dict[str, Item] = {}
    for text, sid, ts in pairs:
        if not text:
            continue
        it = items.get(text)
        if it is None:
            it = items[text] = Item(text)
        it.add(sid, ts)
    return items


def _sid(o: dict) -> str:
    s = o.get("sid")
    return s if isinstance(s, str) else ""


def _ts(o: dict) -> str:
    t = o.get("ts")
    return t if isinstance(t, str) else ""


def build_p(events) -> list[Item]:
    items = _merge((prompt_stems(o["in"]), _sid(o), _ts(o)) for o in events if o["ev"] == "prompt")
    for it in items.values():
        it.corr = bool(CORR_RE.search(it.text))
    # corr first, then s desc, n desc, newest; text last so the order is total.
    return sorted(items.values(), key=lambda i: (not i.corr, -len(i.sids), -i.n, _neg(i.last), i.text))


def build_c(events) -> list[Item]:
    items = _merge((norm_cmd(o["in"]), _sid(o), _ts(o))
                   for o in events if o["ev"] == "tool" and o.get("tool") == "Bash")
    return sorted(items.values(), key=lambda i: (-i.n, -len(i.sids), _neg(i.last), i.text))


def build_e(events) -> list[Item]:
    items = _merge((norm_path(o["in"]), _sid(o), _ts(o))
                   for o in events if o["ev"] == "tool" and o.get("tool") in FILE_TOOLS)
    return sorted(items.values(), key=lambda i: (-i.n, -len(i.sids), _neg(i.last), i.text))


def norm_side(tool, text: str) -> str:
    """One side of an F pair: a command (Bash) or a path, max 80 chars."""
    return norm_cmd(text, 80) if tool == "Bash" else norm_path(text)[:80]


def build_f(events) -> list[Item]:
    """Failure -> different successful call of the same tool within 5 events, same session."""
    by_sid: dict[str, list[dict]] = defaultdict(list)
    for o in events:
        by_sid[_sid(o)].append(o)
    pairs = []
    for sid, seq in by_sid.items():
        for i, o in enumerate(seq):
            if o["ev"] != "tool" or o.get("err") is not True:
                continue
            for nxt in seq[i + 1:i + 6]:
                if (nxt["ev"] == "tool" and nxt.get("tool") == o.get("tool")
                        and nxt.get("err") is not True and nxt["in"] != o["in"]):
                    a, b = norm_side(o.get("tool"), o["in"]), norm_side(nxt.get("tool"), nxt["in"])
                    if a and b and a != b:
                        pairs.append((f"{a} -> {b}", sid, _ts(nxt)))
                    break          # first qualifying fix only; the failure is used once
    items = _merge(pairs)
    return sorted(items.values(), key=lambda i: (-i.n, _neg(i.last), i.text))


def _neg(ts: str):
    """Sort key making a larger (newer) timestamp sort first inside an ascending sort."""
    return tuple(-ord(c) for c in ts)


def take(lines: list[str], max_items: int, budget: int) -> int:
    """How many leading lines fit the item cap and the character budget.

    A section over budget drops whole lowest-ranked items, never truncates one.
    Each line costs its length plus the newline that joins it.
    """
    used = 0
    n = 0
    for ln in lines[:max_items]:
        if used + len(ln) + 1 > budget:
            break
        used += len(ln) + 1
        n += 1
    return n


class Digest:
    """The digest text plus the program's private ref -> sessions map."""

    def __init__(self):
        self.text = ""
        self.counts: dict[str, int] = {}          # items kept per section
        self.refs: dict[str, set[str]] = {}       # ref id -> sids (K refs: empty set)
        self.corr_refs: set[str] = set()          # P refs flagged corr
        self.k_ids: dict[str, dict] = {}          # K ref -> stored instinct
        self.obs = 0
        self.sessions = 0
        self.max_ts = ""


def build_digest(events: list[dict], known: dict[str, dict], now: dt.datetime) -> Digest:
    d = Digest()
    d.obs = len(events)
    d.sessions = len({_sid(o) for o in events})
    d.max_ts = max((_ts(o) for o in events), default="")

    meta = f"META window={iso_week(now.date())} obs={d.obs} sessions={d.sessions}"
    lines = [meta[:META_BUDGET]]

    def section(code: str, items: list[Item], fmt) -> None:
        cap, budget = CAPS[code]
        rendered = [(fmt(k, it), it) for k, it in enumerate(items[:cap], 1)]
        kept = take([r for r, _ in rendered], cap, budget)
        d.counts[code] = kept
        for k, (line, it) in enumerate(rendered[:kept], 1):
            lines.append(line)
            d.refs[f"{code}{k}"] = set(it.sids)
            if code == "P" and it.corr:
                d.corr_refs.add(f"P{k}")

    def counts(code):
        return lambda k, it: f"{code}{k} n={it.n} s={len(it.sids)}  {it.text}"

    section("P", build_p(events),
            lambda k, it: f"P{k} n={it.n} s={len(it.sids)}{' corr' if it.corr else ''}  {it.text}")
    section("C", build_c(events), counts("C"))
    section("F", build_f(events), counts("F"))
    section("E", build_e(events), counts("E"))

    # K: this project's merged active instincts, highest confidence first.
    ranked = sorted(known.values(), key=lambda x: (-x.get("confidence", 0), x["id"]))
    k_lines = []
    for x in ranked[:CAPS["K"][0]]:
        k_lines.append((x, strip_delims(f"{x['id']} | {x['trigger']} | {x['action']}")))
    kept = take([f"K{i} {t}" for i, (_, t) in enumerate(k_lines, 1)], *CAPS["K"])
    d.counts["K"] = kept
    for i, (x, t) in enumerate(k_lines[:kept], 1):
        lines.append(f"K{i} {t}")
        d.refs[f"K{i}"] = set()
        d.k_ids[f"K{i}"] = x

    body = "\n".join(lines)
    d.text = "<<<DIGEST\n" + body + "\nDIGEST>>>"
    # Belt and braces: the budgets make this unreachable, but the cap is a contract.
    assert len(d.text) <= TOTAL_CAP, "digest over the total cap"
    return d


# --------------------------------------------------------------------------
# Prompt file
# --------------------------------------------------------------------------

def load_prompt() -> tuple[str, str, str]:
    """(body, version, hash8): the prompt file with its front matter stripped.

    hash8 is the first 8 hex of sha256 of the body, recorded as pv=<version>:<hash8>
    so any result is attributable to an exact prompt.
    """
    text = (PROMPT_DIR / PROMPT_FILE).read_text(encoding="utf-8")
    version = "?"
    body = text
    if text.startswith("---\n"):
        end = text.find("\n---\n", 4)
        if end != -1:
            front = text[4:end]
            body = text[end + 5:]
            m = re.search(r"^version:\s*(\S+)\s*$", front, re.M)
            if m:
                version = m.group(1)
    body = body.strip()
    return body, version, hashlib.sha256(body.encode("utf-8")).hexdigest()[:8]


# --------------------------------------------------------------------------
# Model call and reply parsing
# --------------------------------------------------------------------------

class Reply(str):
    """The model's reply text; `cost_flag` names a cost problem (`cost-invalid`, `cost-over-cap`)."""

    cost_flag: str | None = None


class CallError(Exception):
    """The call did not produce a usable reply; .reason is timeout|exit|budget|not-json|not-array."""

    def __init__(self, reason: str, cost: float | None = None):
        super().__init__(reason)
        self.reason = reason
        self.cost = cost


def command_line(body: str) -> list[str]:
    """The exact isolation recipe from the design (same as agent-factory/run_evals.py)."""
    return [
        os.environ.get("GRID_CLAUDE") or "claude", "-p",
        "--model", os.environ.get("INSTINCTS_MODEL") or "haiku",
        "--system-prompt", body,
        "--tools", "",
        "--disable-slash-commands",
        "--setting-sources", "",
        "--strict-mcp-config",
        "--no-session-persistence",
        "--max-turns", "1",
        "--output-format", "json",
        "--max-budget-usd", repr(_env_float("INSTINCTS_BUDGET_USD", 0.05)),   # never a raw nan/inf string
    ]


def child_env() -> dict:
    """The environment the `claude` child gets: an allowlist, never the parent's whole env."""
    extra = {n for n in re.split(r"[,\s]+", os.environ.get("INSTINCTS_PASS_ENV", "")) if n}
    env = {k: v for k, v in os.environ.items()
           if k in CHILD_ENV_ALLOW or k.startswith("LC_") or k in extra}
    env["GRID_INSTINCTS_SKIP"] = "1"          # so this call is never observed by the capture hook
    return env


def call_model(body: str, digest: str) -> tuple[str, float | None]:
    """Run the one call; return (reply text, cost). Raises CallError on any failure."""
    timeout = _env_float("INSTINCTS_TIMEOUT_S", 120)
    argv = command_line(body)
    exe = shutil.which(argv[0])               # an absolute path: no PATH surprises inside the child
    if exe is None:
        raise CallError("exit")
    argv[0] = exe
    # A fresh empty cwd so no project files or settings can be picked up.
    with tempfile.TemporaryDirectory(prefix="instincts-call-") as cwd, tempfile.TemporaryFile() as outf:
        try:
            # Own process group so a timeout kills grandchildren too. stdout goes to a file,
            # not a pipe, so the reply size can be bounded without reading it all into memory.
            proc = subprocess.Popen(argv, stdin=subprocess.PIPE, stdout=outf, stderr=subprocess.DEVNULL,
                                    cwd=cwd, env=child_env(), start_new_session=True)
        except OSError:
            raise CallError("exit")

        def kill() -> None:
            try:
                os.killpg(proc.pid, signal.SIGKILL)
            except OSError:
                pass
            proc.wait()

        try:
            # The digest is capped at TOTAL_CAP chars, far below the pipe buffer: no writer thread.
            proc.stdin.write(digest.encode("utf-8", errors="replace"))
            proc.stdin.close()
        except OSError:
            pass                              # the child may exit without reading; the exit code tells
        deadline = time.monotonic() + timeout
        while True:
            try:
                proc.wait(timeout=0.2)
                break
            except subprocess.TimeoutExpired:
                if os.fstat(outf.fileno()).st_size > MAX_REPLY_BYTES:
                    kill()
                    raise CallError("not-json")
                if time.monotonic() > deadline:
                    kill()
                    raise CallError("timeout")
        outf.seek(0)
        out = outf.read(MAX_REPLY_BYTES + 1)
    if len(out) > MAX_REPLY_BYTES:
        raise CallError("not-json")
    text = out.decode("utf-8", errors="replace")
    try:
        env_json = json.loads(text)
    except ValueError:
        env_json = None
    cost, cost_flag = None, None
    if isinstance(env_json, dict) and isinstance(env_json.get("total_cost_usd"), (int, float)) \
            and not isinstance(env_json.get("total_cost_usd"), bool):
        raw_cost = float(env_json["total_cost_usd"])
        if math.isfinite(raw_cost) and raw_cost >= 0:
            cost = raw_cost
            if cost > _env_float("INSTINCTS_BUDGET_USD", 0.05):
                cost_flag = "cost-over-cap"           # the CLI's cap is soft; say so when it was exceeded
        else:
            cost_flag = "cost-invalid"                # NaN or negative: never logged as a cost
    if proc.returncode != 0:
        raise CallError("exit", cost)
    if not isinstance(env_json, dict):
        raise CallError("not-json", cost)
    if env_json.get("is_error"):
        # The CLI reports a spent cap as subtype error_max_budget_usd.
        raise CallError("budget" if "budget" in str(env_json.get("subtype", "")) else "exit", cost)
    result = env_json.get("result")
    if not isinstance(result, str):
        raise CallError("not-json", cost)
    reply = Reply(result)
    reply.cost_flag = cost_flag
    return reply, cost


def parse_reply(result: str) -> list:
    """The whole reply must be a JSON array, with at most one surrounding code fence.

    No text outside the array is tolerated and none is searched for.
    """
    s = result.strip()
    lines = s.splitlines()
    if len(lines) >= 2 and re.fullmatch(r"```(?:json)?", lines[0].strip()) and lines[-1].strip() == "```":
        s = "\n".join(lines[1:-1]).strip()
    try:
        parsed = json.loads(s)
    except (ValueError, RecursionError):       # deeply nested input raises RecursionError
        raise CallError("not-json")
    if not isinstance(parsed, list):
        raise CallError("not-array")
    return parsed


# --------------------------------------------------------------------------
# Output validation (design table, applied in order; first failure drops the item)
# --------------------------------------------------------------------------

def check_field_shapes(item: dict) -> bool:
    """bad-field: types, id regex, length caps and enums, before the unsafe-text check."""
    # Types first: a list or dict is unhashable and would raise on a frozenset lookup.
    if not (isinstance(item["kind"], str) and isinstance(item["id"], str) and isinstance(item["domain"], str)):
        return False
    if item["kind"] not in lib.KINDS or not lib.ID_RE.fullmatch(item["id"]):
        return False
    t, a = item["trigger"], item["action"]
    if not (isinstance(t, str) and isinstance(a, str)):
        return False
    if not t.strip() or not a.strip() or len(t) > lib.MAX_TRIGGER or len(a) > lib.MAX_ACTION:
        return False
    # The prompt requires a trigger that starts with when, before or after.
    if not re.match(r"(?i)(?:when|before|after)\b", t.strip()):
        return False
    if item["domain"] not in lib.DOMAINS:
        return False
    ev = item["evidence"]
    return (isinstance(ev, list) and 1 <= len(ev) <= 6
            and all(isinstance(e, str) and 0 < len(e) <= 16 for e in ev))


# Personal-data shapes an instinct must not carry: email, IPv4, SSN-like, absolute path.
_PII_RE = re.compile(
    r"[\w.+-]+@[\w-]+\.[\w.-]+"
    r"|(?<![\w.])(?:\d{1,3}\.){3}\d{1,3}(?![\w])"
    r"|(?<!\d)\d{3}-\d{2}-\d{4}(?!\d)"
    r"|(?:^|\s)/(?:[\w.-]+/[\w./-]+|(?:etc|home|usr|var|srv|opt|tmp|root|Users)\b)")


def validate_items(items: list, digest: Digest, known: dict[str, dict]):
    """-> (valid items, drops by reason). Each valid item is a dict:
    {kind, id, trigger, action, domain} where confirm/contradict carry the STORED text.
    """
    drops: dict[str, int] = defaultdict(int)
    valid: list[dict] = []
    seen_ids: set[str] = set()
    for idx, raw in enumerate(items):
        if idx >= MAX_ITEMS_OUT:
            drops["over-cap"] += 1
            continue
        # bad-shape: an object with exactly the six keys.
        if not isinstance(raw, dict) or set(raw.keys()) != OUTPUT_KEYS:
            drops["bad-shape"] += 1
            continue
        if not check_field_shapes(raw):
            drops["bad-field"] += 1
            continue
        # unsafe-text: the shared denylist, on the raw AND the sanitised text so
        # hidden characters cannot split a word past it. Text the scrubber would
        # change (a secret shape, hidden characters) is also dropped rather than
        # stored half-redacted: a habit with [REDACTED] in it is useless anyway.
        if any(lib.UNSAFE_RE.search(v) or lib.UNSAFE_RE.search(lib.sanitize(v)) or lib.scrub(v) != v
               for v in (raw["trigger"], raw["action"])):
            drops["unsafe-text"] += 1
            continue
        # pii: shapes that must never be stored as a habit or sent back out through sync.
        if any(_PII_RE.search(v) for v in (raw["trigger"], raw["action"])):
            drops["pii"] += 1
            continue
        cleaned = lib.validate_instinct(raw)
        if cleaned is None:
            drops["bad-field"] += 1
            continue
        if raw["id"] in seen_ids:
            drops["dup-id"] += 1
            continue
        seen_ids.add(raw["id"])
        kind = raw["kind"]
        was_new = kind == "new"
        if kind in ("confirm", "contradict") and raw["id"] not in known:
            drops["unknown-id"] += 1
            continue
        if any(e not in digest.refs for e in raw["evidence"]):
            drops["bad-ref"] += 1
            continue
        # Evidence bars (D46): "confirm" means the habit showed up again, so it must cite at
        # least one real observation item (P, C, F or E: a K ref only points at the stored
        # instinct itself) covering two sessions. A `new` is judged as a new FIRST, so re-using
        # a stored id cannot dodge the two-session rule by being re-typed to a confirm.
        sids = set().union(*(digest.refs[e] for e in raw["evidence"]))
        if kind in ("new", "confirm") and len(sids) < 2:
            drops["thin-evidence"] += 1
            continue
        if kind == "new" and raw["id"] in known:
            kind = "confirm"            # a `new` with a stored id is a confirm, judged as one
        if kind == "contradict" and not any(e in digest.corr_refs for e in raw["evidence"]):
            drops["no-correction"] += 1
            continue
        if kind == "new":
            valid.append({"kind": "new", "id": cleaned["id"], "trigger": cleaned["trigger"],
                          "action": cleaned["action"], "domain": cleaned["domain"]})
        else:
            stored = known[raw["id"]]
            # The model's text is ignored: a confirm/contradict cannot rewrite an instinct.
            valid.append({"kind": kind, "id": raw["id"], "trigger": stored["trigger"],
                          "action": stored["action"], "domain": stored["domain"],
                          "was_new": was_new})
    return valid, dict(drops)


# --------------------------------------------------------------------------
# Merge: deterministic confidence rules
# --------------------------------------------------------------------------

def apply_items(pid: str, valid: list[dict], week: str):
    """Apply valid items and decay to this host's file. -> (stats dict, changed bool).

    Confidence rules (design):
      new            0.3
      confirm        +0.15 once per ISO week not yet counted, cap 0.9, weeks_seen+1, misses reset
      not mentioned  misses+1; from misses >= 4, confidence -0.1 per run
      contradict     retired at once
      confidence < 0.3 -> retired
    """
    path = host_file(pid)
    entries = read_host_lines(path)
    known, _ = merged_view(pid)
    host = lib.host_name()
    stats = {"new": 0, "confirmed": 0, "retired": 0, "kept": 0}
    touched: set[str] = set()
    changed = False

    def mine(iid: str):
        # The LAST line of this host for the id: an approval or a retirement appends a line, and the
        # newest one is the state to carry forward.
        for i in range(len(entries) - 1, -1, -1):
            if isinstance(entries[i], dict) and entries[i]["id"] == iid:
                return i
        return None

    def put(entry: dict) -> None:
        nonlocal changed
        i = mine(entry["id"])
        if i is None:
            entries.append(entry)
        else:
            entries[i] = entry
        changed = True

    for v in valid:
        iid = v["id"]
        touched.add(iid)
        if v["kind"] == "new":
            # `pending`: not injected into any session until the operator runs `instincts.sh approve ID`.
            put({"id": iid, "trigger": v["trigger"], "action": v["action"], "domain": v["domain"],
                 "scope": "project", "project": pid, "confidence": CONF_NEW, "weeks_seen": 1,
                 "first_seen": week, "last_seen": week, "misses": 0, "status": "pending", "host": host})
            stats["new"] += 1
            stats["kept"] += 1
            continue
        base = known[iid]                                  # merged view: text and last_seen
        i = mine(iid)
        cur = dict(entries[i]) if i is not None and entries[i].get("status") != "retired" else dict(base)
        cur["host"] = host
        if v["kind"] == "contradict":
            # One correction line is not proof: demote by CONTRADICT_STEP (the < CONF_MIN rule
            # retires it once it falls low enough). Counted once per ISO week, like decay.
            if cur.get("last_contradict_week") == week:
                continue
            cur["confidence"] = round(cur.get("confidence", CONF_NEW) - CONTRADICT_STEP, 2)
            cur["last_contradict_week"] = week
            cur["misses"] = 0
            if cur["confidence"] < CONF_MIN - 1e-9:
                cur.update(status="retired", last_seen=week)
                stats["retired"] += 1
            put(cur)
            stats["kept"] += 1
            continue
        # confirm: counted at most once per ISO week (the merged last_seen is the truth
        # across hosts, so a second host does not double-count the same week).
        if base.get("last_seen", "") == week:
            continue                                       # valid, but nothing to change
        cur["confidence"] = min(CONF_MAX, round(cur.get("confidence", CONF_NEW) + CONF_STEP, 2))
        cur["weeks_seen"] = max(cur.get("weeks_seen", 0), base.get("weeks_seen", 0)) + 1
        cur["last_seen"] = week
        cur["misses"] = 0
        put(cur)
        stats["confirmed"] += 1
        stats["kept"] += 1

    # Decay: this host's active instincts not mentioned in a run that had enough observations.
    for i, e in enumerate(entries):
        if not isinstance(e, dict) or e.get("status") == "retired" or e["id"] in touched:
            continue
        if e.get("last_decay_week") == week:
            continue                    # decay is once per ISO week: --force or a crash retry must not repeat it
        e = dict(e)
        e["last_decay_week"] = week
        e["misses"] = e.get("misses", 0) + 1
        if e["misses"] >= DECAY_AFTER_MISSES:
            e["confidence"] = round(e.get("confidence", CONF_NEW) - DECAY_STEP, 2)
            if e["confidence"] < CONF_MIN - 1e-9:
                e["status"] = "retired"
                stats["retired"] += 1
        entries[i] = e
        changed = True

    if changed:
        text = "".join((json.dumps(e, ensure_ascii=False, sort_keys=False) if isinstance(e, dict) else e) + "\n"
                       for e in entries)
        atomic_write(path, text)
        write_meta(pid)
    return stats, changed


def write_meta(pid: str) -> None:
    """META.json {"id","display","first_seen"} if missing.

    The analyser only has the project id; a capture-side `META.json` in the
    local obs dir (if it ever carries one) supplies the display name, else the id.
    """
    path = project_store(pid) / "META.json"
    if path.exists():
        return
    display = pid
    try:
        local = json.loads((lib.instincts_state_dir() / pid / "META.json").read_text(encoding="utf-8"))
        if isinstance(local, dict) and isinstance(local.get("display"), str):
            display = lib.sanitize(lib.scrub(local["display"]), 200) or pid
    except (OSError, ValueError):
        pass
    atomic_write(path, json.dumps({"id": pid, "display": display,
                                   "first_seen": now_utc().date().isoformat()}) + "\n")


# --------------------------------------------------------------------------
# status.json (machine-local) and run record
# --------------------------------------------------------------------------

def status_path() -> Path:
    return lib.instincts_state_dir() / "status.json"


def load_status() -> dict:
    """status.json, keeping every top-level key we do not own.

    Our keys are `version` and `projects` (per-project funnel). Other writers add
    their own top-level keys (promote records `pending_global`); they must survive
    our rewrite, and are never treated as project ids. A file that exists but cannot be
    parsed is NOT silently reset: a warning goes to stderr and a copy is kept as
    status.json.bak before the next save replaces it.
    """
    data: dict = {}
    path = status_path()
    try:
        loaded = json.loads(path.read_text(encoding="utf-8"))
        if isinstance(loaded, dict):
            data = loaded
        else:
            raise ValueError("not a JSON object")
    except FileNotFoundError:
        pass
    except (OSError, ValueError, RecursionError) as e:
        print(f"instincts: warning: status.json is unreadable ({e}); starting a new one, old copy kept as status.json.bak",
              file=sys.stderr)
        try:
            shutil.copyfile(path, path.with_name(path.name + ".bak"))
        except OSError:
            pass
    if not isinstance(data.get("projects"), dict):
        data["projects"] = {}
    # A hand-edited or partial entry must not crash status/analyse: keep only well-shaped parts.
    for pid, ps in list(data["projects"].items()):
        if not isinstance(ps, dict):
            data["projects"][pid] = {}
            continue
        if not isinstance(ps.get("runs"), list) or not all(isinstance(r, dict) for r in ps.get("runs", [])):
            ps.pop("runs", None)
        if "last_run" in ps and not isinstance(ps["last_run"], dict):
            ps.pop("last_run")
    data.setdefault("version", 1)
    return data


def save_status(st: dict) -> None:
    atomic_write(status_path(), json.dumps(st, indent=2, sort_keys=True) + "\n")


def record_run(pid: str, outcome: str, cost: float | None, note: str) -> None:
    """One run-log line via scripts/run-record.sh; a failure there is a warning only."""
    cmd = ["bash", str(lib.REPO_ROOT / "scripts" / "run-record.sh"), "--role", "instincts",
           "--action", "analyse", "--outcome", outcome, "--target", pid, "--note", note]
    if cost is not None:
        cmd += ["--cost-usd", f"{cost:.4f}"]
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
        if r.returncode != 0:
            print(f"instincts: run-record failed: {r.stderr.strip()}", file=sys.stderr)
    except (OSError, subprocess.SubprocessError) as e:
        print(f"instincts: run-record failed: {e}", file=sys.stderr)


def fmt_dropped(drops: dict) -> str:
    return ",".join(f"{k}:{v}" for k, v in sorted(drops.items(), key=lambda kv: (-kv[1], kv[0]))) or "-"


def run_note(run: dict, pv: str) -> str:
    parts = [f"obs={run['obs']}"]
    if run["outcome"] == "ok":
        parts += [f"ret={run['ret']}", f"valid={run['valid']}", f"kept={run['kept']}", f"new={run['new']}",
                  f"confirmed={run['confirmed']}", f"retired={run['retired']}",
                  f"dropped={fmt_dropped(run['dropped'])}"]
    parts.append(f"pv={pv}")
    if run.get("err"):
        parts.append(f"err={run['err']}")
    if run.get("flag"):
        parts.append(f"flag={run['flag']}")
    return " ".join(parts)


# --------------------------------------------------------------------------
# analyse
# --------------------------------------------------------------------------

def plan(pids: list[str], force: bool, now: dt.datetime, st: dict):
    """Split projects into (to analyse, skipped as [(pid, reason, obs)]).

    Window = events since the project's last analysis (all retained files with --force).
    """
    week = iso_week(now.date())
    todo, skipped = [], []
    for pid in pids:
        state = enabled_state(pid)
        if state != "enabled":
            # Never sent to a model: no marker (not opted in on this machine) or the repo flag is off now.
            skipped.append((pid, state, None))
            continue
        ps = st["projects"].get(pid, {})
        if not force and ps.get("last_week") == week:
            skipped.append((pid, "already-analysed", None))
            continue
        events = load_observations(pid, None if force else ps.get("last_ts"))
        if len(events) < min_obs():
            skipped.append((pid, "too-few-obs", len(events)))
            continue
        todo.append((pid, events))
    # Most observations first; the cap keeps the weekly bill bounded.
    todo.sort(key=lambda t: (-len(t[1]), t[0]))
    for pid, events in todo[max_projects():]:
        skipped.append((pid, "max-projects", len(events)))
    return todo[:max_projects()], skipped


def acquire_lock():
    """Non-blocking exclusive lock on <state>/instincts/.analyse.lock, or None when held.

    Two overlapping real runs (cron plus a manual run) would each call the model and the
    last status.json writer would win; the second now stops. The descriptor stays open for
    the life of the process, which is the lock's life.
    """
    path = lib.instincts_state_dir() / ".analyse.lock"
    path.parent.mkdir(parents=True, exist_ok=True)
    fd = os.open(path, os.O_RDWR | os.O_CREAT, 0o600)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        os.close(fd)
        return None
    return fd


def cmd_analyse(args) -> int:
    if os.environ.get("GRID_INSTINCTS") == "0":
        # The kill switch stops analysis (and its upload) as well as capture; even --dry-run.
        print("instincts: GRID_INSTINCTS=0: analysis disabled, nothing sent")
        return 0
    lock = None
    if not args.dry_run:
        # Before status.json is read: a run that starts while another finishes must not work from
        # (and then overwrite with) a stale copy.
        lock = acquire_lock()
        if lock is None:
            print("instincts: already running (another analysis holds the lock); nothing done")
            return 0
    now = now_utc()
    week = iso_week(now.date())
    st = load_status()
    pids = project_dirs()
    if args.project:
        if args.project not in pids:
            print(f"instincts: unknown project '{lib.sanitize(args.project, 40)}' (no observation directory)",
                  file=sys.stderr)
            return 2
        pids = [args.project]
    body, version, h8 = load_prompt()
    pv = f"{version}:{h8}"
    todo, skipped = plan(pids, args.force, now, st)

    if args.dry_run:
        # Print only. No call, no write, no run-record, no status.
        print(f"window={week} prompt={PROMPT_FILE} pv={pv} eligible={len(todo)} skipped={len(skipped)}")
        shown = command_line("<body of " + PROMPT_FILE + ">")
        print("planned command: " + " ".join(f'"{a}"' if a == "" else a for a in shown))
        for pid, reason, obs in skipped:
            print(f"project {pid}: skipped ({reason}{'' if obs is None else f', obs={obs}'})")
        for pid, events in todo:
            known, _ = merged_view(pid)
            d = build_digest(events, known, now)
            print(f"project {pid}: obs={d.obs} sessions={d.sessions} chars={len(d.text)} "
                  + " ".join(f"{c}={d.counts.get(c, 0)}" for c in "PCFEK"))
            print(d.text)
        return 0

    errors = 0
    saved = json.dumps(st, sort_keys=True)

    def save_if_changed() -> None:
        # Saved after every project, so a crash later in the loop cannot lose finished work
        # (and the next run cannot repeat a paid call).
        nonlocal saved
        now_text = json.dumps(st, sort_keys=True)
        if now_text != saved:
            save_status(st)
            saved = now_text

    for pid, reason, obs in skipped:
        # An already-analysed week changes nothing (a second run is a true no-op
        # apart from its run-log line); other skips note why in status.json.
        if reason != "already-analysed":
            st["projects"].setdefault(pid, {})["last_skip"] = {"week": week, "reason": reason}
        record_run(pid, "skipped", None, f"obs={obs if obs is not None else '-'} reason={reason} pv={pv}")
        print(f"project {pid}: skipped ({reason})")
    for pid, events in todo:
        try:
            run = analyse_project(pid, events, week, now, body, st)
        except lib.RepoPathError:
            raise                       # a data path inside the repo is a configuration error, not a crash
        except Exception as e:  # noqa: BLE001 - one bad project must not abort the weekly run
            print(f"instincts: project {pid}: {type(e).__name__}", file=sys.stderr)
            run = {"week": week, "at": now.strftime("%Y-%m-%dT%H:%M:%SZ"), "obs": len(events),
                   "outcome": "error", "cost": None, "err": "crash"}
        run["pv"] = pv
        ps = st["projects"].setdefault(pid, {})
        runs = ps.setdefault("runs", [])
        runs.append(run)
        del runs[:-KEEP_RUNS]
        ps["last_run"] = run
        ps.pop("last_skip", None)
        if run["outcome"] == "ok":
            ps["last_week"] = week
            if run.get("max_ts"):
                ps["last_ts"] = run["max_ts"]
        else:
            errors += 1
        record_run(pid, run["outcome"], run.get("cost"), run_note(run, pv))
        if run["outcome"] == "ok":
            print(f"project {pid}: ok obs={run['obs']} ret={run['ret']} valid={run['valid']} kept={run['kept']}")
            prune_observations(pid, now)
        else:
            print(f"project {pid}: error ({run['err']})")
        save_if_changed()
    save_if_changed()
    if not (skipped or todo):
        print("instincts: no projects to analyse")
    run_promote()
    if not args.no_sync:
        # Best effort and exit-code neutral: the analysis result is what the run reports.
        run_sync()
    return 1 if errors else 0


def run_promote() -> None:
    """End of every real run: the deterministic, model-free promotion pass (lib.promote).

    It lists cross-project candidates and records them under `pending_global` in
    status.json (after we have saved ours, so it sees the final file); it never
    writes an unapproved global instinct. It lands with instincts group 4; until
    then lib has no promote and this is a no-op. A failure here never fails the run.
    """
    fn = getattr(lib, "promote", None)
    if fn is None:
        return
    try:
        for c in fn() or []:
            if isinstance(c, dict):
                print(f"pending global: {c.get('id')} projects={c.get('projects')} "
                      f"conf={float(c.get('confidence', 0)):.2f}")
    except Exception as e:  # noqa: BLE001 - best effort, never the reason a weekly run fails
        print(f"instincts: promote failed: {e}", file=sys.stderr)


def analyse_project(pid, events, week, now, body, st) -> dict:
    """Digest, call, validate, merge for one project. Never raises for model/data problems."""
    known, _ = merged_view(pid)
    digest = build_digest(events, known, now)
    run = {"week": week, "at": now.strftime("%Y-%m-%dT%H:%M:%SZ"), "obs": digest.obs,
           "max_ts": digest.max_ts, "outcome": "error", "cost": None}
    try:
        result, cost = call_model(body, digest.text)
        run["cost"] = cost
        if getattr(result, "cost_flag", None):
            run["flag"] = result.cost_flag
        items = parse_reply(result)
    except CallError as e:
        run["err"] = e.reason
        if e.cost is not None:
            run["cost"] = e.cost
        return run                      # error outcome: no writes at all
    valid, drops = validate_items(items, digest, known)
    # Every analysed project met the minimum observations, so decay always applies.
    stats, _ = apply_items(pid, valid, week)
    run.update(outcome="ok", ret=len(items), valid=len(valid), kept=stats["kept"], new=stats["new"],
               confirmed=stats["confirmed"], retired=stats["retired"], dropped=drops)
    return run


def prune_observations(pid: str, now: dt.datetime) -> None:
    """After a successful run: delete local observation files older than 28 days.

    The rule lives in lib.prune_old_obs (capture also applies it whenever it creates a
    new week file, so retention does not depend on this analyser running). Age is judged
    by the ISO week in the file name (the Sunday that ends it). Analysed files younger
    than that stay so --force can re-run.
    """
    lib.prune_old_obs(lib.instincts_state_dir() / pid, now, RETENTION_DAYS)


# --------------------------------------------------------------------------
# status
# --------------------------------------------------------------------------

def unanalysed_count(pid: str, ps: dict) -> int:
    return len(load_observations(pid, ps.get("last_ts")))


def warnings(pid: str, ps: dict, unanalysed: int) -> list[str]:
    """The four WARN rules (design: Funnel visibility)."""
    out = []
    runs = ps.get("runs", [])
    if unanalysed >= WARN_UNANALYSED:
        out.append(f"{unanalysed} observations since the last analysis (>= {WARN_UNANALYSED})")
    last2 = runs[-2:]
    if len(last2) == 2 and all(r.get("outcome") == "ok" for r in last2):
        if all(r.get("ret") == 0 and r.get("obs", 0) >= WARN_UNANALYSED for r in last2):
            out.append(f"two consecutive analyses returned nothing (ret=0) with >= {WARN_UNANALYSED} observations each")
        if all(r.get("ret", 0) > 0 and r.get("kept") == 0 for r in last2):
            out.append("two consecutive analyses returned items but kept none (ret>0 kept=0)")
    if runs and runs[-1].get("outcome") == "error":
        out.append(f"the last run errored ({runs[-1].get('err', '?')})")
    return out


def verdict(run: dict) -> str:
    """Name which kind of zero this is (they need different fixes)."""
    if run.get("outcome") != "ok":
        return "run errored"
    if run.get("ret") == 0:
        return "model returned nothing (no habit seen)"
    if run.get("valid") == 0:
        return "validator dropped everything (prompt and validator disagree)"
    if run.get("kept") == 0:
        return "valid items changed nothing (nothing new)"
    return "store changed"


def cmd_status(args) -> int:
    st = load_status()
    pids = sorted(set(project_dirs()) | set(st["projects"]))
    if args.project:
        pids = [p for p in pids if p == args.project]
    if not pids:
        print("instincts status: no projects")
        return 0
    for pid in pids:
        ps = st["projects"].get(pid, {})
        unan = unanalysed_count(pid, ps) if (lib.instincts_state_dir() / pid).is_dir() else 0
        active, retired = merged_view(pid)
        print(f"project {pid}")
        print(f"  observations since last analysis: {unan}")
        print(f"  last analysis week: {ps.get('last_week', 'never')}")
        run = ps.get("last_run")
        if run:
            print(f"  last run: {run.get('outcome', '?')} ({run.get('week', '?')})")
            if run.get("outcome") == "ok":
                print(f"  funnel: ret={run.get('ret', '?')} valid={run.get('valid', '?')} kept={run.get('kept', '?')}")
                dropped = run.get("dropped") if isinstance(run.get("dropped"), dict) else {}
                print(f"  top drop reasons: {fmt_dropped(dict(list(sorted(dropped.items(), key=lambda kv: -kv[1]))[:3]))}")
            else:
                print(f"  error reason: {run.get('err', '?')}")
            print(f"  reading: {verdict(run)}")
            print(f"  last cost: {'unknown' if run.get('cost') is None else '$%.4f' % run['cost']}")
            print(f"  prompt version: {run.get('pv', '?')}")
        else:
            print("  no analysis run yet")
        print(f"  instincts: active={len(active)} retired={retired}")
        for w in warnings(pid, ps, unan):
            print(f"  WARN: {w}")
    return 0


# --------------------------------------------------------------------------
# Private-repo sync (group 5)
# --------------------------------------------------------------------------

GIT_TIMEOUT_S = 120   # one hung network call must not wedge the weekly job


def _sync_warn(msg: str) -> None:
    """A sync problem is a warning, never a failure: the analysis already succeeded."""
    print(f"instincts: sync warning: {msg}", file=sys.stderr)


def _private_git(priv: Path, *args: str) -> subprocess.CompletedProcess:
    """Run `git -C <private> ARGS`. Hook-exported GIT_* vars are dropped so the call
    targets the private repo, and prompts are disabled so a missing credential fails
    fast instead of waiting on a terminal (cron has none)."""
    env = {k: v for k, v in os.environ.items()
           if k not in ("GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE")}
    env["GIT_TERMINAL_PROMPT"] = "0"
    return subprocess.run(["git", "-C", str(priv), *args], capture_output=True, text=True,
                          timeout=GIT_TIMEOUT_S, env=env)


def _store_pathspec(priv: Path) -> str:
    """The synced instincts path relative to the private repo (default learning/instincts).
    The ONLY path sync ever stages; it is never `-A`."""
    try:
        return str(lib.store_dir().resolve().relative_to(priv.resolve()))
    except ValueError:
        return "learning/instincts"


def _unstage_large(priv: Path, pathspec: str) -> bool:
    """Guard the size of what is about to be committed; return True to REFUSE the commit.

    A NEW file over MAX_SYNC_FILE_BYTES is unstaged (with a warning) and the rest is
    committed (a 60 MB junk file once went into a private repo through a bare `git add`).
    A file that is already TRACKED is different: the commit below is `git commit -- <path>`,
    which re-takes the working-tree content of every tracked file under the path, so
    unstaging it would not keep it out. Then the whole commit is refused and everything this
    run staged is unstaged again, so the warning is true: nothing over the cap is committed."""
    r = _private_git(priv, "diff", "--cached", "--name-only", "-z", "--", pathspec)
    refuse = False
    for name in filter(None, r.stdout.split("\0")):
        try:
            size = (priv / name).stat().st_size
        except OSError:
            continue   # staged deletion: nothing on disk to measure
        if size > MAX_SYNC_FILE_BYTES:
            tracked = _private_git(priv, "cat-file", "-e", "HEAD:" + name).returncode == 0
            if tracked:
                refuse = True
                _sync_warn(f"not committing anything: tracked file {name} is {size} bytes, over the "
                           f"{MAX_SYNC_FILE_BYTES} byte limit")
            else:
                _private_git(priv, "reset", "-q", "HEAD", "--", name)
                _sync_warn(f"not committing {name}: {size} bytes is over the {MAX_SYNC_FILE_BYTES} byte limit")
    if refuse:
        _private_git(priv, "reset", "-q", "HEAD", "--", pathspec)
    return refuse


GUARD = Path(__file__).resolve().parent.parent / "lib" / "private-git-guard.sh"
MAX_SYNC_FILE_BYTES = 1 << 20   # a stray large file must not be committed into the private repo


def _guard(*args: str) -> subprocess.CompletedProcess:
    """Run the shared guard (scripts/lib/private-git-guard.sh), also used by the
    weekly usage job, so both jobs apply one definition of "safe to touch the repo"."""
    return subprocess.run(["bash", str(GUARD), *args], capture_output=True, text=True,
                          timeout=GIT_TIMEOUT_S)


def run_sync() -> int:
    """Stage the instincts path, commit if staged, pull --rebase, push.

    The operator may be mid-rebase in the private repo, so: a busy repo (rebase/merge in
    progress, detached HEAD, unmerged entries, no upstream) skips the whole sync; the pull
    is skipped, never autostashed, while tracked files outside the instincts path are
    modified; the push needs the .grid-private-remote marker to match and every unpushed
    commit to touch only the instincts path.
    Returns 0 for every outcome (a git, network or filesystem failure prints a warning),
    except 4 when the push was refused because of a foreign unpushed commit.
    """
    try:
        priv = lib.private_dir()
        if not priv.is_dir():
            print(f"instincts: sync skipped: {priv} is not a directory")
            return 0
        # Require the private dir to BE a repo root, not a folder inside some other
        # repo, so a mis-set GRID_PRIVATE_DIR cannot commit into an unrelated project.
        top = _private_git(priv, "rev-parse", "--show-toplevel")
        if top.returncode != 0 or Path(top.stdout.strip()).resolve() != priv.resolve():
            print(f"instincts: sync skipped: {priv} is not a git repo")
            return 0
        pathspec = _store_pathspec(priv)
        msg = f"instincts: {lib.host_name()} {lib.current_week()}"

        # The operator's work in progress is never ours to touch: skip the whole sync.
        busy = _guard("precheck", str(priv))
        if busy.returncode != 0:
            print(f"instincts: sync skipped: private repo busy ({busy.stdout.strip()})")
            return 0
        refuse = False
        # On a machine that has produced no instincts yet the path does not exist and
        # `git add` would fail on it; there is simply nothing to stage then.
        if (priv / pathspec).exists():
            r = _private_git(priv, "add", "--", pathspec)
            if r.returncode != 0:
                _sync_warn("git add failed: " + r.stderr.strip())
                return 0
            refuse = _unstage_large(priv, pathspec)
        # diff --cached --quiet: exit 0 = nothing staged, 1 = staged change.
        staged = _private_git(priv, "diff", "--cached", "--quiet", "--", pathspec)
        if refuse:
            pass   # warned above; nothing is committed this run
        elif staged.returncode == 0:
            print("instincts: sync: no changes to commit")
        elif staged.returncode == 1:
            # Commit only our path so anything else already staged in the private repo is left alone.
            # Committing before the pull leaves the path clean, so no autostash is needed.
            r = _private_git(priv, "commit", "-m", msg, "--", pathspec)
            if r.returncode != 0:
                _sync_warn("git commit failed: " + (r.stderr.strip() or r.stdout.strip()))
                return 0
            print(f"instincts: sync: committed '{msg}'")
        else:
            _sync_warn("git diff failed: " + staged.stderr.strip())
            return 0
        # Pull only while no tracked file outside our path is modified: a rebase refuses
        # then, and --autostash would re-apply the operator's edit into conflict markers.
        if _guard("outside-clean", str(priv), pathspec).returncode == 0:
            r = _private_git(priv, "pull", "--rebase")
            if r.returncode != 0:
                # Keep going: pushing local work is still worth trying. The precheck above
                # proved no rebase was running, so one found now is ours: abort it.
                _sync_warn("git pull failed: " + (r.stderr.strip() or r.stdout.strip()))
                if _guard("precheck", str(priv)).stdout.strip() == "rebase-in-progress":
                    _private_git(priv, "rebase", "--abort")
        else:
            print("instincts: sync: private repo has other changes; pull skipped")
        # A failed pull must never leave a conflicted state that is pushed from.
        busy = _guard("precheck", str(priv))
        if busy.returncode != 0:
            _sync_warn(f"push skipped: private repo busy ({busy.stdout.strip()})")
            return 0
        ok = _guard("push-ok", str(priv), pathspec)
        if ok.returncode != 0:
            _sync_warn(f"push skipped: {ok.stdout.strip()}")
            # 4 = foreign unpushed commit; 3 (remote not confirmed) stays a warning.
            return 4 if ok.returncode == 4 else 0
        # Push EXACTLY the remote and branch push-ok validated: a bare `git push` follows
        # push.default, branch.<b>.pushRemote and remote.pushDefault.
        args = _guard("push-args", str(priv))
        if args.returncode != 0:
            _sync_warn(f"push skipped: {args.stdout.strip()}")
            return 0
        remote, refspec = args.stdout.split()
        # "pushed" is printed only when something was actually ahead of the upstream.
        ahead = _private_git(priv, "rev-list", "--count", "@{u}..HEAD")
        if ahead.returncode == 0 and ahead.stdout.strip() == "0":
            print("instincts: sync: nothing to push")
            return 0
        r = _private_git(priv, "-c", "push.default=nothing", "push", remote, refspec)
        if r.returncode != 0:
            _sync_warn("git push failed: " + (r.stderr.strip() or r.stdout.strip()))
        else:
            print("instincts: sync: pushed")
    except (OSError, subprocess.SubprocessError, lib.RepoPathError) as e:
        _sync_warn(str(e))
    return 0


# --------------------------------------------------------------------------
# CLI
# --------------------------------------------------------------------------

def main(argv: list[str]) -> int:
    # Digest text can hold characters the terminal's codec cannot print: replace, never raise.
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.reconfigure(errors="replace")
        except (AttributeError, ValueError):
            pass
    ap = argparse.ArgumentParser(prog="instincts.sh", add_help=True)
    sub = ap.add_subparsers(dest="cmd")
    a = sub.add_parser("analyse", help="weekly analysis of local observations")
    grp = a.add_mutually_exclusive_group()
    grp.add_argument("--all", action="store_true", help="every opted-in project (the default)")
    grp.add_argument("--project", metavar="ID", help="only this project id")
    a.add_argument("--dry-run", action="store_true", help="print the digest and plan; call and write nothing")
    a.add_argument("--force", action="store_true", help="re-analyse even if done this ISO week")
    a.add_argument("--no-sync", action="store_true", help="do not pull/commit/push the private repo afterwards")
    sub.add_parser("sync", help="pull, commit and push this host's instincts in the private repo")
    s = sub.add_parser("status", help="funnel and warnings")
    s.add_argument("--project", metavar="ID")
    try:
        args = ap.parse_args(argv)
    except SystemExit as e:
        return 2 if e.code else 0
    if args.cmd == "analyse":
        return cmd_analyse(args)
    if args.cmd == "status":
        return cmd_status(args)
    if args.cmd == "sync":
        return run_sync()
    ap.print_usage(sys.stderr)
    return 2


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except lib.RepoPathError as e:
        print(f"instincts: {e}", file=sys.stderr)
        sys.exit(2)
