#!/usr/bin/env python3
"""build-plugins.py - generate the Claude Code plugin marketplace tree.

Input  (hand-authored): plugins/bundles.json
Output (generated, committed):
    .claude-plugin/marketplace.json
    plugins/<bundle>/.claude-plugin/plugin.json
    plugins/<bundle>/skills/<name>/...      owned skills + composed orchestrator skills
    plugins/<bundle>/agents/<name>.md       composed specialists + root-owned agents
    plugins/<bundle>/LICENSE, THIRD-PARTY-NOTICES.md   byte-identical copies of the repo root's

Never hand-edit the output: re-run this script instead.

Usage:
    build-plugins.py            write mode: render, then replace the generated tree
    build-plugins.py --check    render into memory/temp, diff against disk, write nothing

Environment:
    GRID_DIR   repo root override (default: this script's parent's parent)

Exit codes:
    0  ok (write mode: tree written; --check: tree matches)
    1  drift (--check only: a generated file is missing, extra or changed)
    2  guard or usage error (nothing is written)

Why composed output is built with the PUBLIC identity: compose.py bakes the local
operator/machine/hostname into each agent's IDENTITY nameplate. Building with
GRID_USER_CONFIG=agent-factory/user.public.yaml and no private roles makes the output
depend only on tracked files, so --check gives the same answer on every machine and a
personal nameplate can never reach the public plugin tree.

Stdlib only; the compose step is the sole consumer of the agent-factory venv.
"""
import argparse
import json
import os
import re
import shutil
import stat
import subprocess
import sys
import tempfile
from pathlib import Path

# ---- manifest schema -------------------------------------------------------
# Unknown keys are a hard error (typos must not silently drop content).
TOP_REQUIRED = {"marketplace", "version", "license", "repository", "exclude_skills", "bundles"}
MARKETPLACE_REQUIRED = {"name", "owner", "description"}
BUNDLE_REQUIRED = {"description", "skills", "compose", "agents"}
MAX_DESCRIPTION = 200  # marketplace listing budget; enforced, never truncated
# Repo-root files copied byte-identically into every bundle dir.
BUNDLE_NOTICE_FILES = ("LICENSE", "THIRD-PARTY-NOTICES.md")

# Component names become path segments, so refuse anything that could escape a dir.
NAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")
# Files never copied into the generated tree from a SOURCE dir. The disk side is NOT
# filtered (see disk_files): a committed .DS_Store under plugins/ must show up as `extra:`
# instead of letting arbitrary bytes pass --check.
IGNORED = {".DS_Store"}

# A rendered file: (bytes, is_executable). The exec bit is part of the content because
# skills may ship scripts and git tracks it.
FileSpec = tuple


class GuardError(Exception):
    """A guard or usage failure: reported, then exit 2 with nothing written."""


# ---- manifest --------------------------------------------------------------
def check_keys(obj, required, where):
    """Require obj to be a dict with exactly the `required` keys (no more, no fewer)."""
    if not isinstance(obj, dict):
        raise GuardError(f"{where}: expected an object")
    unknown = sorted(set(obj) - required)
    if unknown:
        raise GuardError(f"{where}: unknown key(s): {', '.join(unknown)}")
    missing = sorted(required - set(obj))
    if missing:
        raise GuardError(f"{where}: missing key(s): {', '.join(missing)}")


def load_manifest(grid):
    path = grid / "plugins" / "bundles.json"
    if not path.is_file():
        raise GuardError(f"manifest not found: {path}")
    try:
        m = json.loads(read_regular(path).decode("utf-8"))
    except (json.JSONDecodeError, UnicodeDecodeError) as e:
        raise GuardError(f"{path}: invalid JSON: {e}")

    check_keys(m, TOP_REQUIRED, "bundles.json")
    # exclude_skills: {skill name: one-line reason}. Every skills/<d>/SKILL.md must be in a
    # bundle or listed here, so a new root skill is never silently left out of the plugins.
    ex = m["exclude_skills"]
    if not isinstance(ex, dict):
        raise GuardError("bundles.json: 'exclude_skills' must be an object")
    bad = [str(k) for k, v in ex.items()
           if not (NAME_RE.match(k) and isinstance(v, str) and v.strip())]
    if bad:
        raise GuardError("bundles.json: 'exclude_skills' must map plain skill names to a "
                         f"non-empty reason string; bad entr(ies): {', '.join(bad)}")
    check_keys(m["marketplace"], MARKETPLACE_REQUIRED, "bundles.json marketplace")
    for k in ("version", "license", "repository"):
        if not isinstance(m[k], str) or not m[k]:
            raise GuardError(f"bundles.json: '{k}' must be a non-empty string")
    for k in MARKETPLACE_REQUIRED:
        if not isinstance(m["marketplace"][k], str) or not m["marketplace"][k]:
            raise GuardError(f"bundles.json marketplace: '{k}' must be a non-empty string")
    if not isinstance(m["bundles"], dict) or not m["bundles"]:
        raise GuardError("bundles.json: 'bundles' must be a non-empty object")

    for name, b in m["bundles"].items():
        where = f"bundle '{name}'"
        if not NAME_RE.match(name):
            raise GuardError(f"{where}: invalid bundle name")
        check_keys(b, BUNDLE_REQUIRED, where)
        if not isinstance(b["description"], str) or not b["description"]:
            raise GuardError(f"{where}: 'description' must be a non-empty string")
        if len(b["description"]) > MAX_DESCRIPTION:
            raise GuardError(
                f"{where}: description is {len(b['description'])} chars (max {MAX_DESCRIPTION})")
        for k in ("skills", "compose", "agents"):
            v = b[k]
            if not isinstance(v, list) or not all(isinstance(x, str) and NAME_RE.match(x) for x in v):
                raise GuardError(f"{where}: '{k}' must be a list of plain names")
    return m


# ---- file collection -------------------------------------------------------
def reject_odd(path):
    """Raise GuardError unless `path` is a plain file, or a dir holding only plain files and dirs.

    Symlinks (to files, dirs or nothing), FIFOs, sockets and devices are refused, at the top
    and at every depth, without ever following a link. Dereferencing a link would copy bytes
    from outside the source tree into the public tree; os.walk silently skips linked dirs;
    reading a FIFO blocks forever; rmtree cannot remove a symlinked dir.
    """
    try:
        mode = os.lstat(path).st_mode
    except OSError as e:
        raise GuardError(f"{path}: cannot stat: {e}")
    if stat.S_ISLNK(mode):
        raise GuardError(f"{path}: is a symlink (refusing to follow it)")
    if stat.S_ISREG(mode):
        return
    if not stat.S_ISDIR(mode):
        raise GuardError(f"{path}: not a regular file or directory")
    # followlinks=False: a linked dir is listed in dirnames but never descended into.
    for dirpath, dirnames, filenames in os.walk(path, followlinks=False):
        for n in dirnames + filenames:
            p = os.path.join(dirpath, n)
            m = os.lstat(p).st_mode
            if stat.S_ISLNK(m):
                raise GuardError(f"{p}: is a symlink (refusing to follow it)")
            if not (stat.S_ISREG(m) or stat.S_ISDIR(m)):
                raise GuardError(f"{p}: not a regular file or directory")


def read_regular(path):
    """Read a plain file without following a link, or raise GuardError.

    reject_odd already vetted the tree; this re-checks on the opened descriptor so a path
    swapped for a link or FIFO in between cannot be dereferenced or block (O_NOFOLLOW
    refuses links, O_NONBLOCK lets a FIFO open so fstat can reject it).
    """
    if os.path.islink(path):
        raise GuardError(f"{path}: is a symlink (refusing to follow it)")
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    except OSError as e:
        raise GuardError(f"{path}: cannot read as a plain file: {e}")
    with os.fdopen(fd, "rb") as fh:
        if not stat.S_ISREG(os.fstat(fh.fileno()).st_mode):
            raise GuardError(f"{path}: not a regular file")
        return fh.read()


def collect(root, prefix, ignore=True, tracked=None, grid=None):
    """Map every file under `root` to {posix path under `prefix`: (bytes, exec)}.

    `ignore` skips IGNORED names (source side only). Raises GuardError on any symlink or
    non-regular entry anywhere under (or at) `root`. When `tracked` (a set of grid-relative
    posix paths from git_tracked) is given, only files in it are bundled: an untracked file in
    a working tree (.env.local, __pycache__) is never copied into the public tree.
    """
    reject_odd(root)
    out = {}
    for dirpath, dirnames, filenames in os.walk(root, followlinks=False):
        dirnames.sort()
        for fn in sorted(filenames):
            if ignore and fn in IGNORED:
                continue
            p = Path(dirpath) / fn
            if tracked is not None and p.relative_to(grid).as_posix() not in tracked:
                continue
            rel = p.relative_to(root).as_posix()
            out[f"{prefix}/{rel}"] = (read_regular(p), os.access(p, os.X_OK))
    return out


def git_tracked(grid):
    """Set of grid-relative posix paths git tracks under skills/ and agents/.

    Source files are bundled from the working tree, but only if they are tracked: the build
    must not publish what a developer merely has lying around. Refuses (GuardError) when `grid`
    is not itself the top of a git work tree, so the filter can never silently turn into
    "everything". Git runs with a scrubbed environment (no GIT_DIR/GIT_INDEX_FILE redirect).
    """
    env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
    try:
        top = subprocess.run(["git", "-C", str(grid), "rev-parse", "--show-toplevel"],
                             capture_output=True, text=True, env=env)
        r = subprocess.run(["git", "-C", str(grid), "ls-files", "-z", "--", "skills", "agents"],
                           capture_output=True, env=env)
    except OSError as e:
        raise GuardError(f"cannot run git to list tracked files: {e}")
    if top.returncode != 0:
        # git itself refused (safe.directory / dubious ownership, not a repo, ...): pass its reason
        # on, since "not the top of a work tree" would send the reader to the wrong fix.
        reason = top.stderr.strip() or f"exit status {top.returncode}"
        raise GuardError(f"git cannot read {grid} (only git-tracked files are bundled, so the "
                         f"builder needs a work tree it may use): {reason}")
    if os.path.realpath(top.stdout.strip()) != os.path.realpath(grid):
        raise GuardError(f"{grid} is not the top of a git work tree: only git-tracked files "
                         "are bundled, so the builder needs one")
    if r.returncode != 0:
        raise GuardError(f"git ls-files failed: {r.stderr.decode('utf-8', 'replace').strip()}")
    return {x.decode("utf-8", "surrogateescape") for x in r.stdout.split(b"\0") if x}


def check_source_roots(grid):
    """Refuse a symlinked skills/, agents/ or agent-factory/ (an absent one is fine).

    reject_odd vets what is UNDER a source dir but never the dir's own ancestors, so a
    committed `skills -> elsewhere` link would otherwise be followed into the public tree.
    """
    for name in ("skills", "agents", "agent-factory"):
        p = grid / name
        if p.is_symlink():
            raise GuardError(f"{p}: is a symlink (refusing to follow it)")


def repos_skill_names(grid):
    """Names of every skill dir (a dir holding SKILL.md) under repos/*, at any depth.

    Returns None when no skill is found there (repos/ absent, empty, or its submodules
    uninitialised: the dirs exist but hold nothing), so the caller can say it skipped.
    """
    repos = grid / "repos"
    if not repos.is_dir():
        return None
    names = set()
    for dirpath, dirnames, filenames in os.walk(repos):
        dirnames[:] = [d for d in dirnames if d != ".git"]  # never descend into git metadata
        if "SKILL.md" in filenames and Path(dirpath) != repos:
            names.add(Path(dirpath).name)
    return names or None


# ---- compose ---------------------------------------------------------------
def run_compose(grid, project, tmp):
    """Compose one project with the neutral identity; return its _claude-code dir."""
    py = grid / "agent-factory" / ".venv" / "bin" / "python"
    user = grid / "agent-factory" / "user.public.yaml"
    cfg = grid / "agent-factory" / "examples" / f"{project}.yaml"
    if not py.is_file():
        raise GuardError(f"compose needs {py} (create it: cd agent-factory && python3 -m venv .venv "
                         "&& .venv/bin/pip install -r requirements.txt)")
    if not user.is_file():
        # Never fall back to user.yaml: that could carry a personal nameplate.
        raise GuardError(f"compose needs {user} (neutral identity); refusing to use user.yaml")
    if not cfg.is_file():
        raise GuardError(f"compose project '{project}': {cfg} not found")

    env = dict(os.environ)
    env["GRID_PRIVATE_ROLES_DIR"] = ""            # empty disables private roles entirely
    env["GRID_USER_CONFIG"] = str(user)           # neutral operator/machine/channels
    r = subprocess.run(
        [str(py), "agent-factory/compose.py", f"agent-factory/examples/{project}.yaml",
         "--target", "claude-code", "--out", str(tmp)],
        cwd=grid, env=env, capture_output=True, text=True)
    if r.returncode != 0:
        raise GuardError(f"compose of '{project}' failed (exit {r.returncode}):\n"
                         f"{r.stdout[-800:]}{r.stderr[-800:]}")
    out = tmp / project / "_claude-code"
    if not out.is_dir():
        raise GuardError(f"compose of '{project}' produced no {out}")
    return out


# ---- render ----------------------------------------------------------------
def render_bundle(grid, name, b, manifest, repo_skills, tmp, tracked):
    """Return {repo-relative path: FileSpec} for one bundle, or raise GuardError."""
    base = f"plugins/{name}"
    files = {}
    skills = {}   # skill name -> {path: FileSpec relative to skill dir prefix}
    agents = {}   # agent name -> FileSpec

    def add_skill(sname, content, origin):
        if sname in skills:
            raise GuardError(f"bundle '{name}': skill '{sname}' defined twice ({origin})")
        skills[sname] = content

    def add_agent(aname, spec, origin):
        if aname in agents:
            raise GuardError(f"bundle '{name}': agent '{aname}' defined twice ({origin})")
        agents[aname] = spec

    # Owned skills from skills/.
    for s in b["skills"]:
        d = grid / "skills" / s
        if not (d / "SKILL.md").is_file():
            raise GuardError(f"bundle '{name}': listed skill '{s}' has no {d / 'SKILL.md'}")
        if repo_skills is not None and s in repo_skills:
            raise GuardError(f"bundle '{name}': skill '{s}' also exists under repos/ "
                             "(provenance unknown); remove it from the bundle")
        content = collect(d, f"{base}/skills/{s}", tracked=tracked, grid=grid)
        if f"{base}/skills/{s}/SKILL.md" not in content:
            raise GuardError(f"bundle '{name}': skill '{s}' has no git-tracked SKILL.md "
                             "(git add it, or it would ship without one)")
        add_skill(s, content, "skills/")

    # Composed output: orchestrator skills + specialist agents.
    for p in b["compose"]:
        out = run_compose(grid, p, tmp)
        sk_root = out / "skills"
        if sk_root.is_dir():
            for d in sorted(sk_root.iterdir()):
                if d.is_dir():
                    add_skill(d.name, collect(d, f"{base}/skills/{d.name}"), f"compose {p}")
        ag_root = out / "agents"
        if ag_root.is_dir():
            for f in sorted(ag_root.glob("*.md")):
                add_agent(f.stem, (read_regular(f), os.access(f, os.X_OK)), f"compose {p}")

    # Root-owned hand-authored agents from agents/.
    for a in b["agents"]:
        f = grid / "agents" / f"{a}.md"
        if not f.is_file():
            raise GuardError(f"bundle '{name}': listed agent '{a}' has no {f}")
        if f"agents/{a}.md" not in tracked:
            raise GuardError(f"bundle '{name}': agent '{a}' is not tracked by git "
                             "(git add it, or it would not ship)")
        add_agent(a, (read_regular(f), os.access(f, os.X_OK)), "agents/")

    if not skills and not agents:
        raise GuardError(f"bundle '{name}' has no components")

    for content in skills.values():
        files.update(content)
    for aname, spec in agents.items():
        files[f"{base}/agents/{aname}.md"] = spec

    # plugin.json: only the fields the validator needs. No skills/agents/hooks/mcpServers
    # keys: components are found by directory convention (and an `agents` key is rejected).
    plugin = {
        "name": name,
        "version": manifest["version"],
        "description": b["description"],
        "author": {"name": manifest["marketplace"]["owner"]},
        "license": manifest["license"],
        "repository": manifest["repository"],
    }
    files[f"{base}/.claude-plugin/plugin.json"] = (dump_json(plugin), False)

    # Licence and third-party notice travel with every bundle (a plugin install copies only
    # its own dir, so the repo-root files would not reach the user). Byte-identical copies
    # of the root files; a missing or odd root file is a guard error, never skipped.
    for fname in BUNDLE_NOTICE_FILES:
        src = grid / fname
        if not os.path.lexists(src):
            raise GuardError(f"bundle '{name}': root file {fname} is missing ({src})")
        files[f"{base}/{fname}"] = (read_regular(src), False)
    return files


def dump_json(obj):
    """Stable serialisation: fixed key order (dict order), 2-space indent, trailing newline."""
    return (json.dumps(obj, indent=2, ensure_ascii=False) + "\n").encode("utf-8")


def render_marketplace(manifest):
    mp = manifest["marketplace"]
    doc = {
        "name": mp["name"],
        "owner": {"name": mp["owner"]},
        "metadata": {"description": mp["description"]},
        "plugins": [
            {"name": n, "source": f"./plugins/{n}", "description": b["description"],
             "version": manifest["version"]}
            for n, b in manifest["bundles"].items()
        ],
    }
    return {".claude-plugin/marketplace.json": (dump_json(doc), False)}


def check_skill_classification(grid, manifest):
    """Every skills/<d>/SKILL.md must be bundled or listed in exclude_skills (with a reason).

    Without this a new root skill is silently never shipped, and an exclusion has no recorded
    reason. Also refuses a stale exclusion (skill gone) and a skill that is both bundled and
    excluded, so the list cannot rot.
    """
    bundled = {s for b in manifest["bundles"].values() for s in b["skills"]}
    excluded = set(manifest["exclude_skills"])
    skills_dir = grid / "skills"
    on_disk = set()
    if skills_dir.is_dir():
        for d in sorted(skills_dir.iterdir()):
            if os.path.lexists(d / "SKILL.md"):
                on_disk.add(d.name)
    both = sorted(bundled & excluded)
    if both:
        raise GuardError(f"skill(s) both bundled and in exclude_skills: {', '.join(both)}")
    ghost = sorted(excluded - on_disk)
    if ghost:
        raise GuardError(f"exclude_skills names skill(s) with no skills/<name>/SKILL.md: "
                         f"{', '.join(ghost)}")
    unclassified = sorted(on_disk - bundled - excluded)
    if unclassified:
        raise GuardError(
            f"skill(s) in no bundle and not in exclude_skills: {', '.join(unclassified)} "
            "(add each to a bundle in plugins/bundles.json, or to 'exclude_skills' with a reason)")


def render(grid, manifest, tmp):
    """Render every generated file: {path: FileSpec}. Raises GuardError before any write."""
    check_source_roots(grid)   # before any source dir is read
    tracked = git_tracked(grid)
    repo_skills = repos_skill_names(grid)
    if repo_skills is None:
        print("notice: repos/ is empty; skipped the repos/ name-collision check", file=sys.stderr)
    files = {}
    for name, b in manifest["bundles"].items():
        files.update(render_bundle(grid, name, b, manifest, repo_skills, tmp, tracked))
    check_skill_classification(grid, manifest)
    files.update(render_marketplace(manifest))
    return files


# ---- disk state, check, write ----------------------------------------------
def disk_files(grid):
    """Every file the builder owns on disk: all of plugins/<dir>/** plus marketplace.json.

    Raises GuardError (never lists) when any of it is a symlink or odd file, so --check and
    write mode both refuse before anything is deleted. .DS_Store is NOT ignored here.
    """
    found = {}
    plugins = grid / "plugins"
    if plugins.is_symlink():
        raise GuardError(f"{plugins}: is a symlink (refusing to follow it)")
    if plugins.is_dir():
        for d in sorted(plugins.iterdir()):
            # lstat-based: a symlink is refused before is_dir() could follow it.
            m = os.lstat(d).st_mode
            if stat.S_ISLNK(m):
                raise GuardError(f"{d}: is a symlink (refusing to follow it)")
            if stat.S_ISDIR(m):
                found.update(collect(d, f"plugins/{d.name}", ignore=False))
            elif not stat.S_ISREG(m):  # plugins/bundles.json (a file) is input, not output
                raise GuardError(f"{d}: not a regular file or directory")
    cp = grid / ".claude-plugin"
    mp = cp / "marketplace.json"
    if cp.is_symlink():
        raise GuardError(f"{cp}: is a symlink (refusing to follow it)")
    if os.path.lexists(mp):
        reject_odd(mp)
        found[".claude-plugin/marketplace.json"] = (read_regular(mp), os.access(mp, os.X_OK))
    return found


def do_check(grid, files):
    disk = disk_files(grid)
    stale = []
    for p in sorted(set(files) | set(disk)):
        if p not in disk:
            stale.append(f"missing: {p}")
        elif p not in files:
            stale.append(f"extra:   {p}")
        elif files[p] != disk[p]:
            stale.append(f"changed: {p}")
    for line in stale:
        print(line)
    if stale:
        print(f"plugins: {len(stale)} stale path(s); run: python3 scripts/build-plugins.py",
              file=sys.stderr)
        return 1
    print("plugins: up to date")
    return 0


def do_write(grid, manifest, files):
    plugins = grid / "plugins"
    # Guard FIRST: refuse a symlinked or odd tree before the first rmtree, so a refusal can
    # never leave the generated tree half-deleted (disk_files raises GuardError, exit 2).
    disk_files(grid)
    # Replace wholesale: every bundle dir (and any stale dir for a removed bundle) is
    # deleted first so files dropped from a bundle do not linger.
    if plugins.is_dir():
        for d in plugins.iterdir():
            if d.is_dir():
                shutil.rmtree(d)
    for path, (data, is_exec) in sorted(files.items()):
        if path == ".claude-plugin/marketplace.json":
            continue  # written last, after the source-dir guard below
        write_file(grid / path, data, is_exec)

    # Guard: every marketplace entry must point at a directory that now exists.
    # `claude plugin validate` does NOT catch a dangling source, so we do.
    for n in manifest["bundles"]:
        if not (grid / "plugins" / n).is_dir():
            raise GuardError(f"marketplace entry '{n}': source dir plugins/{n} is missing")
    data, is_exec = files[".claude-plugin/marketplace.json"]
    write_file(grid / ".claude-plugin" / "marketplace.json", data, is_exec)
    print(f"plugins: wrote {len(files)} files")


def write_file(path, data, is_exec):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data)
    path.chmod(0o755 if is_exec else 0o644)


def main():
    ap = argparse.ArgumentParser(description="Generate the Claude Code plugin marketplace tree.")
    ap.add_argument("--check", action="store_true",
                    help="diff the generated tree against disk; exit 1 on drift; write nothing")
    args = ap.parse_args()  # usage errors exit 2 (argparse default)

    grid = Path(os.environ.get("GRID_DIR") or Path(__file__).resolve().parent.parent)
    try:
        manifest = load_manifest(grid)
        # Compose output lives in a temp dir that is always removed.
        with tempfile.TemporaryDirectory(prefix="build-plugins-") as t:
            files = render(grid, manifest, Path(t))
        if args.check:
            return do_check(grid, files)
        do_write(grid, manifest, files)
        return 0
    except GuardError as e:
        print(f"build-plugins: {e}", file=sys.stderr)
        return 2
    except OSError as e:
        # Exit 1 means "drift" to callers; an I/O failure (unreadable file, full disk)
        # must not masquerade as that.
        print(f"build-plugins: I/O error: {e}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
