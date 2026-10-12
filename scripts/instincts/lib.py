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
import ipaddress
import json
import os
import re
import shutil
import subprocess
import sys
import unicodedata
import urllib.parse
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
    soft hyphen, tag characters U+E0000..), Cs lone surrogates (they cannot be encoded
    as UTF-8), Zl/Zp line and paragraph separators, plus the variation selectors
    (category Mn, but used to smuggle hidden text).
    """
    if unicodedata.category(ch) in ("Cc", "Cf", "Cs", "Zl", "Zp"):
        return True
    cp = ord(ch)
    return 0xFE00 <= cp <= 0xFE0F or 0xE0100 <= cp <= 0xE01EF


def _strip_hidden(text: str, keep: str = "") -> str:
    """Drop hidden/control characters, except any character listed in `keep`.

    A hidden character that is also whitespace (tab, VT, FF, CR, NEL, U+2028/2029, the
    C0 separators) becomes a space instead of vanishing: deleting it would glue the words
    either side together (`mysql<TAB>-p<TAB>x` -> `mysql-px`), and the secret-flag rules,
    which need whitespace before the flag, would then match nothing.
    """
    out = []
    for c in text:
        if c in keep or not _is_hidden(c):
            out.append(c)
        elif c.isspace():
            out.append(" ")
    return "".join(out)


# Key names whose value is a secret. `auth` must not eat `author(s|ed)`, but must
# still match `authorization`; hence the lookahead. `pass`, `pw` and `pwd` are short,
# so they only count as a whole identifier segment (`DB_PASS`, `pw=`, not `passed`).
_SECRET_KEY = (r"(?:api[_-]?key|access[_-]?key|token|secret|passw(?:or)?d|passphrase"
               r"|pass(?![a-z])|(?<![a-z])pwd?(?![a-z])|auth(?!or(?:s|ed)?\b)"
               r"|credential|private[_-]?key|cookie)")

# One value: a quoted run (to the closing quote, or to the end of the line when the
# quote is never closed, e.g. cut off by truncation) or a bare word. Quoted values
# must be redacted whole: `--password "my pass phrase"` leaks all but the first
# word if only a bare word is taken.
_VALUE = r"""(?P<v>"[^"\n]*"?|'[^'\n]*'?|[^\s'"]+)"""


def _redact_value(m: re.Match) -> str:
    """Keep everything before the value, redact the value, keep its quote style."""
    v = m.group("v")
    q = v[0] if v[0] in "\"'" else ""
    return m.group("pre") + q + REDACTED + q


# Secret-taking flags of commands that take the secret as the NEXT word (`docker login
# -p X`, `mysql -p X`). Only after the named command: `mkdir -p dir` and `psql -p 5432`
# (a port) stay intact. Value: (short flag letters, long flag names).
_PW = ("p", ("password",))
_CMD_FLAGS: dict[str, tuple[str, tuple[str, ...]]] = {
    "login": _PW,                                 # docker/podman/... login, helm registry login
    "mysql": _PW, "mysqldump": _PW, "mysqladmin": _PW, "mysqlpump": _PW, "mariadb": _PW,
    "mongo": _PW, "mongosh": _PW, "mongodump": _PW, "mongorestore": _PW,
    "sshpass": ("p", ()),
    "redis-cli": ("a", ("pass",)),
    "zip": ("P", ()), "unzip": ("P", ()),
    "gpg": ("", ("passphrase",)), "gpg2": ("", ("passphrase",)),
    "curl": ("uUb", ("user", "proxy-user", "oauth2-bearer", "cookie")),
    "ssh-keygen": ("NP", ()),
    "openssl": ("k", ("pass", "passin", "passout")),
}
_CMD_FLAG_RES = {
    cmd: re.compile(
        r"(?P<pre>(?<![\w-])(?:" + "|".join(
            ([f"-[{short}]\\s*"] if short else [])
            + [f"--{re.escape(n)}(?:=|\\s+)" for n in longs]) + r"))" + _VALUE)
    for cmd, (short, longs) in _CMD_FLAGS.items()
}
# A command word, then its argument words up to a shell separator. Separators inside
# quotes do not end the segment (`mysql -p "a;b"`), and a backslash-newline continues it.
_CMD_SEGMENT = re.compile(
    r"(?<![\w-])(?P<cmd>(?:(?:docker|podman|nerdctl|buildah|skopeo|oras)[ \t]+login"
    r"|helm[ \t]+registry[ \t]+login|mysql(?:dump|admin|pump)?|mariadb|mongo(?:sh|dump|restore)?"
    r"|sshpass|redis-cli|u?n?zip|gpg2?|curl|ssh-keygen|openssl|htpasswd))"
    r"(?P<rest>(?:[ \t](?:\\\n|\"[^\"\n]*\"|'[^'\n]*'|[^\n;&|\"'])*)?)")


def _scrub_command_segment(m: re.Match) -> str:
    full = m.group("cmd").lower()
    cmd = "login" if full.endswith("login") else full
    rest = m.group("rest")
    if cmd == "htpasswd":
        # `-b` puts the password on the command line as the LAST non-flag word
        # (`htpasswd -b file user PASS`, `htpasswd -nb user PASS`).
        if re.search(r"(?<![\w-])-[A-Za-z]*b", rest):
            words = [w for w in re.finditer(r"""(?:"[^"]*"|'[^']*'|\S)+""", rest)
                     if not w.group(0).startswith("-")]
            if words:
                w = words[-1]
                rest = rest[:w.start()] + REDACTED + rest[w.end():]
    else:
        rx = _CMD_FLAG_RES.get(cmd)
        if rx:
            rest = rx.sub(_redact_value, rest)
    return m.group("cmd") + rest


# Each rule is (compiled regex, replacement or callable). Applied in order, so the
# specific shapes run before the generic key=value and high-entropy catch-alls. Where a
# rule has a recognisable prefix (a key, a flag, a URL scheme) the prefix is kept
# and only the secret part is replaced, so the redacted text stays readable.
# Every pattern must stay linear on adversarial input: no unbounded run in front of a
# literal that is usually absent (the scheme rules anchor on a lookbehind for that).
_SCRUB_RULES: list[tuple[re.Pattern, object]] = [
    # PEM block: header through the END line, or to the end of the text if cut off.
    (re.compile(r"-----BEGIN [A-Z0-9 ]+-----[\s\S]*?(?:-----END [A-Z0-9 ]+-----|\Z)"), REDACTED),
    # JWT: header.payload.signature, header and payload base64url of `{"`.
    (re.compile(r"eyJ[A-Za-z0-9_-]+\.eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]*"), REDACTED),
    # Authorization header (any scheme); keeps the header name.
    (re.compile(r"(?i)(\bAuthorization\s*[:=]\s*)(?:(?:Bearer|Basic|Token)\s+)?[^\s'\"]+"),
     r"\1" + REDACTED),
    # Bare `Bearer <credential>`.
    (re.compile(r"(?i)(\bBearer\s+)[A-Za-z0-9._~+/=-]{8,}"), r"\1" + REDACTED),
    # Cookie headers hold `a=b; c=d`: redact to the end of the line or the closing quote.
    (re.compile(r"(?i)((?:set-)?cookie['\"]?\s*[:=]\s*)[^\n'\"]+"), r"\1" + REDACTED),
    # URL userinfo for ANY scheme (https, postgres, redis, ...); keeps scheme and host.
    # It ends at the last `@` of the authority, so a password holding `@` goes too.
    (re.compile(r"(?<![a-z0-9+.-])([a-z][a-z0-9+.-]*://)[^/\s:@]*:[^/\s]*@", re.I),
     r"\1" + REDACTED + "@"),
    # Userinfo with no colon is a token (`https://TOKEN@host`): 16+ chars of one class.
    (re.compile(r"(?<![a-z0-9+.-])([a-z][a-z0-9+.-]*://)[A-Za-z0-9_-]{16,}@", re.I),
     r"\1" + REDACTED + "@"),
    # Known token shapes, anchored so `task-...` cannot trip `sk-`.
    (re.compile(
        r"(?<![A-Za-z0-9])(?:"
        r"gh[pousr]_[A-Za-z0-9]{20,}"            # GitHub classic tokens (ghp_ gho_ ghu_ ghs_ ghr_)
        r"|github_pat_[A-Za-z0-9_]{20,}"         # GitHub fine-grained
        r"|sk-[A-Za-z0-9_-]{16,}"                # API keys incl. sk-ant-
        r"|[sr]k_(?:live|test)_[A-Za-z0-9]{10,}"  # Stripe keys (sk_live_, rk_live_, sk_test_, rk_test_)
        r"|whsec_[A-Za-z0-9+/=]{16,}"            # Stripe webhook secret
        r"|glpat-[A-Za-z0-9_-]{16,}"             # GitLab PAT
        r"|glsa_[A-Za-z0-9_]{16,}"               # Grafana service account
        r"|npm_[A-Za-z0-9]{20,}"                 # npm token
        r"|pypi-[A-Za-z0-9_-]{20,}"              # PyPI upload token
        r"|xox[abprse]-[A-Za-z0-9-]{10,}"        # Slack
        r"|xapp-[A-Za-z0-9-]{10,}"               # Slack app-level
        r"|(?:AKIA|ASIA)[0-9A-Z]{16}"            # AWS access key id / temporary key id
        r"|AIza[0-9A-Za-z_-]{35}"                # Google API key
        r"|ya29\.[A-Za-z0-9_-]{20,}"             # Google OAuth access token
        r"|hf_[A-Za-z0-9]{20,}"                  # Hugging Face
        r"|SG\.[A-Za-z0-9_-]{16,}\.[A-Za-z0-9_-]{16,}"   # SendGrid
        r"|shp(?:at|ss|ca|pa)_[A-Za-z0-9]{16,}"  # Shopify
        r"|dop_v1_[A-Za-z0-9]{20,}"              # DigitalOcean
        r")"), REDACTED),
    # openssl `-passin pass:X`, `-passout pass:X`, `-pass pass:X`. Runs BEFORE the attached
    # `-p` rule below, which would otherwise eat `-passin` and leave `pass:X` in the clear.
    (re.compile(r"(?i)(?<![A-Za-z0-9])(pass(?:in|out)?:)\S+"), r"\1" + REDACTED),
    # The same inside a quoted word (`-pass "pass:two words"`): redact to the closing quote.
    (re.compile(r"(?i)(?<=[\"'])(pass(?:in|out)?:)[^\"'\n]*"), r"\1" + REDACTED),
    # `-passin file:PATH` / `env:VAR` name where a secret lives; redacted with the rest.
    (re.compile(r"(?i)((?<![\w-])-pass(?:in|out)?\s+(?:file|env|fd):)\S+"), r"\1" + REDACTED),
    # Space-form secret flags after a known command (docker login -p X, mysql -p X, ...).
    (_CMD_SEGMENT, _scrub_command_segment),
    # Credential flags with a value: `--password x`, `--token=x`, also prefixed
    # (`--http-password x`). `--password-stdin` and `--with-token` style flags carry no
    # value, so they stay out: a name must be followed by `=` or whitespace.
    (re.compile(
        r"(?i)(?P<pre>(?<![A-Za-z0-9-])--?(?:(?!(?:with|no|skip|ask|prompt|use|stdin)-)[a-z0-9]+-){0,3}"
        r"(?:password|passwd|passphrase|pass|pw|token|secret|api-?key|access-?key|auth-?token)(?:=|\s+))"
        + _VALUE), _redact_value),
    # `-pSECRET` (mysql style). Attached form only: `-p dir` (mkdir -p dir) and
    # `-p no:cache` (pytest) must be left alone. Cost accepted: `docker -p8080:80`.
    # `-pass`/`-passin`/`-passout` (openssl) are not attached secrets.
    (re.compile(r"((?<=\s)-p)(?!ass(?:in|out)?(?:\s|=|$))\S+"), r"\1" + REDACTED),
    (re.compile(r"((?<![A-Za-z0-9-])-u\s+)\S+:\S+"), r"\1" + REDACTED),
    # key=value / key: value where the KEY names a secret; also JSON `"key": "v"`.
    # No leading `[\w.-]*`: the prefix is kept anyway, and that unbounded leading run made
    # this rule quadratic (64 KB of `a.a.a.` took minutes). The trailing run is capped.
    (re.compile(r"(?i)(?P<pre>" + _SECRET_KEY + r"[\w.-]{0,64}['\"]?\s*[:=]\s*)" + _VALUE),
     _redact_value),
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


def _apply_rules(text: str) -> str:
    for rx, repl in _SCRUB_RULES:
        text = rx.sub(repl, text)
    return text


def scrub(text: str) -> str:
    """Redact secrets from text and strip hidden unicode / control characters.

    Hidden characters go first so zero-width junk cannot split a token, then NFKC
    folds fullwidth and compatibility forms onto the ASCII the rules expect. A secret
    hidden behind URL-encoding (`password%3Dhunter2`) is found on a decoded copy;
    when that copy matches, the decoded, redacted text is returned. Newlines and tabs
    are kept (multi-line commands stay readable; sanitize() flattens them where one
    line is required). Idempotent.
    """
    out = unicodedata.normalize("NFKC", _strip_hidden(text, keep="\n\t"))
    out = _apply_rules(out)
    if "%" in out:
        decoded = urllib.parse.unquote(out)
        if decoded != out:
            redacted = _apply_rules(decoded)
            if redacted != decoded:
                out = redacted
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
# Whole-line drops for free text (D40): redaction leaks the shape of a secret, so a
# line that holds one is removed instead. Used on prompts and commands at capture
# and on the analyser digest.
# --------------------------------------------------------------------------

# A secret keyword. `pw`/`pwd`/`pass` are short words (`pwd` is also a command), so
# they only count in assignment or "is" position.
_DROP_KEYWORD = re.compile(
    r"password|passwd|passphrase|secret|token|credential"
    r"|(?<![a-z])(?:pw|pwd|pass)(?=\s*[:=]|\s+is\b)"
    r"|(?:api|access|private)[ _-]?key", re.I)
_MIXED_WORD = re.compile(r"[A-Za-z]\w*\d|\d\w*[A-Za-z]")
_LONG_RUN = re.compile(r"[A-Za-z0-9_-]{20,}")
# Every start is anchored with a lookbehind so a long run of one class is scanned once.
_EMAIL = re.compile(r"(?<![A-Za-z0-9._%+-])[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+")
# What may follow the colon: a path, `~`, a word, or what the path rewrites leave behind
# (`(outside)/x` from outside_paths, `./x` from the project-root rewrite). Those rewrites run
# BEFORE this check, so `user@host:/tmp` arrives here as `user@host:(outside)/tmp`.
_SCP_HOST = re.compile(r"(?<![\w.+-])[\w.+-]+@[\w-]+:[/~\w(.]")
# TLDs worth a drop. Left out on purpose because they are file extensions too:
# py sh md rs pl so cc zip mov pm in (README.md, lib.py, requirements.in).
_TLDS = ("com|net|org|io|dev|app|co|uk|de|fr|nl|eu|us|ai|cloud|info|biz|edu|gov|mil|int|me|tv|xyz|"
         "online|site|tech|store|internal|local|lan|corp|intranet|home|localdomain|test|example|"
         "invalid|ca|au|jp|cn|ru|br|ch|se|no|fi|es|it|at|be|cz|dk|ie|nz|za|mx|gg|im|ly")
# `settings.local.json` must survive: a TLD followed by `.word` is a file name.
_FQDN = re.compile(r"(?<![\w.-])(?:[a-z0-9-]+\.)+(?:" + _TLDS + r")(?![\w-]|\.\w)", re.I)
_IPV4 = re.compile(r"(?<![\w.])(?:\d{1,3}\.){3}\d{1,3}(?!\w|\.\d)")
_IPV6 = re.compile(r"(?<![\w:.])[0-9A-Fa-f:]{6,39}(?![\w:])")
_SSN = re.compile(r"(?<!\d)\d{3}-\d{2}-\d{4}(?!\d)")
_CARD = re.compile(r"(?<![\d-])(?:\d[ -]?){12,18}\d(?!\d)")


# An absolute path that survived the root/HOME rewrite lies outside both. It is kept as
# `(outside)/<last component>`: the habit ("cat /etc/x") is data, the directory layout and
# user names are not. The lookbehind skips URL paths (`https://h/a`), `~/x`, `./x`, `a/b`
# and an already rewritten `(outside)/x`.
_ABS_PATH = re.compile(r"(?<![\w.~$/)@%+-])/(?=[\w.])[^\s'\"`;|&<>()=:]*")


def outside_paths(text: str) -> str:
    """Rewrite every absolute path in text to `(outside)/<last component>` (idempotent)."""
    return _ABS_PATH.sub(lambda m: "(outside)/" + m.group(0).rstrip("/").rsplit("/", 1)[-1], text)


def _luhn(digits: str) -> bool:
    total = 0
    for i, ch in enumerate(reversed(digits)):
        d = int(ch)
        if i % 2:
            d = d * 2 - 9 if d > 4 else d * 2
        total += d
    return total % 10 == 0


def _line_is_sensitive(line: str) -> bool:
    kws = list(_DROP_KEYWORD.finditer(line))
    if kws:
        # A keyword with a value after it ("my password is X", `TOKEN=x`), or with a
        # digit-bearing word anywhere ("hunter2 is the password").
        if any(re.search(r"\w", line[m.end():]) for m in kws) or _MIXED_WORD.search(line):
            return True
    for m in _LONG_RUN.finditer(line):
        run = m.group(0)
        if any(c.isalpha() for c in run) and any(c.isdigit() for c in run):
            return True
    if _EMAIL.search(line) or _SCP_HOST.search(line) or _FQDN.search(line) or _SSN.search(line):
        return True
    for m in _IPV4.finditer(line):
        if all(int(o) <= 255 for o in m.group(0).split(".")):
            return True
    for m in _IPV6.finditer(line):
        if m.group(0).count(":") >= 2:
            try:
                ipaddress.IPv6Address(m.group(0))
                return True
            except ValueError:
                pass
    for m in _CARD.finditer(line):
        digits = re.sub(r"\D", "", m.group(0))
        if 13 <= len(digits) <= 19 and _luhn(digits):
            return True
    return False


def drop_sensitive_lines(text: str) -> str:
    """Remove every line that holds a secret keyword with a value, a long digit-bearing
    run, an email, FQDN, IP, SSN or card number. Returns what is left ("" = nothing:
    the caller then records no observation).

    The text is NFKC-normalised and stripped of hidden characters first, so a fullwidth or
    zero-width-split keyword (`ｐａｓｓｗｏｒｄ`, `pass<ZWSP>word`) cannot slip past the keyword rules.
    """
    text = unicodedata.normalize("NFKC", _strip_hidden(text, keep="\n"))
    return "\n".join(ln for ln in text.splitlines() if not _line_is_sensitive(ln))


def prune_old_obs(directory: str | os.PathLike, now, days: int = 28) -> None:
    """Delete `obs-<YYYY>-W<ww>.jsonl` files whose ISO week ended more than `days` before `now`.

    Called whenever a new week file is created and after an analysis, so retention
    does not depend on the analyser running. A missing directory, an unremovable file
    or an impossible week name is ignored.
    """
    today = now.date() if isinstance(now, datetime.datetime) else now
    cutoff = today - datetime.timedelta(days=days)
    try:
        files = list(Path(directory).glob("obs-*.jsonl"))
    except OSError:
        return
    for f in files:
        m = re.fullmatch(r"obs-(\d{4})-W(\d{2})\.jsonl", f.name)
        if not m:
            continue
        try:
            end = datetime.date.fromisocalendar(int(m.group(1)), int(m.group(2)), 7)
        except ValueError:
            continue
        if end < cutoff:
            try:
                f.unlink()
            except OSError:
                pass


# --------------------------------------------------------------------------
# Opt-in, host, paths
# --------------------------------------------------------------------------

# The opt-in flag is parsed by ONE stdlib scanner, used by both the capture side
# (`learning_enabled`) and the emitter (agent-factory/deploy_hooks.py), because capture
# cannot import PyYAML. Rules: a top-level `learning:` line (no indent, optionally
# quoted key), TAB or spaces after the colon, LAST one wins (so a trailing
# `learning: off` stops capture), one pair of quotes and a trailing ` # comment`
# allowed, true only for `on` or `true` in any case. Bare `yes` is off.
_LEARNING_LINE = re.compile(r"""^["']?learning["']?:(?:[ \t]+(?P<v>.*))?$""")


def read_learning_flag(text: str) -> bool:
    """True when the project.yaml text switches `learning` on (see the rules above)."""
    value = ""
    for line in text.lstrip("﻿").splitlines():
        m = _LEARNING_LINE.match(line)
        if not m:
            continue
        v = (m.group("v") or "").strip()
        if v[:1] in ("'", '"'):
            close = v.find(v[0], 1)
            rest = v[close + 1:].strip() if close > 0 else "x"      # unclosed quote: invalid
            value = v[1:close] if close > 0 and (not rest or rest.startswith("#")) else ""
        else:
            value = re.split(r"\s+#", v, maxsplit=1)[0].strip()
    return value.lower() in ("on", "true")


def marker_dir() -> Path:
    """Machine-local opt-in markers: <state>/instincts/enabled/<project-id>."""
    return instincts_state_dir() / "enabled"


def marker_path(pid: str) -> Path:
    """Marker file of one project; the id is validated so it can never name another path."""
    if not isinstance(pid, str) or not PROJECT_DIR_RE.fullmatch(pid):
        raise ValueError(f"bad project id: {pid!r}")
    return marker_dir() / pid


MAX_MARKER_ROOTS = 8       # checkouts of one project the marker remembers


def _valid_root(r: object) -> bool:
    """A marker root must be an absolute path with no control or line-separator character.

    The marker is one root per line, so a checkout directory whose NAME holds a newline would
    write a second, attacker-chosen line that reads back as another authorised root; a relative
    line would depend on the reader's cwd.
    """
    return (isinstance(r, str) and os.path.isabs(r)
            and not any(unicodedata.category(c) in ("Cc", "Zl", "Zp") for c in r))


def marker_roots(pid: str) -> list[str] | None:
    """The checkout roots recorded in the marker (one per line), or None when there is no marker.

    Lines that are not a valid root (relative, empty, holding control characters) are ignored.
    Split on "\n" only: splitlines() would also cut at VT, FF, U+2028 and friends.
    """
    try:
        text = marker_path(pid).read_text(encoding="utf-8", errors="replace")[:8192]
    except (OSError, ValueError):
        return None
    return [ln for ln in text.split("\n") if _valid_root(ln)]


def _store_marker(pid: str, roots: list[str]) -> Path:
    path = marker_path(pid)
    path.parent.mkdir(parents=True, exist_ok=True)
    for d in (instincts_state_dir(), path.parent):
        os.chmod(d, 0o700)
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        fh.write("".join(r + "\n" for r in roots))
    os.chmod(path, 0o600)
    return path


def write_marker(pid: str, root: str | os.PathLike) -> Path:
    """Record `root` in the project's marker (file 0600, dirs 0700; one checkout root per line).

    The marker is what makes the repo flag count: a cloned repo can ship `learning: on` and hook
    config, but it cannot create a file in this machine-local state dir, so only the emitter run
    by the operator turns capture on (design D44). The marker names the CHECKOUT, not just the
    project id: another clone that claims the same remote URL records nothing until the emitter is
    run there too. The analyser re-reads each recorded root to see whether the flag is still on.
    """
    r = os.path.realpath(str(root))
    if not _valid_root(r):
        raise ValueError("checkout path has a newline or control character; no marker written")
    roots = [x for x in (marker_roots(pid) or []) if x != r] + [r]
    return _store_marker(pid, roots[-MAX_MARKER_ROOTS:])


def remove_marker(pid: str, root: str | os.PathLike | None = None) -> None:
    """Forget one checkout (`root`) or, with no root, the whole marker; idempotent."""
    if root is not None:
        r = os.path.realpath(str(root))
        keep = [x for x in (marker_roots(pid) or []) if x != r]
        if keep:
            _store_marker(pid, keep)
            return
    try:
        marker_path(pid).unlink()
    except FileNotFoundError:
        pass


def learning_enabled(project_root: str | os.PathLike | None, pid: str | None = None) -> bool:
    """True when capture/inject may run for this project.

    All three must hold: GRID_INSTINCTS != 0, `<root>/.grid/project.yaml` switches
    `learning` on (read_learning_flag), and the machine-local marker for the project
    id lists THIS checkout (write_marker, created by the emitter). `pid` may be passed
    to save a git call.
    """
    if os.environ.get("GRID_INSTINCTS") == "0" or not project_root:
        return False
    try:
        text = (Path(project_root) / ".grid" / "project.yaml").read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError):
        return False
    if not read_learning_flag(text):
        return False
    pid = pid or git_project_id(str(project_root))
    if not pid:
        return False
    try:
        roots = marker_roots(pid)
    except (ValueError, OSError):       # RepoPathError is a ValueError
        return False
    return roots is not None and os.path.realpath(str(project_root)) in roots


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
# `pending`: written by the analyser for a new project instinct and never injected until
# the operator runs `instincts.sh approve ID` (design D43: a human gate before a habit reaches a session).
STATUSES = frozenset(["active", "pending", "retired"])
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
    # frame and role forgery: text that imitates the injection block or a chat turn
    r"\b(?:system|assistant|human|user)\s*:", r"</?system>", r"</?the-grid-hints>",
    r"the-grid habit hints", r"end of hints", r"(?:^|\s)#+\s*(?:system|assistant|human|user)\b",
    # a bare domain with a path is a download by another name (no `curl` needed)
    r"\b[\w-]+\.[a-z]{2,}/\S+",
    # habits that weaken the controls a human put in place (WP-030): approving unread,
    # permissions and sandbox, shell wrappers and download-and-run, environment dumps,
    # history rewriting, and treating tool output as an authority
    r"\b(?:approv|accept|merge|trust|apply|run)\w*\b.{0,40}\bwithout\s+(?:read|review|check|look|inspect)\w*",
    r"\b(?:permissions?|allow\s*rules?|allowlist|sandbox|auto-?approv\w*|approval\s+prompts?|dangerously|bypass\w*)\b",
    r"\b(?:printenv|environment\s+variables?)\b|\bprint\w*\b.{0,20}\benv\w*",
    r"\b(?:bash|sh|zsh)\s+-c\b|\bxargs\b|\bsubshell\b",
    r"\b(?:download|fetch|grab|install)\w*\b.{0,40}\b(?:and|then)\s+(?:run|execute|pipe|source)\w*",
    r"\brewrit\w*\b.{0,20}\bhistory\b|filter-branch",
    r"\b(?:follow|obey|trust|treat|execute)\w*\b.{0,30}\b(?:tool|command|file|web|page)\s+(?:output|result|content)s?\b",
]
UNSAFE_RE = re.compile("|".join(f"(?:{a})" for a in _UNSAFE_ALTERNATIVES), re.I)


def _clean_text(value, cap: int) -> str | None:
    """A trigger/action: str, no backtick/fence, <= cap chars once cleaned, not UNSAFE."""
    if not isinstance(value, str) or "`" in value:       # rejected, not stripped: a fence is hostile
        return None
    # NFKC folds fullwidth/compatibility lookalikes (`ｃｕｒｌ`) onto ASCII so the denylist sees them.
    # What NFKC cannot fold (Greek or Cyrillic lookalikes) is refused outright: a confusables table is
    # never complete. Cost: habit text must be plain ASCII letters (non-English habits are refused).
    cleaned = sanitize(unicodedata.normalize("NFKC", value))     # newlines, control and hidden chars out
    # Letters AND combining marks: a mark wedged inside `ignore` would split the word past the
    # denylist while still reading as the word.
    if any(ord(c) > 127 and (c.isalpha() or unicodedata.category(c).startswith("M")) for c in cleaned):
        return None
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
    if not isinstance(i, str) or not ID_RE.fullmatch(i):
        return None
    out["id"] = i
    trigger = _clean_text(obj.get("trigger"), MAX_TRIGGER)
    action = _clean_text(obj.get("action"), MAX_ACTION)
    if trigger is None or action is None or not isinstance(obj.get("domain"), str) \
            or obj["domain"] not in DOMAINS:
        return None
    out.update(trigger=trigger, action=action, domain=obj["domain"])

    # Enum-valued optionals.
    for key, allowed in (("kind", KINDS), ("scope", SCOPES), ("status", STATUSES)):
        if key in obj:
            if not isinstance(obj[key], str) or obj[key] not in allowed:
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
    for key in ("first_seen", "last_seen", "last_decay_week", "last_contradict_week"):
        if key in obj:
            if not (isinstance(obj[key], str) and WEEK_RE.fullmatch(obj[key])):
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
                          "weeks_seen", "first_seen", "last_seen", "misses", "status", "host",
                          "last_decay_week", "last_contradict_week"])
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
    return name == GLOBAL_DIR or bool(PROJECT_DIR_RE.fullmatch(name))


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
            except (ValueError, RecursionError):
                continue
            if not isinstance(obj, dict) or not set(obj) <= _STORED_KEYS \
                    or any(k not in obj for k in _STORED_REQUIRED):
                continue
            try:
                v = validate_instinct(obj)
            except (TypeError, ValueError):
                continue
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
    last_seen (text fields come from the newest active line; pending lines never contribute
    to an id that has an active line). The id is `retired`
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
        # Lines that still count for the id. Once ANY host holds an approved (active) line, only
        # active lines count: an unreviewed pending line (a stale store, an id collision, a tampered
        # synced line) must not supply text, confidence or dates for an approved instinct, nor
        # outlive a retire. Without an active line the pending ones stand (shown as pending).
        live = active or [l for l in lines if l["status"] == "pending"]
        retired = [l for l in lines if l["status"] == "retired"]
        newest_live = max(live, key=_line_order) if live else None
        if retired and (newest_live is None
                        or max(r["last_seen"] for r in retired) >= newest_live["last_seen"]):
            m = dict(max(retired, key=_line_order), status="retired")
        else:
            # `active` when an approval exists (live is then active lines only), else `pending`.
            m = dict(newest_live, status="active" if active else "pending")
            m["confidence"] = max(l["confidence"] for l in live)
            firsts = [l["first_seen"] for l in live if "first_seen" in l]
            if firsts:
                m["first_seen"] = min(firsts)
            weeks = [l["weeks_seen"] for l in live if "weeks_seen" in l]
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
    return sorted(p.name for p in d.iterdir() if p.is_dir() and PROJECT_DIR_RE.fullmatch(p.name))


# --------------------------------------------------------------------------
# Promotion (design: Promotion; Q4 = a global line needs an explicit `approve`)
# --------------------------------------------------------------------------

PROMOTE_MIN_CONF = 0.5
PROMOTE_MIN_PROJECTS = 2

# Key order of a written line, as in the design's example (stable, diff-friendly).
_LINE_KEY_ORDER = ("id", "trigger", "action", "domain", "scope", "project", "confidence",
                   "weeks_seen", "first_seen", "last_seen", "misses", "status", "host", "last_decay_week",
                   "last_contradict_week")


def _stored_line(m: dict, host: str) -> dict:
    """The line to write for merged/candidate instinct m: stored keys only, host set."""
    line = dict(m, host=host)
    return {k: line[k] for k in _LINE_KEY_ORDER if k in line}


def _append_line(scope_dir: str, host: str, line: dict) -> None:
    """Append one JSON line to <store>/<scope_dir>/<host>.jsonl (creating it)."""
    path = store_dir() / scope_dir / f"{host}.jsonl"
    path.parent.mkdir(parents=True, exist_ok=True)
    os.chmod(path.parent, 0o700)             # private data: not world-readable whatever the umask
    fd = os.open(path, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600)
    with os.fdopen(fd, "a", encoding="utf-8") as fh:
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


def approve_pending(pid: str, iid: str) -> tuple[bool, str] | None:
    """Approve a PENDING instinct of project `pid`: append an active line to this host's file.

    None when the id is not pending in that project (the caller then tries the global promotion
    path). Approving twice is a no-op success (the merged status is already active).
    """
    if not ID_RE.fullmatch(iid or ""):
        return None
    m = next((x for x in merge_instincts(pid) if x["id"] == iid), None)
    if m is None or m["status"] == "retired":
        return None
    if m["status"] == "active":
        return True, f"already approved: {iid}"
    _append_line(pid, host_name(), _stored_line(dict(m, status="active"), host_name()))
    return True, f"approved: {iid} (project {pid}) conf={m['confidence']:.2f}"


def approve(iid: str) -> tuple[bool, str]:
    """Write the `scope: global` line for a CURRENT candidate; returns (ok, message).

    Not a candidate: (False, "not a promotion candidate") and nothing written.
    Already approved: a no-op success (file untouched).
    """
    if not ID_RE.fullmatch(iid or ""):
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
    """Delete what this machine derived for a project; returns paths removed.

    Local observations, THIS host's instinct file, `META.json` once no host file remains, the
    project's entry in status.json and its opt-in marker. Other hosts' files, derived `_global`
    lines and git history are NOT touched (the CLI says so).
    """
    removed = []
    obs = instincts_state_dir() / pid
    if obs.is_dir():
        shutil.rmtree(obs)
        removed.append(obs)
    mine = store_dir() / pid / f"{host_name()}.jsonl"
    if mine.is_file():
        mine.unlink()
        removed.append(mine)
    store_pid = store_dir() / pid
    meta = store_pid / "META.json"
    if meta.is_file() and not list(store_pid.glob("*.jsonl")):
        meta.unlink()
        removed.append(meta)
    sp = _status_path()
    try:
        status = json.loads(sp.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        status = None
    if isinstance(status, dict) and isinstance(status.get("projects"), dict) and pid in status["projects"]:
        del status["projects"][pid]
        _write_if_changed(sp, json.dumps(status, indent=2, sort_keys=True) + "\n")
        removed.append(sp)
    marker = marker_path(pid)
    if marker.is_file():
        remove_marker(pid)
        removed.append(marker)
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

MAX_SCRUB_INPUT = 64 * 1024     # bytes the `scrub` CLI reads


def main(argv: list[str]) -> int:
    """CLI entry: a data path inside the repo, or a file the store cannot write, is a one-line
    error, never a traceback."""
    try:
        return _main(argv)
    except RepoPathError as e:
        print(f"instincts: {e}", file=sys.stderr)
        return 1
    except OSError as e:
        print(f"instincts: {e.strerror or type(e).__name__}: {e.filename or ''}".rstrip(": "), file=sys.stderr)
        return 1


def _main(argv: list[str]) -> int:
    cmd = argv[0] if argv else ""
    if cmd == "project-id" and len(argv) <= 2:
        pid = git_project_id(argv[1] if len(argv) == 2 else ".")
        if pid is None:
            print("instincts: no git remote", file=sys.stderr)
            return 1
        print(pid)
        return 0
    if cmd == "scrub" and len(argv) == 1:
        # Binary-safe-ish: undecodable bytes are replaced rather than crashing. Input is
        # bounded (a capture line is a few hundred characters) so a huge pipe cannot run for minutes.
        raw = sys.stdin.buffer.read(MAX_SCRUB_INPUT + 1)
        if len(raw) > MAX_SCRUB_INPUT:
            raw = raw[:MAX_SCRUB_INPUT]
            print(f"instincts: scrub input truncated to {MAX_SCRUB_INPUT} bytes", file=sys.stderr)
        sys.stdout.write(scrub(raw.decode("utf-8", errors="replace")))
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
        # A pending instinct of the current project is approved first; otherwise today's
        # global promotion path.
        here = git_project_id(".")
        pend = approve_pending(here, argv[1]) if here else None
        if pend is not None:
            print(pend[1])
            return 0
        ok, msg = approve(argv[1])
        print(msg, file=sys.stdout if ok else sys.stderr)
        return 0 if ok else 1
    if cmd == "show" and len(argv) <= 2:
        pid = argv[1] if len(argv) == 2 else git_project_id(".")
        if pid is None or not PROJECT_DIR_RE.fullmatch(pid):
            print("instincts: pass a project id (12 hex), or run inside a repo with a git remote",
                  file=sys.stderr)
            return 1
        print(cmd_show(pid))
        return 0
    if cmd == "retire" and 2 <= len(argv) <= 4:
        # Scopes: the named (or current) project only. The GLOBAL instinct (every project's) needs --global.
        args = [a for a in argv[1:] if a != "--global"]
        want_global = len(args) != len(argv) - 1
        if not 1 <= len(args) <= 2:
            print("instincts: usage: retire ID [PROJECT] [--global]", file=sys.stderr)
            return 2
        iid = args[0]
        pid = args[1] if len(args) == 2 else git_project_id(".")
        if len(args) == 2 and not (pid and PROJECT_DIR_RE.fullmatch(pid)):
            print("instincts: bad project id", file=sys.stderr)
            return 1
        scopes = ([pid] if pid and PROJECT_DIR_RE.fullmatch(pid) else []) + ([GLOBAL_DIR] if want_global else [])
        done = retire(iid, scopes)
        if not done:
            shown = sanitize(iid, 60)
            hint = ""
            if not want_global and any(x["id"] == iid and x["status"] == "active" for x in merge_instincts(GLOBAL_DIR)):
                hint = " (it is active as a GLOBAL instinct for every project: add --global to retire that)"
            print(f"instincts: no active instinct '{shown}' to retire{hint}", file=sys.stderr)
            return 1
        print(f"retired {sanitize(iid, 60)} in: {', '.join(done)}")
        return 0
    if cmd == "forget" and len(argv) in (2, 3) and (len(argv) == 2 or argv[2] == "--yes"):
        if not PROJECT_DIR_RE.fullmatch(argv[1]):
            print("instincts: forget needs a project id (12 hex)", file=sys.stderr)
            return 1
        if len(argv) == 2:
            # Destructive: refuse without an explicit --yes, delete nothing.
            print(f"instincts: would delete local observations and this host's instincts "
                  f"for {argv[1]}; re-run with --yes", file=sys.stderr)
            return 1
        for p in forget(argv[1]):
            print(f"deleted {p}")
        print("note: capture stays off until the emitter is re-run; set `learning: off` in the project's "
              ".grid/project.yaml to keep it off. Not removed: git history of the private repo, other "
              "hosts' files and derived _global lines (purge them by hand).")
        return 0
    print("usage: lib.py project-id [DIR] | scrub | promote | approve ID | show [PROJECT] "
          "| retire ID [PROJECT] [--global] | forget PROJECT --yes | clusters", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
