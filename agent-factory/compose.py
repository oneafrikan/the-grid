#!/usr/bin/env python3
"""compose.py — the agent-factory engine.

STUB. Not yet functional. Signatures + flow are sketched so the mechanics are
agreed before any real rendering logic lands. Each TODO is a future work item.

Flow:
    compose config (yaml)  ->  resolve roles/stacks/skills  ->  render templates
    ->  write projects/<project>/<role>/{SOUL,SKILL,MEMORY}.md + agents.yaml

Render model (planned):
    SOUL.md   = _core/SOUL_base.md   + roles/<role>/SOUL.md
    SKILL.md  = roles/<role>/SKILL.md with stacks/<stack>/ fragments injected
    MEMORY.md = _core/MEMORY_base.md + roles/<role>/MEMORY.md (flat-file seed;
                gbrain swap is a later phase — keep this dumb for now)
    agents.yaml = _core/agents_base.yaml rendered per the compose config

Usage (planned):
    python compose.py path/to/compose.yaml [--out projects/] [--dry-run]
"""

from __future__ import annotations

import argparse
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROLES_DIR = HERE / "roles"
STACKS_DIR = HERE / "stacks"
SKILLS_DIR = HERE / "skills"
CORE_DIR = HERE / "_core"
PROJECTS_DIR = HERE / "projects"


def load_config(path: Path) -> dict:
    """Parse + validate a compose config against factory.schema.yaml."""
    # TODO: yaml.safe_load + validate required keys, resolve refs to dirs.
    raise NotImplementedError("compose config loading not implemented yet")


def render_agent(agent: dict, paperclip: bool) -> dict[str, str]:
    """Render one agent's files. Returns {filename: contents}."""
    # TODO: merge _core base + role template, inject stack overlays, append
    #       skills, fill MEMORY seed. Keep handoff section dual-mode
    #       (sessions_spawn + PR/webhook). Target = Claude Code + ACP (LCD).
    raise NotImplementedError("agent rendering not implemented yet")


def write_project(name: str, rendered: dict[str, dict[str, str]]) -> Path:
    """Write rendered agents under projects/<name>/. Idempotent overwrite."""
    # TODO: emit per-role folders + top-level agents.yaml. Safe to re-run.
    raise NotImplementedError("project writing not implemented yet")


def main() -> None:
    parser = argparse.ArgumentParser(description="Compose an AI dev team.")
    parser.add_argument("config", type=Path, help="path to the compose config yaml")
    parser.add_argument("--out", type=Path, default=PROJECTS_DIR, help="output dir")
    parser.add_argument("--dry-run", action="store_true", help="render but don't write")
    args = parser.parse_args()

    # TODO: load_config -> for each agent render_agent -> write_project.
    raise SystemExit("compose.py is a stub — engine not implemented yet")


if __name__ == "__main__":
    main()
