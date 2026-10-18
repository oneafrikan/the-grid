#!/usr/bin/env python3
"""Format validators for generated harness artefacts (change `multi-harness`).

Usage:  validate_harness.py <subcommand> FILE...

Each subcommand checks files against ONE harness's documented format, so a vendor-doc
change means editing the one checker here (the vendor facts are in docs/harnesses.md).
Stdlib only: the bats tests run it with the system python3, not the agent-factory venv.

Exit codes: 0 every file passed,
            1 at least one file failed, 2 bad usage,
            3 the check could not run (a `requires` reason, e.g. no tomllib): not a pass, so
              a caller must skip on its own first, as the .bats files do (R16.qa.F13).

Extending: later harness groups add their checker by writing a function that takes a
Path and returns a list of problem strings (empty = valid), and decorating it with
@command("<name>"). Nothing else in this file needs to change.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path
from typing import Callable

# subcommand name -> (checker, requires). `requires()` returns None when the check can run,
# or a one-line reason when it cannot run.
COMMANDS: dict[str, tuple[Callable[[Path], list[str]], Callable[[], str | None]]] = {}


def command(name: str, requires: Callable[[], str | None] = lambda: None):
    """Register a checker under `name`. When `requires()` returns a reason, the run prints
    a notice and exits 3, distinct from a pass (e.g. an interpreter too old for a module)."""
    def register(fn: Callable[[Path], list[str]]):
        COMMANDS[name] = (fn, requires)
        return fn
    return register


# ── codex-agent ──────────────────────────────────────────────────────────────
def _needs_tomllib() -> str | None:
    """tomllib is stdlib from Python 3.11; older interpreters report "cannot run" (exit 3)."""
    try:
        import tomllib  # noqa: F401
    except ImportError:
        return "tomllib unavailable (Python < 3.11)"
    return None


CODEX_SANDBOX_MODES = {"read-only", "workspace-write", "danger-full-access"}


@command("codex-agent", requires=_needs_tomllib)
def check_codex_agent(path: Path) -> list[str]:
    """A Codex subagent file: valid TOML whose `name`, `description` and
    `developer_instructions` are non-empty strings (the three keys Codex requires)."""
    import tomllib
    try:
        with path.open("rb") as fh:
            data = tomllib.load(fh)
    except (OSError, tomllib.TOMLDecodeError) as exc:
        return [f"not valid TOML: {exc}"]
    problems = []
    for key in ("name", "description", "developer_instructions"):
        value = data.get(key)
        if not isinstance(value, str) or not value.strip():
            problems.append(f"missing or non-string required key: {key}")
    # The three values Codex documents; anything else (a typo, "yolo") is not a sandbox.
    if "sandbox_mode" in data and data["sandbox_mode"] not in CODEX_SANDBOX_MODES:
        problems.append(f"sandbox_mode {data['sandbox_mode']!r} must be one of "
                        f"{', '.join(sorted(CODEX_SANDBOX_MODES))}")
    return problems


# ── opencode-agent ───────────────────────────────────────────────────────────
# Frontmatter reading reuses scripts/lib/skill_frontmatter.py (stdlib only, the same reader
# wire.sh uses), loaded by path because `python3 -I` puts neither this dir nor PYTHONPATH on
# sys.path.
def _frontmatter_reader():
    import importlib.util
    path = Path(__file__).resolve().parents[2] / "scripts" / "lib" / "skill_frontmatter.py"
    spec = importlib.util.spec_from_file_location("skill_frontmatter", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


# The values OpenCode accepts for a permission key (opencode.ai/docs/agents).
OPENCODE_PERMISSION_VALUES = {"ask", "allow", "deny"}
# The permission keys this repo's emitter can write (docs/harnesses.md). Extend with the emitter.
OPENCODE_PERMISSION_KEYS = {"edit", "bash", "webfetch"}
# Frontmatter keys an OpenCode agent file may carry (docs/harnesses.md vendor table).
OPENCODE_AGENT_KEYS = {"description", "mode", "model", "temperature", "permission"}


@command("opencode-agent")
def check_opencode_agent(path: Path) -> list[str]:
    """An OpenCode subagent file: a leading frontmatter block with a non-empty `description`
    and `mode: subagent`; only known top-level keys; a `permission:` block map (not flow
    style), when present, holds only known keys with ask/allow/deny values."""
    fm_mod = _frontmatter_reader()
    lines = fm_mod.frontmatter_lines(str(path))
    if lines is None:
        return ["no frontmatter block"]
    problems = []
    if not fm_mod.scalar(lines, "description").strip():
        problems.append("missing or empty frontmatter key: description")
    mode = fm_mod.scalar(lines, "mode")
    if mode != "subagent":
        problems.append(f"mode must be 'subagent', got {mode!r}")
    for line in lines:   # top-level keys are the unindented `key:` lines
        m = re.match(r"([^\s:#][^:]*):", line)
        if m and m.group(1) not in OPENCODE_AGENT_KEYS:
            problems.append(f"unknown frontmatter key {m.group(1)!r}")
    # The permission block is the indented lines after a top-level `permission:`.
    in_perm = False
    for line in lines:
        if line.startswith("permission:"):
            if line.split(":", 1)[1].strip():
                # `permission: {edit: yolo}` and friends: this repo writes block maps only, and a
                # flow map would slip past the per-key checks below.
                problems.append("permission must be a block map, not an inline value")
            in_perm = True
            continue
        if in_perm:
            if line.strip() and line[0] not in " \t":
                break   # next top-level key
            if line.strip():
                key, _, value = line.strip().partition(":")
                if key not in OPENCODE_PERMISSION_KEYS:
                    problems.append(f"unknown permission key {key!r}")
                if value.strip() not in OPENCODE_PERMISSION_VALUES:
                    problems.append(f"permission {key!r} has invalid value {value.strip()!r}")
    return problems


# ── skill ────────────────────────────────────────────────────────────────────
# Agent Skills format as OpenCode enforces it (the strictest reader of the shared dir):
# the dir name matches a lowercase-hyphen regex and is at most 64 chars, the frontmatter
# `name` equals the dir name, and the description is 1 to 1024 chars.
SKILL_NAME_RE = re.compile(r"^[a-z0-9]+(-[a-z0-9]+)*$")


@command("skill")
def check_skill(path: Path) -> list[str]:
    """A skill directory (or a symlink to one, as wired into the shared skills dir).

    `path.name` is deliberately NOT resolved: the harness sees the link's name, and that is
    the name that must match the frontmatter."""
    skill_md = path / "SKILL.md"
    if not skill_md.is_file():
        return ["no SKILL.md"]
    problems = []
    dirname = path.name
    if len(dirname) > 64 or not SKILL_NAME_RE.match(dirname):
        problems.append(f"dir name {dirname!r} must match {SKILL_NAME_RE.pattern} and be at most 64 chars")
    fm_mod = _frontmatter_reader()
    lines = fm_mod.frontmatter_lines(str(skill_md))
    if lines is None:
        return problems + ["no frontmatter block"]
    name = fm_mod.scalar(lines, "name")
    if name != dirname:
        problems.append(f"frontmatter name {name!r} must equal the dir name {dirname!r}")
    desc = fm_mod.scalar(lines, "description")
    if not 1 <= len(desc) <= 1024:
        problems.append(f"description must be 1 to 1024 chars, got {len(desc)}")
    return problems


# ── gemini-agent ─────────────────────────────────────────────────────────────
# (group 5) Reuses the frontmatter reader above.
# The Gemini tool names agent-factory/compose.py GEMINI_TOOLS maps to (stdlib only here, so it
# cannot import compose). tests/test_harness_formats.bats fails if the two lists drift apart.
GEMINI_TOOL_NAMES = {"read_file", "read_many_files", "grep_search", "glob", "list_directory",
                     "run_shell_command", "replace", "write_file", "web_fetch", "google_web_search"}


@command("gemini-agent")
def check_gemini_agent(path: Path) -> list[str]:
    """A Gemini CLI subagent file: a `---` frontmatter block whose `name` matches
    ^[a-z0-9_-]+$ and whose `description` is non-empty. Also (the-grid's own contract, not a
    Gemini rule): `tools`, when present, is a block list of non-empty items (not Claude's
    comma string), and there is no `model` key (the role's model is never pinned)."""
    fm = _frontmatter_reader()
    lines = fm.frontmatter_lines(str(path))
    if lines is None:
        return ["no `---` frontmatter block"]
    problems = []
    name = fm.scalar(lines, "name")
    if not re.fullmatch(r"[a-z0-9_-]+", name):
        problems.append(f"name {name!r} does not match ^[a-z0-9_-]+$")
    if not fm.scalar(lines, "description").strip():
        problems.append("description is empty")
    top = [ln for ln in lines if ln and ln[0] not in " \t"]
    if any(re.match(r"model\s*:", ln) for ln in top):
        problems.append("model must not be set")
    for i, ln in enumerate(lines):
        if re.match(r"tools\s*:", ln):
            items = []
            for nxt in lines[i + 1:]:
                m = re.match(r"^\s*-\s+(\S.*)$", nxt)
                if not m:
                    break
                items.append(m.group(1))
            # `tools:` with text after it (a string / inline list) or with no items is not
            # the block list this repo writes.
            if ln.split(":", 1)[1].strip() or not items:
                problems.append("tools must be a non-empty YAML block list")
            for item in items:
                if item not in GEMINI_TOOL_NAMES:
                    problems.append(f"tool {item!r} is not a Gemini CLI tool name this repo maps")
    # The Markdown body is the system prompt: a file with nothing after the frontmatter has none.
    m = re.match(r"---[ \t]*\n.*?\n---[ \t]*\n(.*)\Z", path.read_text(encoding="utf-8"), re.S)
    if m is None or not m.group(1).strip():
        problems.append("no body after the frontmatter (the body is the system prompt)")
    return problems


# ── driver ───────────────────────────────────────────────────────────────────
def main(argv: list[str]) -> int:
    if len(argv) < 3 or argv[1] not in COMMANDS:
        print(f"usage: {Path(argv[0]).name} <{'|'.join(sorted(COMMANDS))}> FILE...", file=sys.stderr)
        return 2
    checker, requires = COMMANDS[argv[1]]
    skip = requires()
    if skip:
        print(f"{argv[1]}: cannot run, {skip}")
        return 3
    failed = False
    for name in argv[2:]:
        path = Path(name)
        if not path.exists():
            problems = ["no such file"]
        elif path.is_dir() and argv[1] != "skill":   # `skill` takes dirs; the agent checkers take files
            problems = ["is a directory, expected a file"]
        else:
            problems = checker(path)
        for problem in problems:
            print(f"{name}: {problem}", file=sys.stderr)
            failed = True
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
