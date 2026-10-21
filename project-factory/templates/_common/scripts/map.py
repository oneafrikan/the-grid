#!/usr/bin/env python3
"""map.py - generate MAP.md, the one session-start map of a grid project.

Usage:
    map.py [--check] [--include-untracked] [--root DIR]
                                      write (or verify) <root>/MAP.md
    map.py status [--root DIR]        print stage counts and pending signals (writes nothing)

Exit codes: 0 ok / current, 1 stale or missing or a knowledge lint finding (--check only),
2 error (bad argument, unreadable input, over the token budget).

--check also lints signals/ and knowledge/ with scripts/knowledge.py (change
`epistemic-enforcement`, spec `map-lint`); it is skipped with one notice line when
knowledge.py or both directories are absent.

Design rules (change `charter-files`, spec `repo-map`):
  * Python 3 standard library only, valid on 3.8.
  * Output is a pure function of the files under the root: UTF-8, "\\n" newlines,
    code-point sorting, no timestamps, no locale dependence. So it is the same on every
    machine. The one VCS call is `ls-files` (see tracked_paths): inside a repo the
    Files and Skills rows list tracked files only, so a local untracked file (say
    .grid/project.yaml) cannot make the map machine-specific or the gate fail.
    Outside a repo, or with --include-untracked (cut-project.sh, whose seeded files are
    not committed yet), the filesystem decides.
  * MAP.md holds NO volatile data (no stage counts, no pending-signal counts). Those
    come from `status`, which is never checked, so signal and sweep commits cannot
    make the map stale. Only canon (a human PR) can.
  * One script serves the-grid and every project: a section whose source directory is
    absent is omitted (feature detection). The copy under
    project-factory/templates/_common/scripts/map.py must stay byte-identical.
"""
import difflib
import importlib
import os
import re
import subprocess
import sys

# --- budget ------------------------------------------------------------------------
# MAP.md is read at every session start, so its size is a token cost. Over either limit
# the script refuses to write (exit 2) rather than silently growing.
MAX_LINES = 150
MAX_BYTES = 12000

# --- vocabulary --------------------------------------------------------------------
# The six stages, in order. Only `status` uses them; MAP.md never prints a count.
STAGES = ("wip", "provisional", "established", "canonical", "superseded", "retired")

CANON_MAX = 20        # canon one-liners listed before "+N more"
CLAIM_MAX = 140       # claim length before "..."
REGEN = "run: python3 scripts/map.py"
# Agent-to-agent handoffs live in signals/ as `<right-arrow><agent>.md` (the existing
# Signal Protocol). They are not knowledge signals, so `status` skips them. Built with
# chr() so this source file stays pure ASCII.
HANDOFF_PREFIX = chr(0x2192)

# --- the Files registry --------------------------------------------------------------
# (path, what, read when). Fixed order. A row appears only if the path exists in the
# root, so a project never sees a pointer to a file it does not have. RELATED.md is
# optional (cut-project.sh --with-related), so it is listed only when present.
REGISTRY = (
    ("PURPOSE.md", "What this project is for: problem, intended solution, outcome", "session start"),
    ("MAP.md", "This map (generated; do not edit)", "session start"),
    ("GUARDRAILS.md", "Must-nots, one per line with an ID and how each is checked",
     "before editing, committing or opening a PR"),
    ("BEHAVIOUR.md", "This project's additions to the grid-wide agent defaults",
     "before filing a signal or changing how agents work here"),
    ("CLAUDE.md", "Conventions and commands for agents", "loaded automatically; conventions"),
    ("CONTEXT.md", "Domain terms and structural decisions",
     "a domain term or structural decision is unclear"),
    ("LEARNINGS.md", "Durable lessons from past work",
     "on demand: debugging, or before repeating a past mistake"),
    ("SPECS.md", "The spec-driven convention for this repo",
     "before proposing or implementing a non-trivial change"),
    ("openspec/", "Specs (current truth) and in-flight changes",
     "before implementing: specs and in-flight changes"),
    ("SKILLS.md", "Generated index of every skill", "choosing a skill"),
    ("RELATED.md", "Neighbouring projects and what each owns",
     "before building a new capability or adding a dependency"),
    ("handoffs/", "Notes left by earlier sessions", "resuming earlier work"),
    ("signals/", "Knowledge signals filed by agents and humans; agent handoffs", "filing a signal"),
    ("knowledge/", "Claims by stage; knowledge/canon/ is human-approved", "you need a claim below canon"),
    (".grid/project.yaml", "Project facts for deployed agents", "project facts for deployed agents"),
)


class MapError(Exception):
    """Unreadable input or an over-budget map: reported on stderr, exit 2."""


# --- small readers -------------------------------------------------------------------
def read_text(path):
    """Read a UTF-8 file; any failure is a MapError (exit 2), never a traceback."""
    try:
        with open(path, "r", encoding="utf-8", newline=None) as fh:
            return fh.read()
    except (OSError, UnicodeDecodeError) as exc:
        raise MapError("cannot read %s: %s" % (path, exc))


def list_dir(path):
    """Sorted (code point) names in a directory, or [] when it is absent."""
    if not os.path.isdir(path):
        return []
    try:
        return sorted(os.listdir(path))
    except OSError as exc:
        raise MapError("cannot list %s: %s" % (path, exc))


def frontmatter(text):
    """Return (dict of top-level `key: value` pairs, body text) for a `---` block.

    Only single-line scalars are read: this script needs `claim` and `stage` and
    nothing else, so no YAML library. Surrounding quotes are stripped.
    """
    lines = text.split("\n")
    if not lines or lines[0].strip() != "---":
        return {}, text
    meta = {}
    for i in range(1, len(lines)):
        if lines[i].strip() == "---":
            return meta, "\n".join(lines[i + 1:])
        m = re.match(r"^([A-Za-z_][A-Za-z0-9_-]*):\s*(.*?)\s*$", lines[i])
        if m:
            val = m.group(2)
            if len(val) >= 2 and val[0] == val[-1] and val[0] in "\"'":
                val = val[1:-1]
            meta[m.group(1)] = val
    return {}, text  # unterminated block: treat the file as having no frontmatter


def knowledge_files(root, below=""):
    """Every knowledge/**/*.md except README.md, as sorted relative paths."""
    base = os.path.join(root, "knowledge", below)
    found = []
    for dirpath, dirnames, filenames in os.walk(base):
        dirnames.sort()
        for name in sorted(filenames):
            if name.endswith(".md") and name != "README.md":
                found.append(os.path.join(dirpath, name))
    return sorted(found)


# --- compose configs (line-based, no YAML library) --------------------------------------
def parse_config(text):
    """Return {role: [delegates]} for one agent-factory/examples/*.yaml.

    Reads `- role: NAME` entries and the `delegates_to:` that follows, either inline
    `[a, b]` or as `- x` lines. Comments and other keys are ignored. Source order is
    not kept: callers sort, so the output never depends on how the YAML is laid out.
    """
    roles = {}
    cur = None
    in_block = False
    for raw in text.split("\n"):
        line = raw.split("#", 1)[0].rstrip()   # drop trailing comments
        if not line.strip():
            continue
        m = re.match(r"^\s*-\s+role:\s*([A-Za-z0-9_.-]+)\s*$", line)
        if m:
            cur = m.group(1)
            roles[cur] = []
            in_block = False
            continue
        if cur is None:
            continue
        m = re.match(r"^\s*delegates_to:\s*(.*)$", line)
        if m:
            rest = m.group(1).strip()
            if rest.startswith("["):
                inner = rest.strip("[]")
                roles[cur] = [x.strip() for x in inner.split(",") if x.strip()]
                in_block = False
            else:
                in_block = True
            continue
        if in_block:
            m = re.match(r"^\s*-\s+([A-Za-z0-9_.-]+)\s*$", line)
            if m:
                roles[cur].append(m.group(1))
                continue
            in_block = False
    return roles


def load_configs(root):
    """{project: {role: [delegates]}} for every agent-factory/examples/*.yaml."""
    ex = os.path.join(root, "agent-factory", "examples")
    out = {}
    for name in list_dir(ex):
        if name.endswith(".yaml"):
            out[name[:-5]] = parse_config(read_text(os.path.join(ex, name)))
    return out


def tracked_paths(root):
    """Tuple of tracked paths under root, or None when the VCS cannot say.

    None (no git, not a work tree, or nothing tracked yet) means "trust the filesystem",
    so a fresh project that is not committed yet still gets its rows.
    """
    try:
        res = subprocess.run(["git", "-C", root, "ls-files", "-z"], stdout=subprocess.PIPE,
                             stderr=subprocess.DEVNULL, check=True)
    except (OSError, subprocess.CalledProcessError):
        return None
    names = [n for n in res.stdout.decode("utf-8", "replace").split("\0") if n]
    return tuple(names) if names else None


def present(root, rel, tracked, want_file=False):
    """True when `rel` (a file, or a dir if it has tracked files below it) is in the map."""
    rel = rel.rstrip("/")
    if tracked is None:
        full = os.path.join(root, rel)
        return os.path.isfile(full) if want_file else os.path.exists(full)
    return rel in tracked or (not want_file and any(t.startswith(rel + "/") for t in tracked))


def skill_names(root, rel, tracked):
    """Names of dirs under <root>/<rel> that hold a SKILL.md, sorted."""
    base = os.path.join(root, rel)
    return [n for n in list_dir(base)
            if present(root, rel + "/" + n + "/SKILL.md", tracked, True)]


def has_sweep(root):
    """True when the gh-triage role documents a `Knowledge sweep` heading.

    The sweep is a constant of the repo's code, not of its signals, so this is stable
    across signal commits.
    """
    path = os.path.join(root, "agent-factory", "roles", "gh-triage", "AGENTS.md")
    if not os.path.isfile(path):
        return False
    return re.search(r"^#+\s+Knowledge sweep\b", read_text(path), re.M) is not None


# --- canon ---------------------------------------------------------------------------
def one_liner(text):
    """The canon line text: frontmatter `claim`, else the first body line."""
    meta, body = frontmatter(text)
    claim = meta.get("claim", "")
    if not claim:
        for ln in body.split("\n"):
            if ln.strip():
                claim = ln.strip().lstrip("#").strip()
                break
    claim = " ".join(claim.split())            # collapse all whitespace
    if len(claim) > CLAIM_MAX:
        claim = claim[:CLAIM_MAX] + "..."
    return claim


def canon_lines(root):
    """(lines, total): one `- claim (path)` per canon file, capped at CANON_MAX."""
    base = os.path.join(root, "knowledge", "canon")
    names = [n for n in list_dir(base) if n.endswith(".md") and n != "README.md"
             and os.path.isfile(os.path.join(base, n))]
    lines = ["- %s (knowledge/canon/%s)" % (one_liner(read_text(os.path.join(base, n))), n)
             for n in names[:CANON_MAX]]
    return lines, len(names)


# --- generation ----------------------------------------------------------------------
def generate(root, tracked=None):
    """Return the MAP.md text for `root`. Raises MapError over budget.

    `tracked` is tracked_paths(root); None means the filesystem decides."""
    out = ["# MAP",
           "<!-- generated by scripts/map.py - do not edit; run python3 scripts/map.py -->",
           "",
           "## Ontology",
           "",
           "### Files",
           "",
           "| Path | What | Read when |",
           "|---|---|---|"]
    for path, what, when in REGISTRY:
        # MAP.md itself is always listed: it is the file being written.
        if path == "MAP.md" or present(root, path, tracked):
            out.append("| `%s` | %s | %s |" % (path, what, when))

    configs = load_configs(root)
    if configs:
        out += ["", "### Roles", ""]
        for proj in sorted(configs):
            out.append("- %s: %s" % (proj, ", ".join(sorted(configs[proj]))))

    root_skills = skill_names(root, "skills", tracked)
    local_skills = skill_names(root, ".claude/skills", tracked)
    if root_skills or local_skills:
        out += ["", "### Skills", ""]
        if root_skills:
            out.append("- root-owned: %s" % ", ".join(root_skills))
        if local_skills:
            out.append("- project-local (.claude/skills): %s" % ", ".join(local_skills))
        if present(root, "SKILLS.md", tracked, True):
            out.append("- Full index of every skill: `SKILLS.md`")

    if os.path.isdir(os.path.join(root, "knowledge")):
        out += ["", "### Knowledge", "",
                "Entries live under `knowledge/<stage>/`; canon under `knowledge/canon/`. "
                "Entries below canon are not listed here (token cap). "
                "Counts: `python3 scripts/map.py status`."]

    out += ["", "## Topology", ""]
    deleg = []
    for proj in sorted(configs):
        for role in sorted(configs[proj]):
            if configs[proj][role]:
                deleg.append("- %s -> %s" % (role, ", ".join(sorted(configs[proj][role]))))
    if deleg:
        out += ["### Delegation", ""] + sorted(deleg) + [""]
    out += ["### Signals", "",
            "- Filing: any agent or human writes one file to `signals/` (see `signals/README.md`).",
            "- Sweep: %s" % ("`gh-triage knowledge sweep`" if has_sweep(root) else "none configured")]

    out += ["", "## Epistemology", ""]
    if os.path.isdir(os.path.join(root, "knowledge")):
        lines, total = canon_lines(root)
        out += ["### Canon", ""]
        if lines:
            out += lines
            if total > CANON_MAX:
                out.append("+%d more: knowledge/canon/" % (total - CANON_MAX))
        else:
            out.append("No canon entries yet.")
        out.append("")
    out += ["### Memory", "",
            "- **Always in context:** the learnings summary in CLAUDE.md, up to 6 instincts at "
            "session start when `learning: on`, and the canon lines above.",
            "- **On demand only:** `LEARNINGS.md` and `knowledge/` below canon. Read before "
            "relying on them; never present unread material as known."]

    text = "\n".join(out) + "\n"
    n_lines = text.count("\n")
    n_bytes = len(text.encode("utf-8"))
    if n_lines > MAX_LINES:
        raise MapError("MAP.md would be %d lines, over the %d-line limit; not written" % (n_lines, MAX_LINES))
    if n_bytes > MAX_BYTES:
        raise MapError("MAP.md would be %d bytes, over the %d-byte limit; not written" % (n_bytes, MAX_BYTES))
    return text


# --- status ----------------------------------------------------------------------------
def status(root):
    """Print stage counts, `invalid: N` if any, and pending signals. Writes nothing."""
    if not os.path.isdir(root):
        raise MapError("root is not a directory: %s" % root)
    counts = dict((s, 0) for s in STAGES)
    invalid = 0
    for path in knowledge_files(root):
        try:
            stage = frontmatter(read_text(path))[0].get("stage", "")
        except MapError:
            stage = ""              # unreadable (e.g. not UTF-8): count it invalid, keep exit 0
        if stage in counts:
            counts[stage] += 1
        else:
            invalid += 1            # missing or unknown stage: shown here, never in MAP.md
    for s in STAGES:
        print("%s: %d" % (s, counts[s]))
    if invalid:
        print("invalid: %d" % invalid)
    sig = os.path.join(root, "signals")
    # Handoffs (names starting with an arrow) and README.md are not knowledge signals.
    pending = [n for n in list_dir(sig)
               if n.endswith(".md") and n != "README.md" and not n.startswith(HANDOFF_PREFIX)
               and os.path.isfile(os.path.join(sig, n))]
    print("pending signals: %d" % len(pending))


# --- check -----------------------------------------------------------------------------
def check_drift(target, text):
    """Print why MAP.md differs from `text` and return 1; return 0 when it is current."""
    if not os.path.isfile(target):
        print("MAP.md is missing")
        print(REGEN)
        return 1
    current = read_text(target)
    if current == text:
        return 0
    print("MAP.md is stale")
    diff = list(difflib.unified_diff(current.split("\n"), text.split("\n"),
                                     "MAP.md", "generated", lineterm="", n=0))
    for ln in diff[:12]:
        print(ln)
    print(REGEN)
    return 1


def load_knowledge():
    """The scripts/knowledge.py module that sits next to this file, or None when absent.

    Loaded with importlib inside this function, not an `import` statement: map.py stays
    standard-library only (tests/test_map.bats checks its imports) and works in a project
    that has no knowledge.py. The grammar, the warrant rules and the hash routine live in
    knowledge.py alone; the lint imports them instead of carrying a second copy that could
    drift. Bytecode writing is off for the import so --check never leaves a __pycache__
    behind (it writes nothing).
    """
    here = os.path.dirname(os.path.abspath(__file__))
    if not os.path.isfile(os.path.join(here, "knowledge.py")):
        return None
    old_flag = sys.dont_write_bytecode
    sys.dont_write_bytecode = True
    sys.path.insert(0, here)
    try:
        return importlib.import_module("knowledge")
    finally:
        sys.path.remove(here)
        sys.dont_write_bytecode = old_flag


def knowledge_lint(root):
    """Lint signals/ and knowledge/ through knowledge.check_tree. Returns 1 on any finding.

    Findings print one per line as `E_<CODE> <path>: <message>` (knowledge.format_finding),
    already sorted by path then code. An unreadable linted file is a MapError (exit 2):
    the lint could not run, which is different from a finding. When there is nothing to
    lint (no knowledge.py, or neither directory) it prints one notice and returns 0, so a
    project that has not adopted the knowledge layer still passes on the drift result.
    """
    knowledge = load_knowledge()
    if knowledge is None:
        print("map.py: knowledge lint skipped (knowledge.py not found next to map.py)")
        return 0
    if not (os.path.isdir(os.path.join(root, "signals"))
            or os.path.isdir(os.path.join(root, "knowledge"))):
        print("map.py: knowledge lint skipped (no signals/ or knowledge/ directory)")
        return 0
    history_skipped = []
    try:
        findings = knowledge.check_tree(root, history_skipped)
    except knowledge.KnowledgeError as exc:      # E_READ: str(exc) is "cannot read <file>"
        raise MapError(str(exc))
    # Without git the edited-after-add check cannot run; say so once, not per signal.
    if history_skipped:
        print("map.py: signal history check skipped (git cannot answer here)")
    for finding in findings:
        print(knowledge.format_finding(finding))
    return 1 if findings else 0


# --- main ------------------------------------------------------------------------------
def parse_args(argv):
    """Return (mode, root, include_untracked). mode is 'write', 'check' or 'status'."""
    mode = "write"
    root = None
    include_untracked = False
    args = list(argv)
    if args and args[0] == "status":
        mode = "status"
        args.pop(0)
    i = 0
    while i < len(args):
        a = args[i]
        if a == "--check" and mode == "write":
            mode = "check"
        elif a == "--include-untracked":
            include_untracked = True
        elif a == "--root" and i + 1 < len(args):
            root = args[i + 1]
            i += 1
        else:
            raise MapError("usage: map.py [--check] [--include-untracked] [--root DIR] | map.py status [--root DIR] (got %r)" % a)
        i += 1
    if root is None:
        # default root: the parent of scripts/, wherever this copy lives
        root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    return mode, root, include_untracked


def main(argv):
    try:
        mode, root, include_untracked = parse_args(argv)       # validate everything before any write
        if mode == "status":
            status(root)
            return 0
        if not os.path.isdir(root):
            raise MapError("root is not a directory: %s" % root)
        text = generate(root, None if include_untracked else tracked_paths(root))
        target = os.path.join(root, "MAP.md")
        if mode == "check":
            # Drift first, then the lint: both always run so one --check shows everything
            # that is wrong, and the exit code is 1 if either found something.
            drift = check_drift(target, text)
            lint = knowledge_lint(root)
            return 1 if drift or lint else 0
        try:
            with open(target, "w", encoding="utf-8", newline="\n") as fh:
                fh.write(text)
        except OSError as exc:      # read-only root etc.: exit 2 with one line, no traceback
            raise MapError("cannot write %s: %s" % (target, exc))
        return 0
    except MapError as exc:
        print("map.py: %s" % exc, file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
