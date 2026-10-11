#!/usr/bin/env python3
"""instincts core library: the one place the rules live (openspec change `instincts`).

Imported by the capture, analyse and inject code of later groups, and runnable as
a tiny CLI for the shell dispatcher (scripts/instincts.sh):

    python3 -I lib.py project-id [DIR]   print the project id of the repo at DIR (default .)
    python3 -I lib.py scrub              read stdin, write the scrubbed text to stdout
    python3 -I lib.py promote|approve ID|show [PROJECT]|retire ID [PROJECT]|forget PROJECT --yes|clusters
                                         store commands (group 4), see the functions below

Exit codes (CLI): 0 ok, 1 no git remote (project-id), 2 usage error.

Design rules this module enforces (see openspec/changes/instincts/design.md):
  * One scrub rule set, used at capture, at instinct write and at injection.
  * One UNSAFE_RE, applied inside validate_instinct (so at write, at injection
    and at `show`): the store is git-synced and therefore tamperable.
  * Nothing here ever writes inside the repo tree. The path helpers REFUSE to
    return a location under the repo root, because all data this feature stores
    is private and lives under ~/.grid (machine-local) or the private repo.

Stdlib only; no network.
"""
from __future__ import annotations

import datetime
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import unicodedata
from pathlib import Path

# scripts/instincts/lib.py -> repo root is two levels above this directory.
REPO_ROOT = Path(__file__).resolve().parents[2]

REDACTED = "[REDACTED]"

# --------------------------------------------------------------------------
# Project id
# --------------------------------------------------------------------------

def normalise_remote(url: str) -> str:
    """Reduce a git remote URL to a lowercase scheme-less `host/path`.

    `git@github.com:Owner/Repo.git`, `https://github.com/owner/repo` and
    `https://user:tok@github.com/owner/repo.git/` must all give the same string,
    so the same project gets the same id on every machine and over every protocol.
    """
    u = url.strip()
    if "://" in u:
        # URL form: drop the scheme, then userinfo and port from the authority.
        u = u.split("://", 1)[1]
        authority, _, path = u.partition("/")
        authority = authority.rsplit("@", 1)[-1]          # strip user[:pass]@
        authority = re.sub(r":\d+$", "", authority)       # strip :port (ssh vs https ports differ)
        u = authority + ("/" + path if path else "")
    else:
        # scp-like form `[user@]host:path` (colon before any slash). A plain
        # local path has no such colon and is left alone.
        m = re.match(r"^(?:[^@/:]+@)?([^/:]+):(.*)$", u)
        if m:
            u = m.group(1) + "/" + m.group(2).lstrip("/")
    u = u.lower()
    # Trailing "/" and ".git" can stack ("repo.git/"), so strip until stable.
    while True:
        stripped = u.rstrip("/")
        if stripped.endswith(".git"):
            stripped = stripped[:-4]
        if stripped == u:
            return u
        u = stripped


def project_id(remote_url: str) -> str | None:
    """First 12 hex chars of SHA-256 of the normalised remote; None for a blank URL."""
    norm = normalise_remote(remote_url or "")
    if not norm:
        return None
    return hashlib.sha256(norm.encode("utf-8")).hexdigest()[:12]


def _git(cwd: str, *args: str) -> str | None:
    """Run `git -C cwd ...`; stdout stripped, or None on any failure (never raises)."""
    try:
        r = subprocess.run(["git", "-C", str(cwd), *args], capture_output=True,
                           text=True, timeout=5)
    except (OSError, subprocess.SubprocessError):
        return None
    return r.stdout.strip() if r.returncode == 0 else None


def git_project_id(cwd: str = ".") -> str | None:
    """Project id of the repo at cwd: `origin` if present, else the first remote.

    None when cwd is not a repo or has no remote (capture is then skipped: a path
    hash would split one project into several, see design Decisions).
    """
    url = _git(cwd, "remote", "get-url", "origin")
    if not url:
        remotes = _git(cwd, "remote")
        first = remotes.splitlines()[0] if remotes else ""
        url = _git(cwd, "remote", "get-url", first) if first else None
    return project_id(url) if url else None


# --------------------------------------------------------------------------
# Scrubbing and sanitising
# --------------------------------------------------------------------------

def _is_hidden(ch: str) -> bool:
    """True for characters that are invisible or can steer rendering/injection.

    Cc control chars, Cf format chars (bidi overrides, zero-width space/joiner,
    soft hyphen, tag characters U+E0000..), Zl/Zp line and paragraph separators,
    plus the variation selectors (category Mn, but used to smuggle hidden text).
    """
    if unicodedata.category(ch) in ("Cc", "Cf", "Zl", "Zp"):
        return True
    cp = ord(ch)
    return 0xFE00 <= cp <= 0xFE0F or 0xE0100 <= cp <= 0xE01EF


def _strip_hidden(text: str, keep: str = "") -> str:
    """Drop hidden/control characters, except any character listed in `keep`."""
    return "".join(c for c in text if c in keep or not _is_hidden(c))


# Key names whose value is a secret. `auth` must not eat `author(s|ed)`, but must
# still match `authorization`; hence the lookahead.
_SECRET_KEY = (r"(?:api[_-]?key|token|secret|passw(?:or)?d|auth(?!or(?:s|ed)?\b)"
               r"|credential|private[_-]?key)")

# Each rule is (compiled regex, replacement). Applied in order, so the specific
# shapes run before the generic key=value and high-entropy catch-alls. Where a
# rule has a recognisable prefix (a key, a flag, a URL scheme) the prefix is kept
# and only the secret part is replaced, so the redacted text stays readable.
_SCRUB_RULES: list[tuple[re.Pattern, str]] = [
    # PEM block: header through the END line, or to the end of the text if cut off.
    (re.compile(r"-----BEGIN [A-Z0-9 ]+-----[\s\S]*?(?:-----END [A-Z0-9 ]+-----|\Z)"), REDACTED),
    # JWT: header.payload.signature, header and payload base64url of `{"`.
    (re.compile(r"eyJ[A-Za-z0-9_-]+\.eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]*"), REDACTED),
    # Authorization header (any scheme); keeps the header name.
    (re.compile(r"(?i)(\bAuthorization\s*[:=]\s*)(?:(?:Bearer|Basic|Token)\s+)?[^\s'\"]+"),
     r"\1" + REDACTED),
    # Bare `Bearer <credential>`.
    (re.compile(r"(?i)(\bBearer\s+)[A-Za-z0-9._~+/=-]{8,}"), r"\1" + REDACTED),
    # URL userinfo for ANY scheme (https, postgres, redis, ...); keeps scheme and host.
    (re.compile(r"([a-z][a-z0-9+.-]*://)[^/\s:@]+:[^@\s]+@", re.I), r"\1" + REDACTED + "@"),
    # Known token shapes, anchored so `task-...` cannot trip `sk-`.
    (re.compile(
        r"(?<![A-Za-z0-9])(?:"
        r"gh[pousr]_[A-Za-z0-9]{20,}"            # GitHub classic tokens (ghp_ gho_ ghu_ ghs_ ghr_)
        r"|github_pat_[A-Za-z0-9_]{20,}"         # GitHub fine-grained
        r"|sk-[A-Za-z0-9_-]{16,}"                # API keys incl. sk-ant-
        r"|[sr]k_live_[A-Za-z0-9]{10,}"          # Stripe live keys (sk_live_, rk_live_)
        r"|glpat-[A-Za-z0-9_-]{16,}"             # GitLab PAT
        r"|npm_[A-Za-z0-9]{20,}"                 # npm token
        r"|xox[abprs]-[A-Za-z0-9-]{10,}"         # Slack
        r"|xapp-[A-Za-z0-9-]{10,}"               # Slack app-level
        r"|(?:AKIA|ASIA)[0-9A-Z]{16}"            # AWS access key id / temporary key id
        r"|AIza[0-9A-Za-z_-]{35}"                # Google API key
        r")"), REDACTED),
    # Credential flags with a value: `--password x`, `--token=x`, `-u user:pass`.
    # The lookbehind keeps `--with-token`/`--password-stdin` style flags out.
    (re.compile(r"(?i)((?<![A-Za-z0-9-])--?(?:password|passwd|token|secret|api-?key)(?:=|\s+))['\"]?[^\s'\"]+"),
     r"\1" + REDACTED),
    # `-pSECRET` (mysql style). Attached form only: `-p dir` (mkdir -p dir) and
    # `-p no:cache` (pytest) must be left alone. Cost accepted: `docker -p8080:80`.
    (re.compile(r"((?<=\s)-p)\S+"), r"\1" + REDACTED),
    (re.compile(r"((?<![A-Za-z0-9-])-u\s+)\S+:\S+"), r"\1" + REDACTED),
    # key=value / key: value where the KEY names a secret; also JSON `"key": "v"`.
    (re.compile(r"(?i)(\b[\w.-]*" + _SECRET_KEY + r"[\w.-]*['\"]?\s*[:=]\s*['\"]?)[^\s'\"]+"),
     r"\1" + REDACTED),
]

# Generic high-entropy run: 32+ chars of the base64/url alphabet that holds a
# letter AND a digit. Cost accepted (design): 40-hex commit SHAs and long
# digit-bearing relative paths are redacted too.
_ENTROPY_RUN = re.compile(r"[A-Za-z0-9_\-+/=]{32,}")


def _entropy_sub(m: re.Match) -> str:
    s = m.group(0)
    if any(c.isalpha() for c in s) and any(c.isdigit() for c in s):
        return REDACTED
    return s


def scrub(text: str) -> str:
    """Redact secrets from text and strip hidden unicode / control characters.

    Hidden characters go first so zero-width junk cannot split a token and dodge
    the patterns. Newlines and tabs are kept (multi-line commands stay readable;
    sanitize() flattens them where one line is required). Idempotent.
    """
    out = _strip_hidden(text, keep="\n\t")
    for rx, repl in _SCRUB_RULES:
        out = rx.sub(repl, out)
    return _ENTROPY_RUN.sub(_entropy_sub, out)


def sanitize(text: str, max_len: int | None = None) -> str:
    """One plain line: no control chars, hidden unicode, newlines or backticks.

    Newlines/tabs become a space and runs of whitespace collapse. Truncated to
    max_len when given (None = no cap, used where a too-long value must be
    rejected rather than clipped).
    """
    out = re.sub(r"[\r\n\t]+", " ", text)
    out = _strip_hidden(out).replace("`", "")
    out = re.sub(r"\s+", " ", out).strip()
    return out[:max_len].rstrip() if max_len is not None else out


# --------------------------------------------------------------------------
# Opt-in, host, paths
# --------------------------------------------------------------------------

# One line, top-level key only (no indent): `learning: on|true`, any case, optional comment.
_LEARNING_RE = re.compile(r"^learning:\s*(on|true)\s*(#.*)?$", re.I | re.M)


def learning_enabled(project_root: str | os.PathLike | None) -> bool:
    """True when <root>/.grid/project.yaml has `learning: on|true` and GRID_INSTINCTS != 0."""
    if os.environ.get("GRID_INSTINCTS") == "0" or not project_root:
        return False
    try:
        text = (Path(project_root) / ".grid" / "project.yaml").read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError):
        return False
    return bool(_LEARNING_RE.search(text))


def host_name() -> str:
    """GRID_HOST, else `hostname -s`; lowercased and reduced to [a-z0-9-]."""
    raw = os.environ.get("GRID_HOST", "")
    if not raw:
        try:
            raw = subprocess.run(["hostname", "-s"], capture_output=True, text=True,
                                 timeout=5).stdout.strip()
        except (OSError, subprocess.SubprocessError):
            raw = ""
    if not raw:
        raw = os.uname().nodename.split(".")[0]
    return re.sub(r"[^a-z0-9-]", "-", raw.lower()) or "unknown"


class RepoPathError(ValueError):
    """A data path resolved inside the repo tree (all instincts data is private)."""


def _outside_repo(p: Path) -> Path:
    """Return p, or raise RepoPathError if it lies inside the repo checkout."""
    rp = p.expanduser().resolve()
    if rp == REPO_ROOT or REPO_ROOT in rp.parents:
        raise RepoPathError(f"refusing data path inside the repo: {rp}")
    return p.expanduser()


def state_dir() -> Path:
    """Machine-local state root: $GRID_STATE_DIR, default ~/.grid."""
    return _outside_repo(Path(os.environ.get("GRID_STATE_DIR") or Path.home() / ".grid"))


def instincts_state_dir() -> Path:
    """Raw observations and status.json (never synced, never committed)."""
    return _outside_repo(state_dir() / "instincts")


def private_dir() -> Path:
    """The private git repo: $GRID_PRIVATE_DIR, default ~/.the-grid-private."""
    return _outside_repo(Path(os.environ.get("GRID_PRIVATE_DIR") or Path.home() / ".the-grid-private"))


def learning_dir() -> Path:
    """Private learning store: $GRID_LEARNING_DIR, default <private>/learning."""
    env = os.environ.get("GRID_LEARNING_DIR")
    return _outside_repo(Path(env) if env else private_dir() / "learning")


def store_dir() -> Path:
    """Synced instincts store: <learning>/instincts (per project, per host files)."""
    return _outside_repo(learning_dir() / "instincts")


# --------------------------------------------------------------------------
# Instinct validation
# --------------------------------------------------------------------------

ID_RE = re.compile(r"^[a-z0-9][a-z0-9-]{1,46}[a-z0-9]$")
WEEK_RE = re.compile(r"^\d{4}-W\d{2}$")
DOMAINS = frozenset(["testing", "git", "style", "workflow", "tooling", "docs", "security", "preference"])
SCOPES = frozenset(["project", "global"])
STATUSES = frozenset(["active", "retired"])
KINDS = frozenset(["new", "confirm", "contradict"])   # model-output items only
MAX_TRIGGER = 120
MAX_ACTION = 200

# ONE regex: union of the design's alternatives (prompt-engineer list merged with
# the security review's SEC11b list). Deliberately blunt and unanchored: it is a
# floor under the structural defences, and it drops some legitimate habits that
# mention e.g. `push` or `secret` (cost accepted in the design).
_UNSAFE_ALTERNATIVES = [
    # links and code (the backtick is written as a class so this source file
    # does not need a literal one in a string)
    r"https?://", r"\bwww\.", r"\bftp://", "[`]", r"\$\(", r"<<<", r">>>",
    # commands
    r"\b(?:curl|wget|sudo|ssh|scp|netcat|eval|exec|chmod|chown|base64)\b",
    r"\brm\s+-", r"\|\s*(?:ba|z)?sh\b",
    # gate evasion (SEC11b)
    r"no-verify|hooksPath|GRID_(?:DISABLED_)?HOOKS|disable|skip\s+(?:the\s+)?(?:hook|test|check|gate)|force|push",
    # instruction hijack
    r"\b(?:ignore|disregard|forget)\b.{0,30}\b(?:previous|prior|above|earlier|rules|instructions)\b",
    r"system prompt|developer message|jailbreak",
    # secrets (unanchored so `tokens`, `secrets` also match)
    r"token|password|passwd|secret|credential|api[ _-]?key|private key|\.env\b|id_rsa|id_ed25519",
    # exfiltration
    r"\b(?:exfiltrat\w*|upload|send|post|email)\b.{0,40}\b(?:to|at)\b",
]
UNSAFE_RE = re.compile("|".join(f"(?:{a})" for a in _UNSAFE_ALTERNATIVES), re.I)


def _clean_text(value, cap: int) -> str | None:
    """A trigger/action: str, no backtick/fence, <= cap chars once cleaned, not UNSAFE."""
    if not isinstance(value, str) or "`" in value:       # rejected, not stripped: a fence is hostile
        return None
    cleaned = sanitize(value)                            # newlines, control and hidden chars out
    if not cleaned or len(cleaned) > cap or UNSAFE_RE.search(cleaned):
        return None
    return cleaned


def validate_instinct(obj) -> dict | None:
    """Validate one instinct (stored line or model output item); cleaned dict or None.

    Required: id, trigger, action, domain. Optional fields are validated when
    present and dropped when unknown, so the result holds only vetted keys:
      kind (model output), evidence (1-6 strings), scope, status, project,
      confidence, weeks_seen, misses, first_seen, last_seen, host.
    Any invalid present field rejects the whole item.
    """
    if not isinstance(obj, dict):
        return None
    out: dict = {}
    i = obj.get("id")
    if not isinstance(i, str) or not ID_RE.match(i):
        return None
    out["id"] = i
    trigger = _clean_text(obj.get("trigger"), MAX_TRIGGER)
    action = _clean_text(obj.get("action"), MAX_ACTION)
    if trigger is None or action is None or obj.get("domain") not in DOMAINS:
        return None
    out.update(trigger=trigger, action=action, domain=obj["domain"])

    # Enum-valued optionals.
    for key, allowed in (("kind", KINDS), ("scope", SCOPES), ("status", STATUSES)):
        if key in obj:
            if obj[key] not in allowed:
                return None
            out[key] = obj[key]
    if "evidence" in obj:
        ev = obj["evidence"]
        if not (isinstance(ev, list) and 1 <= len(ev) <= 6
                and all(isinstance(e, str) and 0 < len(e) <= 16 for e in ev)):
            return None
        out["evidence"] = list(ev)

    # Stored-line bookkeeping fields. bool is an int subclass, so exclude it.
    if "confidence" in obj:
        c = obj["confidence"]
        if isinstance(c, bool) or not isinstance(c, (int, float)) or not 0 <= c <= 1:
            return None
        out["confidence"] = float(c)
    for key in ("weeks_seen", "misses"):
        if key in obj:
            n = obj[key]
            if isinstance(n, bool) or not isinstance(n, int) or n < 0:
                return None
            out[key] = n
    for key in ("first_seen", "last_seen"):
        if key in obj:
            if not (isinstance(obj[key], str) and WEEK_RE.match(obj[key])):
                return None
            out[key] = obj[key]
    if "project" in obj:
        p = obj["project"]
        if p is not None and not (isinstance(p, str) and re.fullmatch(r"[0-9a-f]{12}", p)):
            return None
        out["project"] = p
    if "host" in obj:
        h = obj["host"]
        if not (isinstance(h, str) and re.fullmatch(r"[a-z0-9-]{1,63}", h)):
            return None
        out["host"] = h
    return out


# --------------------------------------------------------------------------
# Store reading and the read-time merge (design: Instinct line, Merge across hosts)
# --------------------------------------------------------------------------

GLOBAL_DIR = "_global"          # <store>/_global/<host>.jsonl holds approved global instincts
PROJECT_DIR_RE = re.compile(r"^[0-9a-f]{12}$")

# The exact key set of a STORED line (design: Instinct line). validate_instinct
# silently drops unknown keys, but a stored line carrying extras is tampered or
# from a different writer, so the reader rejects it outright.
_STORED_KEYS = frozenset(["id", "trigger", "action", "domain", "scope", "project", "confidence",
                          "weeks_seen", "first_seen", "last_seen", "misses", "status", "host"])
_STORED_REQUIRED = ("confidence", "last_seen", "status")


def current_week() -> str:
    """ISO week `YYYY-Www` of today; INSTINCTS_NOW=YYYY-MM-DD overrides (tests)."""
    raw = os.environ.get("INSTINCTS_NOW", "")
    try:
        day = datetime.date.fromisoformat(raw) if raw else datetime.date.today()
    except ValueError:
        day = datetime.date.today()
    iso = day.isocalendar()
    return f"{iso[0]}-W{iso[1]:02d}"


def _valid_scope_dir(name: str) -> bool:
    """A store sub-directory name we accept from callers: `_global` or a 12-hex project id."""
    return name == GLOBAL_DIR or bool(PROJECT_DIR_RE.match(name))


def read_lines(scope_dir: str) -> list[dict]:
    """Every valid instinct line of every host file under <store>/<scope_dir>/.

    Invalid JSON, failed validate_instinct (incl. UNSAFE_RE), extra keys or missing
    bookkeeping fields: the line is skipped, never repaired. Files are read in
    sorted order so the result is deterministic. Each result carries `_file`, the
    host file stem it came from (not a stored key).
    """
    if not _valid_scope_dir(scope_dir):
        return []
    d = store_dir() / scope_dir
    out: list[dict] = []
    for f in sorted(d.glob("*.jsonl")) if d.is_dir() else []:
        try:
            raw_lines = f.read_text(encoding="utf-8").splitlines()
        except (OSError, UnicodeDecodeError):
            continue
        for raw in raw_lines:
            try:
                obj = json.loads(raw)
            except ValueError:
                continue
            if not isinstance(obj, dict) or not set(obj) <= _STORED_KEYS \
                    or any(k not in obj for k in _STORED_REQUIRED):
                continue
            v = validate_instinct(obj)
            if v is not None:
                v["_file"] = f.stem
                out.append(v)
    return out


def _line_order(l: dict):
    """Sort key: newest last_seen, then highest confidence, then host (deterministic ties)."""
    return (l["last_seen"], l["confidence"], l.get("_file", ""))


def merge_instincts(scope_dir: str) -> list[dict]:
    """Read-time merge of one project's (or `_global`'s) host files; one dict per id.

    Group lines by id. Among ACTIVE lines take the max confidence and the latest
    last_seen (text fields come from the newest active line). The id is `retired`
    when some host's retired line has last_seen >= the latest last_seen of every
    active line; an id with only retired lines is retired too. Result is sorted by id
    and includes retired ids (status field), so callers filter on status.
    `scope_dir` is a 12-hex project id or `_global`.
    """
    groups: dict[str, list[dict]] = {}
    for l in read_lines(scope_dir):
        groups.setdefault(l["id"], []).append(l)
    merged = []
    for iid in sorted(groups):
        lines = groups[iid]
        active = [l for l in lines if l["status"] == "active"]
        retired = [l for l in lines if l["status"] == "retired"]
        newest_active = max(active, key=_line_order) if active else None
        if retired and (newest_active is None
                        or max(r["last_seen"] for r in retired) >= newest_active["last_seen"]):
            m = dict(max(retired, key=_line_order), status="retired")
        else:
            m = dict(newest_active, status="active")
            m["confidence"] = max(l["confidence"] for l in active)
            firsts = [l["first_seen"] for l in active if "first_seen" in l]
            if firsts:
                m["first_seen"] = min(firsts)
            weeks = [l["weeks_seen"] for l in active if "weeks_seen" in l]
            if weeks:
                m["weeks_seen"] = max(weeks)
        m["scope"] = "global" if scope_dir == GLOBAL_DIR else "project"
        m["project"] = None if scope_dir == GLOBAL_DIR else scope_dir
        m.pop("_file", None)
        merged.append(m)
    return merged


def project_dirs() -> list[str]:
    """Project ids that have a directory in the synced store (sorted; excludes `_global`)."""
    d = store_dir()
    if not d.is_dir():
        return []
    return sorted(p.name for p in d.iterdir() if p.is_dir() and PROJECT_DIR_RE.match(p.name))


# --------------------------------------------------------------------------
# Promotion (design: Promotion; Q4 = a global line needs an explicit `approve`)
# --------------------------------------------------------------------------

PROMOTE_MIN_CONF = 0.5
PROMOTE_MIN_PROJECTS = 2

# Key order of a written line, as in the design's example (stable, diff-friendly).
_LINE_KEY_ORDER = ("id", "trigger", "action", "domain", "scope", "project", "confidence",
                   "weeks_seen", "first_seen", "last_seen", "misses", "status", "host")


def _stored_line(m: dict, host: str) -> dict:
    """The line to write for merged/candidate instinct m: stored keys only, host set."""
    line = dict(m, host=host)
    return {k: line[k] for k in _LINE_KEY_ORDER if k in line}


def _append_line(scope_dir: str, host: str, line: dict) -> None:
    """Append one JSON line to <store>/<scope_dir>/<host>.jsonl (creating it)."""
    path = store_dir() / scope_dir / f"{host}.jsonl"
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "a", encoding="utf-8") as fh:
        fh.write(json.dumps(line) + "\n")


def promotion_candidates() -> list[dict]:
    """Ids active at confidence >= 0.5 in >= 2 distinct project dirs (merged view).

    Each result is the proposed global line: confidence = LOWEST contributing
    confidence (conservative, design Decisions), last_seen = latest, text from the
    most recently seen contributor, plus `projects` (a count, not a stored key).
    Sorted by id. Includes ids that are already approved; callers split those off.
    """
    by_id: dict[str, list[dict]] = {}
    for pid in project_dirs():
        for m in merge_instincts(pid):
            if m["status"] == "active" and m["confidence"] >= PROMOTE_MIN_CONF:
                by_id.setdefault(m["id"], []).append(m)
    out = []
    for iid in sorted(by_id):
        contrib = by_id[iid]
        if len(contrib) < PROMOTE_MIN_PROJECTS:
            continue
        top = max(contrib, key=_line_order)
        cand = dict(top, scope="global", project=None, status="active", misses=0,
                    confidence=min(c["confidence"] for c in contrib),
                    last_seen=max(c["last_seen"] for c in contrib),
                    weeks_seen=max(c.get("weeks_seen", 1) for c in contrib),
                    projects=len(contrib))
        firsts = [c["first_seen"] for c in contrib if "first_seen" in c]
        if firsts:
            cand["first_seen"] = min(firsts)
        out.append(cand)
    return out


def _status_path() -> Path:
    return instincts_state_dir() / "status.json"


def _write_if_changed(path: Path, text: str) -> None:
    """Write text only when it differs, so an idempotent re-run touches nothing."""
    try:
        if path.read_text(encoding="utf-8") == text:
            return
    except OSError:
        pass
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")


def promote() -> list[dict]:
    """Deterministic, model-free promotion pass; returns the PENDING candidates.

    * An id already approved (any line in any host's `_global/*.jsonl`) is never
      pending; if THIS host holds an active line for it, that line's confidence and
      last_seen are refreshed from the current candidates (only when they differ).
    * Every other candidate is pending: recorded under `pending_global` in
      status.json and NEVER written to the store (that needs `approve`).
    Re-running changes no file (status.json is written canonically, only on change).
    """
    host = host_name()
    global_lines = read_lines(GLOBAL_DIR)
    approved = {l["id"] for l in global_lines}
    # This host's latest line per id (read order = file order, so last wins).
    own = {l["id"]: l for l in global_lines if l["_file"] == host}
    pending = []
    for cand in promotion_candidates():
        iid = cand["id"]
        if iid not in approved:
            pending.append(cand)
            continue
        mine = own.get(iid)
        # Each host writes only its own files, so only an own active line is refreshed.
        if mine and mine["status"] == "active" and (
                mine["confidence"] != cand["confidence"] or mine["last_seen"] != cand["last_seen"]):
            _append_line(GLOBAL_DIR, host, _stored_line(
                dict(mine, confidence=cand["confidence"], last_seen=cand["last_seen"]), host))
    # Record pending candidates for `status`. Sorted keys, no timestamps: byte-stable.
    sp = _status_path()
    try:
        status = json.loads(sp.read_text(encoding="utf-8"))
        if not isinstance(status, dict):
            status = {}
    except (OSError, ValueError):
        status = {}
    if pending:
        status["pending_global"] = [{"id": c["id"], "projects": c["projects"],
                                     "conf": round(c["confidence"], 2)} for c in pending]
    else:
        status.pop("pending_global", None)
    if sp.exists() or status:
        _write_if_changed(sp, json.dumps(status, indent=2, sort_keys=True) + "\n")
    return pending


def approve(iid: str) -> tuple[bool, str]:
    """Write the `scope: global` line for a CURRENT candidate; returns (ok, message).

    Not a candidate: (False, "not a promotion candidate") and nothing written.
    Already approved: a no-op success (file untouched).
    """
    if not ID_RE.match(iid or ""):
        return False, "not a promotion candidate"
    if any(l["id"] == iid for l in read_lines(GLOBAL_DIR)):
        return True, f"already approved: {iid}"
    cand = next((c for c in promotion_candidates() if c["id"] == iid), None)
    if cand is None:
        return False, "not a promotion candidate"
    _append_line(GLOBAL_DIR, host_name(), _stored_line(cand, host_name()))
    return True, f"approved global: {iid} conf={cand['confidence']:.2f}"


# --------------------------------------------------------------------------
# Operator commands: show, retire, forget, clusters
# --------------------------------------------------------------------------

def cmd_show(scope_dir: str) -> str:
    """Plain-text table of merged instincts for one project plus the global set."""
    lines = []
    for sd in (scope_dir, GLOBAL_DIR):
        for m in merge_instincts(sd):
            lines.append("%-7s %-7s %.2f  %-8s %-10s %s | %s -> %s" % (
                m["scope"], m["status"], m["confidence"], m["last_seen"], m["domain"],
                m["id"], m["trigger"], m["action"]))
    if not lines:
        return "no instincts"
    return "\n".join(["scope   status  conf  last     domain     id | trigger -> action"] + lines)


def retire(iid: str, scope_dirs: list[str]) -> list[str]:
    """Append a retired line (this host's file) in each scope where iid is active.

    last_seen is the later of this week and the merged line's, so the retired line
    wins the read-time merge. Returns the scopes written (empty = nothing retired).
    """
    done = []
    host = host_name()
    for sd in scope_dirs:
        m = next((x for x in merge_instincts(sd) if x["id"] == iid and x["status"] == "active"), None)
        if m is None:
            continue
        _append_line(sd, host, _stored_line(
            dict(m, status="retired", last_seen=max(current_week(), m["last_seen"])), host))
        done.append(sd)
    return done


def forget(pid: str) -> list[Path]:
    """Delete local observations and THIS host's instinct file for a project; returns paths removed."""
    removed = []
    obs = instincts_state_dir() / pid
    if obs.is_dir():
        shutil.rmtree(obs)
        removed.append(obs)
    mine = store_dir() / pid / f"{host_name()}.jsonl"
    if mine.is_file():
        mine.unlink()
        removed.append(mine)
    return removed


CLUSTER_MIN_SIZE = 3
CLUSTER_MIN_CONF = 0.6
GLOBAL_LIST_CONF = 0.75


def cmd_clusters() -> str:
    """Plain text for Tank: per-project domain clusters (>= 3 active, conf >= 0.6) and strong globals."""
    def fmt(m):
        return "%s: %s: %s (conf %.2f)" % (m["id"], m["trigger"], m["action"], m["confidence"])
    out = []
    for pid in project_dirs():
        by_domain: dict[str, list[dict]] = {}
        for m in merge_instincts(pid):
            if m["status"] == "active" and m["confidence"] >= CLUSTER_MIN_CONF:
                by_domain.setdefault(m["domain"], []).append(m)
        for dom in sorted(by_domain):
            if len(by_domain[dom]) >= CLUSTER_MIN_SIZE:
                out.append(f"cluster: project={pid} domain={dom} size={len(by_domain[dom])}")
                out.extend("- " + fmt(m) for m in by_domain[dom])
    for m in merge_instincts(GLOBAL_DIR):
        if m["status"] == "active" and m["confidence"] >= GLOBAL_LIST_CONF:
            out.append("global: " + fmt(m))
    return "\n".join(out)


# --------------------------------------------------------------------------
# CLI (called by scripts/instincts.sh as `python3 -I lib.py <cmd> ...`)
# --------------------------------------------------------------------------

def main(argv: list[str]) -> int:
    cmd = argv[0] if argv else ""
    if cmd == "project-id" and len(argv) <= 2:
        pid = git_project_id(argv[1] if len(argv) == 2 else ".")
        if pid is None:
            print("instincts: no git remote", file=sys.stderr)
            return 1
        print(pid)
        return 0
    if cmd == "scrub" and len(argv) == 1:
        # Binary-safe-ish: undecodable bytes are replaced rather than crashing.
        data = sys.stdin.buffer.read().decode("utf-8", errors="replace")
        sys.stdout.write(scrub(data))
        return 0
    if cmd in ("promote", "clusters") and len(argv) == 1:
        if cmd == "clusters":
            text = cmd_clusters()
            if text:
                print(text)
            return 0
        for c in promote():
            print(f"pending global: {c['id']} projects={c['projects']} conf={c['confidence']:.2f}")
        return 0
    if cmd == "approve" and len(argv) == 2:
        ok, msg = approve(argv[1])
        print(msg, file=sys.stdout if ok else sys.stderr)
        return 0 if ok else 1
    if cmd == "show" and len(argv) <= 2:
        pid = argv[1] if len(argv) == 2 else git_project_id(".")
        if pid is None or not PROJECT_DIR_RE.match(pid):
            print("instincts: pass a project id (12 hex), or run inside a repo with a git remote",
                  file=sys.stderr)
            return 1
        print(cmd_show(pid))
        return 0
    if cmd == "retire" and len(argv) in (2, 3):
        # Scopes: the named (or current) project, plus the global set.
        pid = argv[2] if len(argv) == 3 else git_project_id(".")
        scopes = ([pid] if pid and PROJECT_DIR_RE.match(pid) else []) + [GLOBAL_DIR]
        if len(argv) == 3 and not scopes[0] == pid:
            print("instincts: bad project id", file=sys.stderr)
            return 1
        done = retire(argv[1], scopes)
        if not done:
            print(f"instincts: no active instinct '{argv[1]}' to retire", file=sys.stderr)
            return 1
        print(f"retired {argv[1]} in: {', '.join(done)}")
        return 0
    if cmd == "forget" and len(argv) in (2, 3) and (len(argv) == 2 or argv[2] == "--yes"):
        if not PROJECT_DIR_RE.match(argv[1]):
            print("instincts: forget needs a project id (12 hex)", file=sys.stderr)
            return 1
        if len(argv) == 2:
            # Destructive: refuse without an explicit --yes, delete nothing.
            print(f"instincts: would delete local observations and this host's instincts "
                  f"for {argv[1]}; re-run with --yes", file=sys.stderr)
            return 1
        for p in forget(argv[1]):
            print(f"deleted {p}")
        return 0
    print("usage: lib.py project-id [DIR] | scrub | promote | approve ID | show [PROJECT] "
          "| retire ID [PROJECT] | forget PROJECT --yes | clusters", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
