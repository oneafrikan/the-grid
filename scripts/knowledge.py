#!/usr/bin/env python3
"""knowledge.py - helpers for knowledge signals and entries (change `knowledge-signals`).

Sections (added as the change lands, in this order):
    1. Vocabulary   stage names and their rank
    2. Claim hash   claim_hash, entry_id, slug
    3. Warrant      is_warranted, ceiling
    4. Signal       KnowledgeError, parse_frontmatter, parse_signal, SIGNAL_NAME_RE, filer_slug

Design rules:
  * Python 3 standard library only, valid on 3.8 (no `X | Y` annotations, no
    `str.removeprefix`).
  * Pure functions: no file access, no git, no clock. Same input, same output on every
    machine.
  * Error text never echoes claim or warrant text (those may carry hostile content).
  * Sorting, where it appears, is plain code-point order.
"""
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
