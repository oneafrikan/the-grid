#!/usr/bin/env python3
"""instincts core library: the one place the rules live (openspec change `instincts`).

Imported by the capture, analyse and inject code of later groups, and runnable as
a tiny CLI for the shell dispatcher (scripts/instincts.sh):

    python3 -I lib.py project-id [DIR]   print the project id of the repo at DIR (default .)
    python3 -I lib.py scrub              read stdin, write the scrubbed text to stdout

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

import hashlib
import os
import re
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
    print("usage: lib.py project-id [DIR] | scrub", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
