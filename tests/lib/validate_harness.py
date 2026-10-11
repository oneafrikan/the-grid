#!/usr/bin/env python3
"""Format validators for generated harness artefacts (change `multi-harness`).

Usage:  validate_harness.py <subcommand> FILE...

Each subcommand checks files against ONE harness's documented format, so a vendor-doc
change means editing the one checker here (the vendor facts are in docs/harnesses.md).
Stdlib only: the bats tests run it with the system python3, not the agent-factory venv.

Exit codes: 0 every file passed (or the check was skipped, see `requires`),
            1 at least one file failed, 2 bad usage.

Extending: later harness groups add their checker by writing a function that takes a
Path and returns a list of problem strings (empty = valid), and decorating it with
@command("<name>"). Nothing else in this file needs to change.
"""
from __future__ import annotations

import sys
from pathlib import Path
from typing import Callable

# subcommand name -> (checker, requires). `requires()` returns None when the check can run,
# or a one-line reason when it must be skipped.
COMMANDS: dict[str, tuple[Callable[[Path], list[str]], Callable[[], str | None]]] = {}


def command(name: str, requires: Callable[[], str | None] = lambda: None):
    """Register a checker under `name`. When `requires()` returns a reason, the run prints
    a skip notice and exits 0 instead of failing (e.g. an interpreter too old for a module)."""
    def register(fn: Callable[[Path], list[str]]):
        COMMANDS[name] = (fn, requires)
        return fn
    return register


# ── codex-agent ──────────────────────────────────────────────────────────────
def _needs_tomllib() -> str | None:
    """tomllib is stdlib from Python 3.11; older interpreters skip rather than fail."""
    try:
        import tomllib  # noqa: F401
    except ImportError:
        return "tomllib unavailable (Python < 3.11)"
    return None


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
    return problems


# ── driver ───────────────────────────────────────────────────────────────────
def main(argv: list[str]) -> int:
    if len(argv) < 3 or argv[1] not in COMMANDS:
        print(f"usage: {Path(argv[0]).name} <{'|'.join(sorted(COMMANDS))}> FILE...", file=sys.stderr)
        return 2
    checker, requires = COMMANDS[argv[1]]
    skip = requires()
    if skip:
        print(f"{argv[1]}: skipped, {skip}")
        return 0
    failed = False
    for name in argv[2:]:
        path = Path(name)
        problems = checker(path) if path.is_file() else ["no such file"]
        for problem in problems:
            print(f"{name}: {problem}", file=sys.stderr)
            failed = True
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
