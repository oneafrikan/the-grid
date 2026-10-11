#!/usr/bin/env python3
"""baseline_wired.py - which skills would the BASELINE wire? (used by budget.py)

    baseline_wired(grid_dir) -> list[dict] | None

Each entry is a dict with the keys
    name        the link name in the skills dir (what Claude Code lists)
    source_dir  absolute, symlink-resolved dir the link points at
    repo        "repos/<repo>" dir name, or "owned" for the root skills/ dir
    kind        "skill" (a link in .claude/skills) or "agent" (a root-owned
                agents/*.md link in .claude/agents)

How: it does NOT re-implement wire.sh's discovery (that would drift). It runs
the real wire.sh into a throwaway home and reads the symlinks it made:

  * GRID_DRY_HOME=<tmp>   wire.sh forces every home-derived target under <tmp>
                          and writes nothing into the repo or the real home.
  * GRID_HOST=__baseline__ a host with no overlay file, so the answer is the
                          baseline manifest alone (no per-machine overlay).
  * GRID_SKIP_CATALOG=1   belt and braces: never rewrite SKILLS.md.
  * GRID_BASELINE         passed through when the caller set it.

Returns None ("cannot measure here") when the baseline file is absent or any
submodule is uninitialised - the baseline is personal and gitignored, so CI and
fresh clones legitimately cannot measure it. Raises RuntimeError if wire.sh
itself fails (a broken measurement must not look like "skipped").

Stdlib only.
"""
from __future__ import annotations

import os
import shutil
import subprocess
import tempfile


def _under(path: str, root: str) -> bool:
    """True when `path` is `root` or lives below it (both already realpath'd)."""
    return path == root or path.startswith(root + os.sep)


def baseline_wired(grid_dir: str):
    grid = os.path.realpath(grid_dir)

    # 1. Is there a baseline to measure? GRID_BASELINE wins over the default file.
    baseline = os.environ.get("GRID_BASELINE") or os.path.join(
        grid, "baseline-submodules.txt"
    )
    if not os.path.isfile(baseline):
        return None

    # 2. Any uninitialised submodule ("-<sha> path" line) means the skill set on
    #    disk is incomplete, so a measurement would under-count. Not a git repo
    #    (a mock grid in tests) prints nothing and counts as "all initialised".
    env = {k: v for k, v in os.environ.items()
           if k not in ("GIT_INDEX_FILE", "GIT_DIR", "GIT_WORK_TREE",
                        "GIT_PREFIX", "GIT_EXEC_PATH")}
    sub = subprocess.run(
        ["git", "-C", grid, "submodule", "status"],
        capture_output=True, text=True, env=env,
    )
    if any(line.startswith("-") for line in sub.stdout.splitlines()):
        return None

    # 3. Run the real wire.sh into a throwaway home.
    tmp = tempfile.mkdtemp(prefix="grid-budget-")
    try:
        wire_env = dict(env)
        wire_env.update({
            "GRID_DRY_HOME": tmp,
            "GRID_SKIP_CATALOG": "1",
            "GRID_HOST": "__baseline__",
            "GRID_DIR": grid,
        })
        # No SKILLS_DIR / AGENTS_DIR override: GRID_DRY_HOME forces them.
        if os.environ.get("GRID_BASELINE"):
            wire_env["GRID_BASELINE"] = os.environ["GRID_BASELINE"]
        run = subprocess.run(
            ["bash", os.path.join(grid, "scripts", "wire.sh")],
            capture_output=True, text=True, env=wire_env,
        )
        if run.returncode != 0:
            raise RuntimeError("wire.sh failed during baseline measurement:\n"
                               + run.stdout + run.stderr)

        projects = os.path.join(grid, "agent-factory", "projects")
        repos = os.path.join(grid, "repos")
        owned = os.path.join(grid, "skills")
        entries = []

        # 4a. Skills dir. Each link is a skill dir, except the gstack-style
        #     runtime-root link (link -> repos/<r> itself), which is not a skill
        #     dir but which Claude Code still lists from repos/<r>/SKILL.md.
        sdir = os.path.join(tmp, ".claude", "skills")
        for name in sorted(os.listdir(sdir)) if os.path.isdir(sdir) else []:
            link = os.path.join(sdir, name)
            if not os.path.islink(link):
                continue
            target = os.path.realpath(link)
            if _under(target, projects):          # composed roles: counted from source
                continue
            if os.path.dirname(target) == repos:  # runtime-root link -> repos/<r>
                if not os.path.isfile(os.path.join(target, "SKILL.md")):
                    continue                       # nothing to list
                entries.append({"name": name, "source_dir": target,
                                "repo": os.path.basename(target), "kind": "skill"})
                continue
            if not os.path.isdir(target):          # dangling
                continue
            if _under(target, repos):
                repo = os.path.relpath(target, repos).split(os.sep)[0]
            elif _under(target, owned):
                repo = "owned"
            else:
                continue                           # not ours
            entries.append({"name": name, "source_dir": target,
                            "repo": repo, "kind": "skill"})

        # 4b. Agents dir: composed agents are ignored (counted from role source);
        #     what is left is root-owned agents/*.md.
        adir = os.path.join(tmp, ".claude", "agents")
        for name in sorted(os.listdir(adir)) if os.path.isdir(adir) else []:
            link = os.path.join(adir, name)
            if not os.path.islink(link):
                continue
            target = os.path.realpath(link)
            if _under(target, projects) or not os.path.isfile(target):
                continue
            entries.append({"name": name, "source_dir": target,
                            "repo": "owned", "kind": "agent"})
        return entries
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":  # tiny CLI for debugging: prints one name per line
    import sys
    result = baseline_wired(sys.argv[1] if len(sys.argv) > 1 else ".")
    if result is None:
        print("baseline not measurable here", file=sys.stderr)
        sys.exit(3)
    for e in result:
        print(e["kind"], e["name"], e["repo"])
