#!/usr/bin/env python3
"""knowledge.py - helpers for knowledge signals and entries (change `knowledge-signals`).

Sections (added as the change lands, in this order):
    1. Vocabulary   stage names and their rank
    2. Claim hash   claim_hash, entry_id, slug
    3. Warrant      is_warranted, ceiling

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
