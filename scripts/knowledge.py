#!/usr/bin/env python3
"""knowledge.py - helpers for knowledge signals and entries (change `knowledge-signals`).

Sections (added as the change lands, in this order):
    1. Vocabulary   stage names and their rank
    2. Claim hash   claim_hash, entry_id, slug
    3. Warrant      is_warranted, ceiling
    4. Signal       KnowledgeError, parse_frontmatter, parse_signal, SIGNAL_NAME_RE, filer_slug
    5. Entry        parse_entry, render_entry, ENTRY_NAME_RE

Design rules:
  * Python 3 standard library only, valid on 3.8 (no `X | Y` annotations, no
    `str.removeprefix`).
  * Pure functions: no file access, no git, no clock. Same input, same output on every
    machine.
  * Error text never echoes claim or warrant text (those may carry hostile content).
  * Sorting, where it appears, is plain code-point order.
"""
import datetime
import hashlib
import re
import unicodedata

# --- 1. vocabulary -----------------------------------------------------------------
# Stages a signal may claim, lowest to highest.
STAGES_SIGNAL = ("wip", "provisional", "established", "canonical")
# Stages an entry may sit in: the signal stages plus the two terminal ones, which only a
# human sets.
STAGES_ENTRY = STAGES_SIGNAL + ("superseded", "retired")
# Rank of the claimable stages, for "highest claimed stage" comparisons.
STAGE_RANK = {name: rank for rank, name in enumerate(STAGES_SIGNAL)}

# --- 2. claim hash -----------------------------------------------------------------


def claim_hash(claim):
    """First 16 hex of SHA-256 over the normalised claim.

    Normalisation: NFKC, casefold, whitespace runs collapsed to one space, trimmed. So a
    claim differing only in case, spacing or compatibility forms keeps its identity, while
    any wording change makes a new hash (rejection memory is by exact claim, not meaning).
    """
    text = unicodedata.normalize("NFKC", claim).casefold()
    # str.split() with no argument splits on every Unicode whitespace run and drops the
    # ends, which is the collapse-and-trim in one step.
    text = " ".join(text.split())
    return hashlib.sha256(text.encode("utf-8")).hexdigest()[:16]


def entry_id(claim):
    """Entry address `K-` plus the first 8 hex of the claim hash."""
    return "K-" + claim_hash(claim)[:8]


def slug(text, maxlen=40):
    """Lower-case ASCII slug: runs of anything outside [a-z0-9] become one `-`.

    The cut is made before the final trim so a cut that lands on a `-` leaves no
    trailing one.
    """
    out = re.sub(r"[^a-z0-9]+", "-", text.lower()).strip("-")
    return out[:maxlen].strip("-")


# --- 3. warrant --------------------------------------------------------------------
# Placeholder warrants that count as "no warrant". The sweep checks presence, not quality.
_UNWARRANTED = frozenset(("none", "n/a", "na", "untested", "unknown", "tbd", "?"))


def is_warranted(warrant):
    """True when the warrant is non-empty after trimming and not a placeholder."""
    text = warrant.strip()
    return bool(text) and text.casefold() not in _UNWARRANTED


def ceiling(evidence):
    """Highest stage the evidence supports.

    `evidence` is a list of dicts with `filed_by` and `warrant`. Distinct filers with a
    warranted line: 0 -> wip, 1 -> provisional, 2 or more -> established. Counting
    distinct filers (not lines) stops one agent confirming itself.
    """
    filers = {e["filed_by"] for e in evidence if is_warranted(e["warrant"])}
    return STAGES_SIGNAL[min(len(filers), 2)]


# --- 4. signal format --------------------------------------------------------------
# Error codes: E_SIGNAL is any malformed signal; E_STAGE is a stage name nobody knows.
E_SIGNAL = "E_SIGNAL"
E_STAGE = "E_STAGE"


class KnowledgeError(ValueError):
    """A signal broke the format. `.code` is stable; the message names the key and the
    limit but never echoes claim or warrant text, which may be hostile."""

    def __init__(self, code, message):
        super().__init__(message)
        self.code = code


# File name of a signal: UTC timestamp, filer slug, six hex. Any six hex is valid and it is
# not compared with the content, so a filer with no shell can still write one by hand.
# \Z (not $) so a trailing newline in the name cannot sneak through.
SIGNAL_NAME_RE = re.compile(r"[0-9]{8}T[0-9]{6}Z-[a-z0-9-]{1,32}-[0-9a-f]{6}\.md\Z")

BODY_MAX_BYTES = 4096
# Per-key length limits in characters (claim and warrant are one line each).
_CLAIM_MAX = 200
_WARRANT_MAX = 300

_REQUIRED = ("filed_by", "claim", "stage", "warrant", "status")
_OPTIONAL = ("supersedes", "contradicts", "confirms", "guardrail")
_FILED_BY_RE = re.compile(r"[A-Za-z0-9._-]{1,48}\Z")
_ENTRY_ADDR_RE = re.compile(r"K-[0-9a-f]{8}\Z")
# [0-9] not \d: \d also matches other scripts' digits.
_GUARDRAIL_RE = re.compile(r"GUARDRAILS#G[0-9]+\Z")
# Control (Cc), format (Cf: zero-width space, bidi override), line/paragraph separators.
_HIDDEN_CATEGORIES = frozenset(("Cc", "Cf", "Zl", "Zp"))


def filer_slug(filed_by):
    """File-name form of `filed_by`: lower-case, other runs become `-`, trimmed, <= 32."""
    return slug(filed_by, 32)


def parse_frontmatter(text):
    """Split a flat `---` fenced block from the body: returns (dict, body).

    One `key: value` per line, no nesting. A repeated key, a line without `: ` or a missing
    closing fence is an error. Flat on purpose: no YAML parser means no YAML surprises
    (anchors, tags, multi-line scalars) in text that agents read unattended. Splits on
    "\\n" only; str.splitlines would treat U+2028 and friends as line ends and hide them.
    """
    lines = text.split("\n")
    if lines[0] != "---":
        raise KnowledgeError(E_SIGNAL, "frontmatter: missing opening fence")
    fields = {}
    for i in range(1, len(lines)):
        line = lines[i]
        if line == "---":
            return fields, "\n".join(lines[i + 1:])
        key, sep, value = line.partition(": ")
        if not sep or not key:
            raise KnowledgeError(E_SIGNAL, "frontmatter line %d: expected 'key: value'" % (i + 1))
        if key in fields:
            raise KnowledgeError(E_SIGNAL, "frontmatter line %d: repeated key" % (i + 1))
        fields[key] = value.strip(" ")
    raise KnowledgeError(E_SIGNAL, "frontmatter: missing closing fence")


def _check_visible(key, value):
    """Reject control and hidden characters instead of cleaning them: a cleaned value would
    differ from what the filer wrote, and an uncleaned one would carry invisible text into
    always-in-context entries."""
    for ch in value:
        if unicodedata.category(ch) in _HIDDEN_CATEGORIES:
            raise KnowledgeError(E_SIGNAL, "%s: control or hidden character" % key)


def _check_length(key, value, maxlen):
    if not 1 <= len(value) <= maxlen:
        raise KnowledgeError(E_SIGNAL, "%s: must be 1-%d characters" % (key, maxlen))


def parse_signal(text):
    """Parse and validate one signal: the fields plus `body`, or raise KnowledgeError."""
    fields, body = parse_frontmatter(text)
    allowed = _REQUIRED + _OPTIONAL
    for key in fields:
        # The unknown key itself is not echoed: it is attacker-chosen text.
        if key not in allowed:
            raise KnowledgeError(E_SIGNAL, "unknown key")
    for key in _REQUIRED:
        if key not in fields:
            raise KnowledgeError(E_SIGNAL, "%s: required" % key)
    for key, value in fields.items():
        _check_visible(key, value)

    if not _FILED_BY_RE.match(fields["filed_by"]):
        raise KnowledgeError(E_SIGNAL, "filed_by: must match [A-Za-z0-9._-]{1,48}")
    _check_length("claim", fields["claim"], _CLAIM_MAX)
    _check_length("warrant", fields["warrant"], _WARRANT_MAX)
    # `none` and friends are valid here; is_warranted() decides what they count for.

    stage = fields["stage"]
    if stage in STAGES_SIGNAL:
        pass
    elif stage in STAGES_ENTRY:
        # Known but not claimable: humans (or a merged proposal) set these, not a filer.
        raise KnowledgeError(E_SIGNAL, "stage: not claimable by a signal")
    else:
        raise KnowledgeError(E_STAGE, "stage: must be one of " + ", ".join(STAGES_SIGNAL))

    if fields["status"] != "pending":
        raise KnowledgeError(E_SIGNAL, "status: must be pending")
    for key in ("supersedes", "contradicts", "confirms"):
        if key in fields and not _ENTRY_ADDR_RE.match(fields[key]):
            raise KnowledgeError(E_SIGNAL, "%s: must be K- plus 8 lowercase hex" % key)
    if "guardrail" in fields and not _GUARDRAIL_RE.match(fields["guardrail"]):
        raise KnowledgeError(E_SIGNAL, "guardrail: must be GUARDRAILS#G<digits>")

    try:
        size = len(body.encode("utf-8"))
    except UnicodeEncodeError:
        raise KnowledgeError(E_SIGNAL, "body: not valid UTF-8")
    if size > BODY_MAX_BYTES:
        raise KnowledgeError(E_SIGNAL, "body: at most %d bytes" % BODY_MAX_BYTES)

    result = dict(fields)
    result["body"] = body
    return result


# --- 5. entry format ---------------------------------------------------------------
# E_ENTRY is any malformed entry; a stage outside the six reuses E_STAGE.
E_ENTRY = "E_ENTRY"

# File name of an entry: `K-<hash8>-<slug>.md`. The slug is `slug(claim)`; a claim that
# reduces to nothing is written as `entry` so the name is never `K-<hash8>-.md`. \Z for the
# same reason as SIGNAL_NAME_RE.
ENTRY_NAME_RE = re.compile(r"K-[0-9a-f]{8}-[a-z0-9-]{1,40}\.md\Z")

# Frontmatter keys in the fixed order render_entry writes them.
_ENTRY_REQUIRED = ("id", "claim", "claim_hash", "stage", "created", "updated")
_ENTRY_OPTIONAL = ("supersedes", "superseded_by", "contradicts", "guardrail", "unwarranted")
_ENTRY_KEYS = _ENTRY_REQUIRED + _ENTRY_OPTIONAL
_CLAIM_HASH_RE = re.compile(r"[0-9a-f]{16}\Z")
_DATE_RE = re.compile(r"[0-9]{4}-[0-9]{2}-[0-9]{2}\Z")
_EVIDENCE_SEP = " | "


def _entry_error(message):
    return KnowledgeError(E_ENTRY, message)


def _check_date(key, value):
    # The regex pins the shape (fromisoformat is looser on newer Pythons); date() rejects
    # month 13 and 30 February.
    if _DATE_RE.match(value):
        try:
            datetime.date(int(value[:4]), int(value[5:7]), int(value[8:]))
            return
        except ValueError:
            pass
    raise _entry_error("%s: must be a YYYY-MM-DD date" % key)


def _parse_evidence_line(line):
    """One `- <signal> | <filed_by> | <stage> | <warrant>` line as a dict."""
    if not line.startswith("- "):
        raise _entry_error("evidence: each line must start with '- '")
    # maxsplit=3: the first three separators split, so a warrant may itself contain ' | '.
    parts = line[2:].split(_EVIDENCE_SEP, 3)
    if len(parts) != 4:
        raise _entry_error("evidence: expected 'signal | filed_by | stage | warrant'")
    signal, filed_by, stage, warrant = parts
    if not SIGNAL_NAME_RE.match(signal):
        raise _entry_error("evidence: signal is not a signal file name")
    if not _FILED_BY_RE.match(filed_by):
        raise _entry_error("evidence: filed_by must match [A-Za-z0-9._-]{1,48}")
    if stage not in STAGES_SIGNAL:
        if stage in STAGES_ENTRY:
            raise _entry_error("evidence: stage not claimable by a signal")
        raise KnowledgeError(E_STAGE, "evidence: stage must be one of " + ", ".join(STAGES_SIGNAL))
    if not 1 <= len(warrant) <= _WARRANT_MAX:
        raise _entry_error("evidence: warrant must be 1-%d characters" % _WARRANT_MAX)
    return {"signal": signal, "filed_by": filed_by, "stage": stage, "warrant": warrant}


def parse_entry(text):
    """Parse and validate one entry: the fields plus `claim_text` and `evidence`, or raise
    KnowledgeError (E_STAGE for a stage outside the six, E_ENTRY for everything else).

    `evidence` is a list of dicts with `signal`, `filed_by`, `stage`, `warrant`. Entries
    carry no signal body text, so there is nothing else to return.
    """
    try:
        fields, body = parse_frontmatter(text)
    except KnowledgeError as err:
        # One parser for both formats; only the code differs (the message is already free of
        # echoed content).
        raise _entry_error(str(err))
    for key in fields:
        if key not in _ENTRY_KEYS:
            raise _entry_error("unknown key")
    for key in _ENTRY_REQUIRED:
        if key not in fields:
            raise _entry_error("%s: required" % key)
    for key, value in fields.items():
        try:
            _check_visible(key, value)
        except KnowledgeError as err:
            raise _entry_error(str(err))

    if not _CLAIM_HASH_RE.match(fields["claim_hash"]):
        raise _entry_error("claim_hash: must be 16 lowercase hex")
    if not 1 <= len(fields["claim"]) <= _CLAIM_MAX:
        raise _entry_error("claim: must be 1-%d characters" % _CLAIM_MAX)
    # id and claim_hash are both derived from the claim; checking them against each other and
    # the claim means a hand-edited claim cannot keep its old identity (and with it the old
    # rejection memory and addresses).
    if fields["claim_hash"] != claim_hash(fields["claim"]):
        raise _entry_error("claim_hash: does not match claim")
    if fields["id"] != "K-" + fields["claim_hash"][:8]:
        raise _entry_error("id: must be K- plus the first 8 of claim_hash")
    if fields["stage"] not in STAGES_ENTRY:
        raise KnowledgeError(E_STAGE, "stage: must be one of " + ", ".join(STAGES_ENTRY))
    _check_date("created", fields["created"])
    _check_date("updated", fields["updated"])
    for key in ("supersedes", "superseded_by", "contradicts"):
        if key in fields and not _ENTRY_ADDR_RE.match(fields[key]):
            raise _entry_error("%s: must be K- plus 8 lowercase hex" % key)
    if "guardrail" in fields and not _GUARDRAIL_RE.match(fields["guardrail"]):
        raise _entry_error("guardrail: must be GUARDRAILS#G<digits>")
    if "unwarranted" in fields and fields["unwarranted"] != "yes":
        raise _entry_error("unwarranted: only the value yes is allowed")

    # Body: `## Claim`, the claim text, `## Evidence`, one line per signal. Blank lines are
    # layout and ignored; anything else outside that shape is an error.
    lines = [ln for ln in body.split("\n") if ln.strip()]
    for ln in lines:
        try:
            _check_visible("body", ln)
        except KnowledgeError as err:
            raise _entry_error(str(err))
    if not lines or lines[0] != "## Claim":
        raise _entry_error("body: must start with a '## Claim' heading")
    if "## Evidence" not in lines:
        raise _entry_error("body: missing '## Evidence' heading")
    split_at = lines.index("## Evidence")
    claim_lines = lines[1:split_at]
    if len(claim_lines) != 1:
        raise _entry_error("body: the claim text must be exactly one line")
    claim_text = claim_lines[0]
    if claim_text != fields["claim"]:
        raise _entry_error("body: claim text does not match the claim key")
    evidence = [_parse_evidence_line(ln) for ln in lines[split_at + 1:]]
    if not evidence:
        raise _entry_error("body: at least one evidence line is required")

    result = dict(fields)
    result["claim_text"] = claim_text
    result["evidence"] = evidence
    return result


def render_entry(fields, evidence):
    """Entry text in the fixed layout: frontmatter keys in the order above, then `## Claim`
    and `## Evidence`. `fields` may be parse_entry's output (its derived `claim_text` and
    `evidence` are ignored). The result is run back through parse_entry before it is
    returned, so this never writes an entry the reader would reject, and a multi-line claim
    cannot add extra structure."""
    for key in fields:
        if key not in _ENTRY_KEYS and key not in ("claim_text", "evidence"):
            raise _entry_error("unknown key")
    lines = ["---"]
    for key in _ENTRY_KEYS:
        if key in fields:
            lines.append("%s: %s" % (key, fields[key]))
    lines += ["---", "", "## Claim", "", fields.get("claim", ""), "", "## Evidence", ""]
    for ev in evidence:
        lines.append("- " + _EVIDENCE_SEP.join(
            (ev["signal"], ev["filed_by"], ev["stage"], ev["warrant"])))
    text = "\n".join(lines) + "\n"
    parse_entry(text)
    return text
