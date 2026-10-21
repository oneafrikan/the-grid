#!/usr/bin/env python3
"""knowledge.py - helpers for knowledge signals and entries (change `knowledge-signals`).

Sections (added as the change lands, in this order):
    1. Vocabulary   stage names and their rank
    2. Claim hash   claim_hash, entry_id, slug
    3. Warrant      is_warranted, ceiling
    4. Signal       KnowledgeError, parse_frontmatter, parse_signal, SIGNAL_NAME_RE, filer_slug,
                    Finding, format_finding, iter_signals, iter_done, check_signal
    5. Entry        parse_entry, render_entry, ENTRY_NAME_RE
    6. Address      heading_slugs, resolve_address
    7. Ledger       ledger_path, read_ledger, append_ledger, processed_signals, claim_state
    8. Tree check   iter_entries, check_entry, check_tree (the one function a second tool
                    imports to lint the whole tree)
    9. Plan         build_plan (read-only: which pending signals the sweep would look at)
   10. Command line main, SUBCOMMANDS (the one place a subcommand is registered); `file`
                    writes a signal, `check` lints signals and entries, `plan` prints build_plan

Design rules:
  * Python 3 standard library only, valid on 3.8 (no `X | Y` annotations, no
    `str.removeprefix`).
  * Pure functions: no clock, no git except edited_after_add (and check_signal, which calls it),
    and no file access except resolve_address, read_ledger, append_ledger, iter_signals,
    iter_done, check_signal, iter_entries, check_entry, check_tree and build_plan, which only
    touch files under the root they are given (check_tree and build_plan write nothing). Same
    input, same output on every machine. (The command line is the exception: `file` reads the clock and
    writes one file under the root.)
  * Error text never echoes claim or warrant text (those may carry hostile content).
  * Sorting, where it appears, is plain code-point order.
"""
import collections
import datetime
import hashlib
import json
import os
import re
import subprocess
import sys
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
# E_EDITED is a signal changed after the commit that added it (signals are immutable).
E_EDITED = "E_EDITED"
# E_READ is a file that cannot be opened. Library only: the command line turns it into a
# usage-style failure (exit 2), never a finding.
E_READ = "E_READ"


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


# One problem found by `check`. These codes and the printed line are the interface the later
# lint (map.py --check) reads, so they do not change.
Finding = collections.namedtuple("Finding", ("code", "path", "message"))


def format_finding(finding):
    """`E_<CODE> <relpath>: <message>`, the one line `check` prints per finding."""
    return "%s %s: %s" % (finding.code, finding.path, finding.message)


def _is_handoff_or_readme(name):
    # `signals/README.md` and the `→<agent>.md` hand-off files are not signals and every
    # command ignores them.
    return name == "README.md" or name.startswith("→")


def _has_claim_key(text):
    """True when the first frontmatter block has a `claim:` line. Deliberately loose (no
    parse): a misnamed file may well also be malformed, and it is still a misnamed signal."""
    lines = text.split("\n")
    if lines[0] != "---":
        return False
    for line in lines[1:]:
        if line == "---":
            break
        if line.startswith("claim:"):
            return True
    return False


def iter_signals(root):
    """Pending signals under root/signals/: returns (relative paths, findings).

    Paths are the regular files directly in signals/ (not subdirectories) whose names match
    SIGNAL_NAME_RE, in sorted name order. Findings are E_SIGNAL "misnamed signal file" for a
    `*.md` file that is not a hand-off or README, does not match the pattern, and has a
    `claim:` key: the sweep would never see it, so the lint says so. A missing signals/ is an
    empty result.
    """
    base = os.path.join(root, "signals")
    try:
        names = sorted(os.listdir(base))
    except OSError:
        return [], []
    paths = []
    findings = []
    for name in names:
        if not os.path.isfile(os.path.join(base, name)):
            continue
        rel = "signals/" + name
        if SIGNAL_NAME_RE.match(name):
            paths.append(rel)
        elif name.endswith(".md") and not _is_handoff_or_readme(name):
            try:
                with open(os.path.join(base, name), "rb") as fh:
                    text = fh.read().decode("utf-8")
            except (OSError, UnicodeDecodeError):
                # Cannot tell whether it claims anything; not a signal, so not our concern.
                continue
            if _has_claim_key(text):
                findings.append(Finding(E_SIGNAL, rel, "misnamed signal file"))
    return paths, findings


def iter_done(root):
    """Relative paths of the processed signals in root/signals/done/ that match
    SIGNAL_NAME_RE, sorted. The ledger and anything else in there is ignored."""
    base = os.path.join(root, "signals", "done")
    try:
        names = sorted(os.listdir(base))
    except OSError:
        return []
    return ["signals/done/" + n for n in names
            if SIGNAL_NAME_RE.match(n) and os.path.isfile(os.path.join(base, n))]


def _git(root, *args):
    """stdout of `git <args>` run in root, or None when git is missing or exits non-zero
    (not a repository, no commits yet). Fixed argv, never a shell; LC_ALL=C so the output
    format cannot vary with the machine's locale."""
    env = dict(os.environ, LC_ALL="C")
    try:
        done = subprocess.run(("git",) + args, cwd=root, env=env, stdin=subprocess.DEVNULL,
                              stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    except OSError:
        return None
    if done.returncode != 0:
        return None
    return done.stdout.decode("utf-8", "replace")


def edited_after_add(root, relpath):
    """True when the signal at relpath was changed after the commit that added it, False when
    it was not, None when git cannot answer (no git binary, or root is not a repository).

    A signal is immutable: that is checked from git history, never from the `<hash6>` in the
    name. "Changed" means a commit that modified the path (--diff-filter=M), or an `M` in the
    index or working tree against HEAD. A rename (the sweep moving a signal to signals/done/
    unchanged), a delete and a file git has never seen are not modifications. A rename plus
    an edit looks like a new file and is accepted (a recorded limit of the design).
    """
    history = _git(root, "log", "--diff-filter=M", "--format=%H", "--", relpath)
    if history is None:
        return None
    if history.strip():
        return True
    status = _git(root, "diff", "--name-status", "HEAD", "--", relpath)
    if status is None:
        # A repository without a commit yet: nothing could have been added and then changed.
        return False
    return any(line.startswith("M") for line in status.splitlines())


def check_signal(root, relpath, history_skipped=None):
    """Findings for one signal file (a list, empty when it is valid).

    On top of the format findings, E_EDITED when the signal was changed after the commit that
    added it (see edited_after_add). When git cannot answer the check is skipped and relpath
    is appended to `history_skipped` (if given) so the caller can say so once.
    """
    findings = _check_signal_format(root, relpath)
    edited = edited_after_add(root, relpath)
    if edited is None:
        if history_skipped is not None:
            history_skipped.append(relpath)
    elif edited:
        findings.append(Finding(E_EDITED, relpath, "signal changed after it was added"))
    return findings


def _check_signal_format(root, relpath):
    """Format findings for one signal file (a list, empty when it is valid).

    The parse findings carry the code of the error parse_signal raised. A file whose name
    filer is not the slug of `filed_by` is an E_SIGNAL too: the name is what the sweep and
    the humans see, so it must not name someone else. An unreadable file raises
    KnowledgeError(E_READ) naming the path; a file that is not UTF-8 is a finding.
    """
    try:
        with open(os.path.join(root, *relpath.split("/")), "rb") as fh:
            data = fh.read()
    except OSError:
        raise KnowledgeError(E_READ, "cannot read " + relpath)
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError:
        return [Finding(E_SIGNAL, relpath, "file: not valid UTF-8")]
    name = relpath.rsplit("/", 1)[-1]
    if not SIGNAL_NAME_RE.match(name):
        return [Finding(E_SIGNAL, relpath, "file name does not match the signal pattern")]
    try:
        fields = parse_signal(text)
    except KnowledgeError as err:
        return [Finding(err.code, relpath, str(err))]
    # Name layout: 16-char timestamp, "-", filer, "-", six hex, ".md" (10 chars with its dash).
    # The filer is not echoed: it is filer-chosen text.
    if name[17:-10] != filer_slug(fields["filed_by"]):
        return [Finding(E_SIGNAL, relpath, "file name filer does not match filed_by")]
    return []


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


# --- 6. address resolution ---------------------------------------------------------
# E_ADDRESS is any address that does not resolve (zero or several files, bad form, no heading).
E_ADDRESS = "E_ADDRESS"

_ADDR_ID_RE = re.compile(r"K-[0-9a-f]{8}\Z")
_HEADING_RE = re.compile(r"#{1,6}[ \t]+(.*?)[ \t#]*\Z")
_FENCE_RE = re.compile(r"(`{3,}|~{3,})")


def heading_slugs(text):
    """Slugs of the Markdown headings in `text`, in document order.

    Slug rule: lower-case, punctuation dropped, whitespace runs to one `-`. Lines inside a
    fenced code block are skipped so a `# comment` in a code sample is not an address target.
    """
    slugs = []
    fence = None
    for line in text.split("\n"):
        stripped = line.strip()
        marker = _FENCE_RE.match(stripped)
        if marker:
            if fence is None:
                fence = marker.group(1)[0]
            elif marker.group(1)[0] == fence:
                fence = None
            continue
        if fence is not None:
            continue
        found = _HEADING_RE.match(line)
        if found:
            # \w keeps letters and digits of any script plus `_`; `-` is kept too.
            kept = re.sub(r"[^\w\s-]", "", found.group(1).lower())
            slugs.append("-".join(kept.split()))
    return slugs


def _address_error(message):
    return KnowledgeError(E_ADDRESS, message)


def resolve_address(root, addr):
    """Resolve a knowledge address under `root`: returns (relative_path, slug_or_None).

    Forms:
      K-<hash8>[#slug]                     matches knowledge/*/K-<hash8>-*.md, so an entry that
                                           moves between stage directories still resolves
      knowledge/<dir>/K-<hash8>-<slug>.md[#slug]   valid only while the file is at that path
    Raises KnowledgeError(E_ADDRESS) for zero matches, several matches (every match is
    listed), a missing path, a slug that is not a heading of the file, or any other form.
    Reads files under `root` only; nothing is written.
    """
    ref, sep, want = addr.partition("#")
    if _ADDR_ID_RE.match(ref):
        rel = _find_by_id(root, ref)
    elif ref.startswith("knowledge/"):
        parts = ref.split("/")
        # Exactly knowledge/<dir>/<entry file>: a fixed shape means `..`, `.`, empty parts
        # and absolute paths cannot reach outside the knowledge tree.
        if (len(parts) != 3 or parts[1] in ("", ".", "..") or not ENTRY_NAME_RE.match(parts[2])):
            raise _address_error("path form must be knowledge/<dir>/K-<hash8>-<slug>.md")
        rel = ref
        if not os.path.isfile(os.path.join(root, *parts)):
            raise _address_error("no such file: " + rel)
    else:
        raise _address_error("address must be K-<hash8> or a knowledge/ path")
    if not sep:
        return rel, None
    try:
        with open(os.path.join(root, *rel.split("/")), encoding="utf-8") as fh:
            text = fh.read()
    except (OSError, UnicodeDecodeError):
        raise _address_error("cannot read " + rel)
    if want not in heading_slugs(text):
        raise _address_error("no heading " + want)
    return rel, want


def _find_by_id(root, entry_addr):
    """Relative path of the one entry file for `K-<hash8>`, or raise E_ADDRESS."""
    base = os.path.join(root, "knowledge")
    matches = []
    try:
        dirs = sorted(os.listdir(base))
    except OSError:
        dirs = []
    for d in dirs:
        if not os.path.isdir(os.path.join(base, d)):
            continue
        for name in sorted(os.listdir(os.path.join(base, d))):
            if name.startswith(entry_addr + "-") and ENTRY_NAME_RE.match(name):
                matches.append("knowledge/%s/%s" % (d, name))
    if not matches:
        raise _address_error("no entry matches " + entry_addr)
    if len(matches) > 1:
        raise _address_error("ambiguous %s: %s" % (entry_addr, ", ".join(matches)))
    return matches[0]


# --- 7. ledger ---------------------------------------------------------------------
# E_LEDGER is any ledger line that is not valid JSON, has an unknown event, or lacks a
# required key. The ledger is append-only, so old bytes stay a prefix of the file and a
# reader never sees a record change under it.
E_LEDGER = "E_LEDGER"

_DISPOSITIONS = ("wip", "written", "confirmed", "escalated", "invalid", "duplicate",
                 "repeat-rejected", "secret")
_RESULTS = ("accepted", "rejected")
# Required keys per event. Extra keys are allowed so a later writer can add fields without
# breaking older readers.
_LEDGER_REQUIRED = {
    "disposition": ("signal", "claim_hash", "disposition", "entry", "issue", "pr", "run"),
    "resolution": ("claim_hash", "pr", "result", "run"),
    "reopen": ("claim_hash", "by", "run"),
}


def ledger_path(root):
    """Path of the ledger file under `root`."""
    return os.path.join(root, "signals", "done", "ledger.jsonl")


def _ledger_error(lineno, message):
    # Line number only: the line itself may carry hostile text, so it is never echoed.
    return KnowledgeError(E_LEDGER, "line %d: %s" % (lineno, message))


def _check_ledger_record(lineno, rec):
    if not isinstance(rec, dict):
        raise _ledger_error(lineno, "not a JSON object")
    event = rec.get("event")
    if event not in _LEDGER_REQUIRED:
        raise _ledger_error(lineno, "unknown event")
    for key in _LEDGER_REQUIRED[event]:
        if key not in rec:
            raise _ledger_error(lineno, "%s needs key %s" % (event, key))
    if event == "disposition" and rec["disposition"] not in _DISPOSITIONS:
        raise _ledger_error(lineno, "unknown disposition")
    if event == "resolution" and rec["result"] not in _RESULTS:
        raise _ledger_error(lineno, "unknown result")


def read_ledger(root):
    """All ledger records under `root`, oldest first; `[]` when the file is absent.

    Blank lines are skipped. Any other bad line raises KnowledgeError(E_LEDGER) naming its
    1-based line number.
    """
    try:
        with open(ledger_path(root), encoding="utf-8") as fh:
            lines = fh.read().split("\n")
    except FileNotFoundError:
        return []
    records = []
    for lineno, line in enumerate(lines, 1):
        if not line.strip():
            continue
        try:
            rec = json.loads(line)
        except ValueError:
            raise _ledger_error(lineno, "not valid JSON")
        _check_ledger_record(lineno, rec)
        records.append(rec)
    return records


def append_ledger(root, records):
    """Append each record as one compact JSON line, creating signals/done/ when missing.

    The file is only ever opened in append mode ("a"), never "w" or "r+", so bytes already
    written are never rewritten. Records are validated first so a bad one writes nothing.
    """
    lines = []
    for i, rec in enumerate(records, 1):
        _check_ledger_record(i, rec)
        lines.append(json.dumps(rec, sort_keys=True, separators=(",", ":")) + "\n")
    path = ledger_path(root)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "a", encoding="utf-8") as fh:
        fh.write("".join(lines))


def processed_signals(ledger):
    """Set of signal file names that have a `disposition` line."""
    return {rec["signal"] for rec in ledger if rec["event"] == "disposition"}


def claim_state(ledger, claim_hash):
    """State of one claim hash: {"escalated_open": issue or None, "rejected": bool}.

    escalated_open is the issue of the latest `escalated` disposition with no `resolution`
    after it. rejected is true when the latest resolution/reopen line is a rejected
    resolution. Matching is by exact normalised claim hash, not meaning: a reworded claim
    is a new claim.
    """
    escalated_open = None
    rejected = False
    for rec in ledger:
        if rec["claim_hash"] != claim_hash:
            continue
        event = rec["event"]
        if event == "disposition" and rec["disposition"] == "escalated":
            escalated_open = rec["issue"]
        elif event == "resolution":
            escalated_open = None
            rejected = rec["result"] == "rejected"
        elif event == "reopen":
            rejected = False
    return {"escalated_open": escalated_open, "rejected": rejected}


def open_escalations(ledger):
    """Every `escalated` disposition line with no later `resolution` for its claim hash, oldest
    first, as {"claim_hash", "signal", "issue", "pr"}. The role checks each against the real PR
    state; the ledger alone cannot know whether it merged.
    """
    open_lines = []
    for rec in ledger:
        if rec["event"] == "disposition" and rec["disposition"] == "escalated":
            open_lines.append(rec)
        elif rec["event"] == "resolution":
            # A resolution closes every earlier escalation of that claim, not just the latest.
            open_lines = [r for r in open_lines if r["claim_hash"] != rec["claim_hash"]]
    return [{"claim_hash": r["claim_hash"], "signal": r["signal"], "issue": r["issue"],
             "pr": r["pr"]} for r in open_lines]


# --- 8. tree check -----------------------------------------------------------------
# E_ADDR is a finding for a cross-link whose address does not resolve. It is the finding code;
# resolve_address itself raises E_ADDRESS, which check_entry turns into this.
E_ADDR = "E_ADDR"

# Directory each entry stage lives in: every stage in the directory of its own name except
# `canonical`, which lives in `canon/`.
_STAGE_DIRS = dict((stage, stage) for stage in STAGES_ENTRY)
_STAGE_DIRS["canonical"] = "canon"
ENTRY_DIRS = tuple(_STAGE_DIRS[stage] for stage in STAGES_ENTRY)


def iter_entries(root):
    """(directory name, relative path) of every `knowledge/<dir>/K-*.md` regular file in the six
    stage directories, sorted by path. A missing directory is skipped; other directories under
    knowledge/ are not entries and are ignored."""
    found = []
    for dirname in ENTRY_DIRS:
        base = os.path.join(root, "knowledge", dirname)
        try:
            names = os.listdir(base)
        except OSError:
            continue
        for name in names:
            if name.startswith("K-") and name.endswith(".md") \
                    and os.path.isfile(os.path.join(base, name)):
                found.append((dirname, "knowledge/%s/%s" % (dirname, name)))
    return sorted(found, key=lambda item: item[1])


def _load_entry(root, relpath):
    """parse_entry of the file at relpath, or None when it cannot be read or parsed (the entry
    is then reported on its own; a link to it simply cannot be confirmed)."""
    try:
        with open(os.path.join(root, *relpath.split("/")), "rb") as fh:
            return parse_entry(fh.read().decode("utf-8"))
    except (OSError, UnicodeDecodeError, KnowledgeError):
        return None


def _link_findings(root, relpath, fields):
    """Findings for the supersede cross-links of one parsed entry.

    A link must hold both ways: `superseded_by: K-new` needs K-new to carry `supersedes: K-old`,
    and `supersedes: K-old` needs K-old to carry `superseded_by: K-new` and sit in superseded/.
    The addresses are regex-checked K-<hex>, so echoing them is safe.
    """
    findings = []
    own = fields["id"]
    for key, back in (("superseded_by", "supersedes"), ("supersedes", "superseded_by")):
        if key not in fields:
            continue
        try:
            target, _ = resolve_address(root, fields[key])
        except KnowledgeError as err:
            findings.append(Finding(E_ADDR, relpath, "%s: %s" % (key, err)))
            continue
        other = _load_entry(root, target)
        if other is None or other.get(back) != own:
            findings.append(Finding(E_ENTRY, relpath,
                                    "%s: %s does not carry %s back" % (key, fields[key], back)))
        elif key == "supersedes" and target.split("/")[1] != "superseded":
            findings.append(Finding(E_ENTRY, relpath,
                                    "supersedes: %s is not in knowledge/superseded/" % fields[key]))
    return findings


def check_entry(root, dirname, relpath):
    """Findings for one entry file (a list, empty when it is valid).

    parse_entry findings carry its code and end the check (there are no fields to compare). On
    a parsed entry: E_STAGE when `stage` disagrees with the directory, E_ENTRY when the file
    name is not `<id>-<slug of the claim>.md`, and the cross-link findings. An unreadable file
    raises KnowledgeError(E_READ) naming the path; a file that is not UTF-8 is a finding.
    """
    try:
        with open(os.path.join(root, *relpath.split("/")), "rb") as fh:
            data = fh.read()
    except OSError:
        raise KnowledgeError(E_READ, "cannot read " + relpath)
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError:
        return [Finding(E_ENTRY, relpath, "file: not valid UTF-8")]
    try:
        fields = parse_entry(text)
    except KnowledgeError as err:
        return [Finding(err.code, relpath, str(err))]
    findings = []
    want = _STAGE_DIRS[fields["stage"]]
    if dirname != want:
        findings.append(Finding(E_STAGE, relpath,
                                "stage does not match the directory (expected knowledge/%s/)" % want))
    # Same fallback as the writer: a claim that reduces to nothing is named `entry`.
    if relpath.rsplit("/", 1)[-1] != "%s-%s.md" % (fields["id"], slug(fields["claim"]) or "entry"):
        findings.append(Finding(E_ENTRY, relpath, "file name does not match id and claim"))
    return findings + _link_findings(root, relpath, fields)


def check_tree(root, history_skipped=None):
    """All findings for pending signals, done signals and entries, sorted by path then code
    (then message, so the order is total). Writes nothing. `history_skipped` is passed to
    check_signal. Raises KnowledgeError(E_READ) for a file that cannot be opened."""
    paths, findings = iter_signals(root)
    for rel in paths + iter_done(root):
        findings += check_signal(root, rel, history_skipped)
    for dirname, rel in iter_entries(root):
        findings += check_entry(root, dirname, rel)
    return sorted(findings, key=lambda f: (f.path, f.code, f.message))


# --- 9. plan -----------------------------------------------------------------------
# Signals one sweep run looks at when no cap is given.
DEFAULT_CAP = 10


# The scan runs in bash because the repository's one secret-pattern table is a bash library
# (hooks/lib/secret-patterns.sh); a Python copy of it would drift. Fixed argv, no shell=True:
# $1 is the library, $2 the signal. Strict mode (SECRET_STRICT=1) ignores the placeholder
# words and the allow pragma, so a signal cannot opt out of the scan. It prints only the
# pattern name (SECRET_MATCH_NAME), never the line, and exits 3 on a hit, 0 when clean.
_SECRET_SCAN_SCRIPT = (
    'export SECRET_STRICT=1\n'
    '. "$1" || exit 4\n'
    'while IFS= read -r line || [ -n "$line" ]; do\n'
    '  if secret_match_long "$line"; then printf "%s" "$SECRET_MATCH_NAME"; exit 3; fi\n'
    'done < "$2"\n'
    'exit 0\n'
)
# A pattern name is lower-case words joined by dashes; anything else from the scanner is
# not trusted into the plan.
_SECRET_NAME_RE = re.compile(r"[a-z0-9-]{1,40}\Z")


def find_secret_patterns():
    """Path of secret-patterns.sh: $KNOWLEDGE_SECRET_PATTERNS if set, else the copy beside
    this script's repo (<script dir>/../hooks/lib), else $GRID_DIR (default ~/.the-grid).

    A project cut from the template has no hooks/ of its own, hence the last two. Raises
    KnowledgeError(E_READ) when none exists: no scan means no sweep (fail closed). The set
    variable is used alone, never falling through, so a typo cannot silently scan with
    another table.
    """
    env = os.environ.get("KNOWLEDGE_SECRET_PATTERNS")
    if env:
        candidates = [env]
    else:
        here = os.path.dirname(os.path.abspath(__file__))
        grid = os.environ.get("GRID_DIR") or os.path.join(os.path.expanduser("~"), ".the-grid")
        candidates = [os.path.join(here, os.pardir, "hooks", "lib", "secret-patterns.sh"),
                      os.path.join(grid, "hooks", "lib", "secret-patterns.sh")]
    for path in candidates:
        if os.path.isfile(path):
            return path
    raise KnowledgeError(E_READ, "secret-patterns.sh not found (set KNOWLEDGE_SECRET_PATTERNS)")


def scan_secret(lib, path):
    """Pattern name when the file at `path` holds a token-shaped value, else None.

    Output of the scanner is captured and only a well-formed pattern name is returned, so
    the matched text can reach neither stdout nor stderr. A scanner that fails in any other
    way raises KnowledgeError(E_READ) rather than passing the signal.
    """
    env = dict(os.environ)
    # BASH_ENV would run an arbitrary file inside the scan.
    env.pop("BASH_ENV", None)
    try:
        proc = subprocess.run(["bash", "-c", _SECRET_SCAN_SCRIPT, "knowledge-secret-scan", lib, path],
                              stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                              stderr=subprocess.DEVNULL, env=env)
    except OSError:
        raise KnowledgeError(E_READ, "cannot run the secret scan")
    if proc.returncode == 0:
        return None
    name = proc.stdout.decode("utf-8", "replace")
    if proc.returncode == 3 and _SECRET_NAME_RE.match(name):
        return name
    raise KnowledgeError(E_READ, "the secret scan failed")


def build_plan(root, cap=DEFAULT_CAP):
    """Read-only plan of the pending signals: a dict that json.dumps(sort_keys=True) renders
    byte-identically on an unchanged tree (no clock, no run id, no absolute paths).

    Pending = a name matching SIGNAL_NAME_RE directly in signals/ that has no ledger
    `disposition` line and is not already in signals/done/. Oldest name first (the timestamp
    leads the name, so code-point order is age order); only the first `cap` are listed and the
    rest are counted in `deferred`, untouched. A signal with any check_signal finding is
    `invalid` with the finding codes in `reasons`; every other one is `pending` for now (later
    changes replace that with the real dispositions). Later changes add fields to each signal
    entry, never remove one. A grammatically valid signal that holds a token-shaped value is
    `secret` (reasons: the pattern name only, no claim_hash). A valid, non-secret signal whose
    claim has an open escalation is `duplicate` (reasons name the issue); one whose claim was
    rejected with no later reopen is `repeat-rejected`. `reconcile` lists the escalations with no
    resolution yet; each takes one slot of the cap. Raises KnowledgeError(E_READ) for
    a file that cannot be opened or when the secret scanner is missing or fails, and E_LEDGER
    for a bad ledger.
    """
    # Fail closed before looking at any signal: no scanner means no sweep.
    secret_lib = find_secret_patterns()
    paths, _ = iter_signals(root)
    ledger = read_ledger(root)
    seen = processed_signals(ledger)
    seen.update(rel.rsplit("/", 1)[-1] for rel in iter_done(root))
    pending = [rel for rel in paths if rel.rsplit("/", 1)[-1] not in seen]

    # Unresolved escalations come first and each takes one slot of the cap, so the role's
    # per-run work stays bounded; those past the cap are counted in `deferred`, not dropped.
    open_all = open_escalations(ledger)
    reconcile = open_all[:cap]
    slots = cap - len(reconcile)

    signals = []
    counts = {}
    for rel in pending[:slots]:
        findings = check_signal(root, rel)
        entry = {"claim_hash": None, "disposition": "pending", "entry": None,
                 "file": rel.rsplit("/", 1)[-1], "needs_judgement": [], "reasons": [],
                 "stage": None}
        if findings:
            entry["disposition"] = "invalid"
            # Codes only, never the message: it names the key but a code is all a reader needs.
            entry["reasons"] = sorted(set(f.code for f in findings))
        else:
            full = os.path.join(root, *rel.split("/"))
            # The whole file is scanned before anything is read from it; a hit names the
            # pattern and nothing else (no hash, no entry).
            secret = scan_secret(secret_lib, full)
            if secret:
                entry["disposition"] = "secret"
                entry["reasons"] = [secret]
            else:
                # Valid, so it parses; the hash is the claim's identity for the later rules.
                with open(full, "rb") as fh:
                    entry["claim_hash"] = claim_hash(parse_signal(fh.read().decode("utf-8"))["claim"])
                # Ledger rules, by claim hash only. An open escalation wins over a stale
                # rejection (claim_state clears `rejected` only on reopen, and a re-escalation
                # needs a reopen first); a later `reopen` lets the claim through to later rules.
                state = claim_state(ledger, entry["claim_hash"])
                if state["escalated_open"] is not None:
                    entry["disposition"] = "duplicate"
                    entry["reasons"] = ["open issue %s" % state["escalated_open"]]
                elif state["rejected"]:
                    entry["disposition"] = "repeat-rejected"
                    entry["reasons"] = ["rejected"]
        counts[entry["disposition"]] = counts.get(entry["disposition"], 0) + 1
        signals.append(entry)
    return {"cap": cap, "counts": counts,
            "deferred": len(pending) - len(signals) + len(open_all) - len(reconcile),
            "pending": len(pending), "reconcile": reconcile, "signals": signals}


# --- 10. command line --------------------------------------------------------------
# Exit status: 0 ok, 1 findings (`check`), 2 usage error or unreadable file. Every error is
# one `knowledge.py: ...` line on stderr and nothing on stdout, so a caller can treat stdout
# as the result alone.


class UsageError(Exception):
    """Bad command line; main() turns it into one stderr line and exit status 2."""


def default_root():
    """Git root of the current directory, else the current directory (git absent or failing)."""
    try:
        out = subprocess.run(["git", "rev-parse", "--show-toplevel"], stdout=subprocess.PIPE,
                             stderr=subprocess.DEVNULL, check=True).stdout
        top = out.decode("utf-8", "surrogateescape").strip()
        if top:
            return top
    except (OSError, subprocess.CalledProcessError):
        pass
    return os.getcwd()


def _cmd_hash(root, claim):
    # root is unused here; it is accepted so every subcommand shares one call shape.
    print(claim_hash(claim))
    return 0


_NOW_RE = re.compile(r"[0-9]{8}T[0-9]{6}Z\Z")
# Value-taking options of `file`, in the order their keys follow the required ones.
_FILE_OPTIONAL = ("supersedes", "contradicts", "confirms", "guardrail")


def _signal_time():
    """UTC timestamp for a signal name: KNOWLEDGE_NOW when set (so tests are deterministic),
    else the clock."""
    now = os.environ.get("KNOWLEDGE_NOW")
    if now is None:
        return datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    if not _NOW_RE.match(now):
        raise UsageError("KNOWLEDGE_NOW must look like YYYYMMDDTHHMMSSZ")
    return now


def _cmd_file(root, filer=None, claim=None, stage=None, warrant=None, body_file=None, **optional):
    """Write one signal under root/signals/ and print its path; never commits, never needs git.

    Everything is validated (through parse_signal, on the exact text that would be written)
    before the first byte touches disk, so a bad argument leaves no file behind. Validation
    failures are usage errors here (exit 2): the caller gave bad input.
    """
    values = {"filed_by": filer, "claim": claim, "stage": stage, "warrant": warrant}
    for key, value in values.items():
        if value is None:
            raise UsageError("file needs --%s" % ("filer" if key == "filed_by" else key))
    values.update((k, v) for k, v in optional.items() if v is not None)
    values["status"] = "pending"

    body = ""
    if body_file is not None:
        try:
            # Bytes then strict decode: a body that is not UTF-8 is refused, not mangled.
            with open(body_file, "rb") as fh:
                body = fh.read().decode("utf-8")
        except (OSError, UnicodeDecodeError):
            raise UsageError("cannot read --body-file as UTF-8 text")

    # Fixed key order: required keys, then whichever optional keys were given.
    lines = ["---"]
    for key in _REQUIRED + _OPTIONAL:
        if key in values:
            lines.append("%s: %s" % (key, values[key]))
    lines.append("---")
    text = "\n".join(lines) + "\n"
    if body:
        text += "\n" + body

    try:
        parsed = parse_signal(text)
    except KnowledgeError as err:
        raise UsageError("%s %s" % (err.code, err))
    # A value holding a newline (or padding the parser trims) would parse as something other
    # than what was asked for, e.g. a claim that smuggles in a `guardrail:` line. Refuse it.
    if any(parsed.get(key) != value for key, value in values.items()):
        raise UsageError("E_SIGNAL a value is not a single trimmed line")

    data = text.encode("utf-8")
    name = "%s-%s-%s.md" % (_signal_time(), filer_slug(filer), hashlib.sha256(data).hexdigest()[:6])
    if not SIGNAL_NAME_RE.match(name):
        # e.g. a filer name with no letters or digits leaves an empty slug.
        raise UsageError("E_SIGNAL filed_by gives no usable file-name slug")
    directory = os.path.join(root, "signals")
    os.makedirs(directory, exist_ok=True)
    path = os.path.join(directory, name)
    try:
        # "x" so an existing file is never rewritten: the same content in the same second by
        # the same filer lands on the same name and is left as it is.
        with open(path, "xb") as fh:
            fh.write(data)
    except FileExistsError:
        pass
    print(path)
    return 0


def _check_target(root, arg):
    """Root-relative `/` path for a `check` PATH argument: relative ones are taken as relative
    to root, absolute ones must sit under it."""
    if os.path.isabs(arg):
        arg = os.path.relpath(arg, root)
    parts = os.path.normpath(arg).split(os.sep)
    if parts[0] == "..":
        raise UsageError("path is outside the root")
    return "/".join(parts)


def _cmd_check(root, *paths, address=None):
    """Print one finding per line, sorted by path; exit 0 when there are none, 1 otherwise.

    With PATH arguments only those signal files are checked; with none, check_tree: every
    pending and done signal and every entry. Findings are collected before anything is printed,
    so an unreadable file (exit 2) leaves stdout empty. Output never carries claim text.

    With --address ADDR (no PATH allowed) it resolves one address instead: the resolved
    relative path (plus `#slug` when given) goes to stdout and the exit is 0; an address that
    does not resolve raises E_ADDRESS, which main prints on stderr with exit 1.
    """
    if address is not None:
        if paths:
            raise UsageError("--address cannot be combined with PATH arguments")
        rel, slug = resolve_address(root, address)
        print(rel if slug is None else "%s#%s" % (rel, slug))
        return 0
    findings = []
    skipped = []
    try:
        if paths:
            for arg in paths:
                rel = _check_target(root, arg)
                # Hand-off files and the README are ignored by every command, named or not.
                if not _is_handoff_or_readme(rel.rsplit("/", 1)[-1]):
                    findings += check_signal(root, rel, skipped)
        else:
            findings = check_tree(root, skipped)
    except KnowledgeError as err:
        if err.code != E_READ:
            raise
        raise UsageError("%s %s" % (err.code, err))
    if skipped:
        # One line however many signals: every other rule was still applied, and this is not
        # a failure.
        print("notice: git history unavailable, edited-signal check skipped", file=sys.stderr)
    for finding in sorted(findings, key=lambda f: (f.path, f.code, f.message)):
        print(format_finding(finding))
    return 1 if findings else 0


def _cmd_plan(root, cap=None):
    """Print build_plan as JSON (sorted keys, 2-space indent) and write nothing. Exit 0.

    --cap N limits how many pending signals are listed (default DEFAULT_CAP, N >= 0). An
    unreadable signal is a usage-style failure (exit 2) like in `check`; the plan is built
    before anything is printed so stdout stays empty then.
    """
    if cap is None:
        limit = DEFAULT_CAP
    else:
        # ASCII digits only: no sign, space or other script's digits, so the cap is one plain
        # non-negative number.
        if not (cap.isascii() and cap.isdigit()):
            raise UsageError("--cap must be a non-negative integer")
        limit = int(cap)
    try:
        plan = build_plan(root, limit)
    except KnowledgeError as err:
        if err.code != E_READ:
            raise
        raise UsageError("%s %s" % (err.code, err))
    print(json.dumps(plan, sort_keys=True, indent=2))
    return 0


# Subcommand table: name -> (number of positional arguments or None for any number,
# value-taking options, handler).
# Options map `--flag` to the handler's keyword name; handler(root, *positionals, **options).
# A later subcommand is one new entry here plus its handler.
SUBCOMMANDS = {
    "hash": (1, {}, _cmd_hash),
    "check": (None, {"--address": "address"}, _cmd_check),
    "plan": (0, {"--cap": "cap"}, _cmd_plan),
    "file": (0, dict([("--filer", "filer"), ("--claim", "claim"), ("--stage", "stage"),
                      ("--warrant", "warrant"), ("--body-file", "body_file")]
                     + [("--" + k, k) for k in _FILE_OPTIONAL]), _cmd_file),
}


def _parse(argv):
    """Return (name, root_or_None, positionals, options) or raise UsageError."""
    if not argv:
        raise UsageError("usage: knowledge.py <%s> [--root DIR] [args]" % "|".join(SUBCOMMANDS))
    name = argv[0]
    if name not in SUBCOMMANDS:
        raise UsageError("unknown subcommand %r" % name)
    known = SUBCOMMANDS[name][1]
    root = None
    positionals = []
    options = {}
    i = 1
    while i < len(argv):
        arg = argv[i]
        if arg == "--":
            # Everything after `--` is positional, so a claim may start with a dash.
            positionals += argv[i + 1:]
            break
        if arg == "--root":
            if i + 1 >= len(argv):
                raise UsageError("--root needs a directory")
            root = argv[i + 1]
            i += 1
        elif arg in known:
            if i + 1 >= len(argv):
                raise UsageError("%s needs a value" % arg)
            if known[arg] in options:
                raise UsageError("%s given twice" % arg)
            # The value is taken verbatim, even if it starts with a dash (a claim may).
            options[known[arg]] = argv[i + 1]
            i += 1
        elif arg.startswith("-") and arg != "-":
            raise UsageError("unknown option %r" % arg)
        else:
            positionals.append(arg)
        i += 1
    if SUBCOMMANDS[name][0] is not None and len(positionals) != SUBCOMMANDS[name][0]:
        raise UsageError("%s takes %d argument(s)" % (name, SUBCOMMANDS[name][0]))
    return name, root, positionals, options


def main(argv=None):
    """Run one subcommand and return its exit status."""
    if argv is None:
        argv = sys.argv[1:]
    try:
        name, root, positionals, options = _parse(argv)
        if root is None:
            root = default_root()
        return SUBCOMMANDS[name][2](root, *positionals, **options)
    except UsageError as err:
        print("knowledge.py: %s" % err, file=sys.stderr)
        return 2
    except KnowledgeError as err:
        print("knowledge.py: %s %s" % (err.code, err), file=sys.stderr)
        return 1
    except UnicodeError:
        # An argument that is not valid UTF-8 (surrogate escapes) cannot be hashed; the text
        # itself is not echoed.
        print("knowledge.py: argument is not valid UTF-8", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
