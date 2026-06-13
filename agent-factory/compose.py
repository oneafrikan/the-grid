#!/usr/bin/env python3
"""compose.py — the agent-factory engine.

Composes an AI dev team from three orthogonal inputs (role × stack × skills)
described in a compose config (yaml), and writes one ready-to-run agent folder
per team member under projects/<project>/.

Flow:
    compose config (yaml)  ->  resolve + validate roles/stacks/skills
    ->  render templates    ->  write projects/<project>/<role>/{SOUL,SKILL,MEMORY}.md
                                + projects/<project>/agents.yaml

Render model:
    SOUL.md   = _core/SOUL_base.md   merged with roles/<role>/SOUL.md
    SKILL.md  = roles/<role>/SKILL.md + stacks/<stack>/ overlay(s) appended
    MEMORY.md = _core/MEMORY_base.md merged with roles/<role>/MEMORY.md
    agents.yaml = _core/agents_base.yaml + per-agent entries from the config

    "Merged" = section-aware: shared level-2 (`## `) headings unify under one
    heading (base body first, then the role's seed); headings unique to either
    side are kept in order (base sections first, then role-only sections). This
    is why role templates reuse the base headings — so the merge reads as a
    single clean document, not two concatenated ones.

Runtime target is Claude Code + ACP (swappable coding CLI); rendered content
stays LCD. Memory is a flat-file seed for now (gbrain swap is a later phase).

Usage:
    .venv/bin/python compose.py path/to/compose.yaml [--out projects/] [--dry-run]

Requires PyYAML — install into the project venv:
    python3 -m venv .venv && .venv/bin/pip install -r requirements.txt
"""

from __future__ import annotations

import argparse
import shutil
import sys
from pathlib import Path

try:
    import yaml
except ModuleNotFoundError:
    sys.exit(
        "compose.py needs PyYAML. Create the project venv and install it:\n"
        "  python3 -m venv .venv && .venv/bin/pip install -r requirements.txt\n"
        "then run:  .venv/bin/python compose.py <config.yaml>"
    )

HERE = Path(__file__).resolve().parent
ROLES_DIR = HERE / "roles"
STACKS_DIR = HERE / "stacks"
SKILLS_DIR = HERE / "skills"
CORE_DIR = HERE / "_core"
PROJECTS_DIR = HERE / "projects"

# Files a fully-populated role provides. SKILL.md is mandatory (it is the
# operating manual); SOUL.md / MEMORY.md merge with the _core base if present.
ROLE_SOUL = "SOUL.md"
ROLE_SKILL = "SKILL.md"
ROLE_MEMORY = "MEMORY.md"


# ── markdown section-aware merge ──────────────────────────────────────────────

def split_sections(md: str) -> tuple[str, list[tuple[str, str]]]:
    """Split markdown into (preamble, [(heading_line, body), ...]).

    Section boundaries are level-2 headings (lines starting with "## ").
    Everything before the first such heading — including any "# " title and
    leading HTML comments — is the preamble.
    """
    preamble: list[str] = []
    sections: list[list] = []  # [[heading, [body lines]], ...]
    current: list | None = None
    for line in md.splitlines():
        if line.startswith("## "):
            current = [line, []]
            sections.append(current)
        elif current is None:
            preamble.append(line)
        else:
            current[1].append(line)
    return (
        "\n".join(preamble),
        [(heading, "\n".join(body)) for heading, body in sections],
    )


def merge_layered(base_md: str, role_md: str) -> str:
    """Merge a base template with a role template, section by section.

    Shared "## " headings unify under one heading (base body, then role body).
    Base-only sections come first (in base order); role-only sections are
    appended after (in role order). Both preambles are kept — the dual title
    documents the layering and the files are HTML-comment heavy anyway.
    """
    base_pre, base_secs = split_sections(base_md)
    role_pre, role_secs = split_sections(role_md)
    role_bodies = dict(role_secs)

    blocks: list[str] = []
    if base_pre.strip():
        blocks.append(base_pre.rstrip())
    if role_pre.strip():
        blocks.append(role_pre.rstrip())

    merged_headings: set[str] = set()
    for heading, body in base_secs:
        parts = [heading]
        if body.strip():
            parts.append(body.rstrip())
        if heading in role_bodies:
            role_body = role_bodies[heading]
            if role_body.strip():
                parts.append(role_body.rstrip())
            merged_headings.add(heading)
        blocks.append("\n".join(parts))

    for heading, body in role_secs:
        if heading in merged_headings:
            continue
        parts = [heading]
        if body.strip():
            parts.append(body.rstrip())
        blocks.append("\n".join(parts))

    return "\n\n".join(blocks) + "\n"


# ── config loading + validation ───────────────────────────────────────────────

def _read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def load_config(path: Path) -> dict:
    """Parse a compose config and validate it against the factory contract.

    Validates the shape documented in factory.schema.yaml: required top-level
    keys, required per-agent keys, and that every referenced role / stack /
    skill resolves to an existing directory. Raises ValueError on any problem,
    accumulating all errors so the operator sees them in one pass.
    """
    if not path.is_file():
        raise ValueError(f"compose config not found: {path}")

    config = yaml.safe_load(_read(path)) or {}
    if not isinstance(config, dict):
        raise ValueError("compose config must be a YAML mapping at the top level")

    errors: list[str] = []

    # Top-level required keys.
    for key in ("project", "agents"):
        if key not in config:
            errors.append(f"missing required top-level key: {key}")

    agents = config.get("agents")
    if agents is not None and not isinstance(agents, list):
        errors.append("`agents` must be a list")
        agents = None

    for i, agent in enumerate(agents or []):
        where = f"agents[{i}]"
        if not isinstance(agent, dict):
            errors.append(f"{where}: each agent must be a mapping")
            continue

        role = agent.get("role")
        if not role:
            errors.append(f"{where}: missing required key: role")
        else:
            role_dir = ROLES_DIR / role
            if not role_dir.is_dir():
                errors.append(f"{where}: role '{role}' has no dir at {role_dir}")
            elif not (role_dir / ROLE_SKILL).is_file():
                errors.append(
                    f"{where}: role '{role}' has no {ROLE_SKILL} "
                    f"(the operating manual is mandatory)"
                )

        for stack in agent.get("stacks", []) or []:
            if not (STACKS_DIR / stack).is_dir():
                errors.append(f"{where}: stack '{stack}' has no dir at {STACKS_DIR / stack}")

        for skill in agent.get("skills", []) or []:
            if not (SKILLS_DIR / skill).is_dir():
                errors.append(f"{where}: skill '{skill}' has no dir at {SKILLS_DIR / skill}")

    if errors:
        raise ValueError("invalid compose config:\n  - " + "\n  - ".join(errors))

    return config


# ── rendering ─────────────────────────────────────────────────────────────────

def render_stack_overlay(stacks: list[str]) -> str:
    """Build the stack overlay appended to a role's SKILL.md.

    Phase-1: append each stack's summary plus the contents of any fragment
    files it declares (ordered). The inline `<!-- STACK: ... -->` markers in the
    role SKILL.md are left in place as documentation; keyed inline injection at
    those exact points is a later upgrade (TODO) — until then the overlay is a
    clearly-labelled trailing section, which is honest about what is injected.
    """
    if not stacks:
        return ""

    sections = ["", "---", "", "## Stack overlays", ""]
    for stack in stacks:
        meta = yaml.safe_load(_read(STACKS_DIR / stack / "stack.yaml")) or {}
        summary = (meta.get("summary") or "").strip()
        sections.append(f"### {meta.get('name', stack)}")
        if summary:
            sections.append("")
            sections.append(summary)
        for fragment in meta.get("fragments", []) or []:
            frag_path = STACKS_DIR / stack / fragment
            if frag_path.is_file():
                sections.append("")
                sections.append(_read(frag_path).rstrip())
        sections.append("")
    return "\n".join(sections)


def render_agent(agent: dict) -> dict[str, str]:
    """Render one agent's files. Returns {filename: contents}."""
    role = agent["role"]
    role_dir = ROLES_DIR / role
    stacks = agent.get("stacks", []) or []

    rendered: dict[str, str] = {}

    # SOUL = base merged with role layer (role SOUL optional).
    base_soul = _read(CORE_DIR / "SOUL_base.md")
    role_soul_path = role_dir / ROLE_SOUL
    role_soul = _read(role_soul_path) if role_soul_path.is_file() else ""
    rendered[ROLE_SOUL] = merge_layered(base_soul, role_soul) if role_soul else base_soul

    # SKILL = role operating manual + stack overlay(s). No base SKILL exists.
    rendered[ROLE_SKILL] = _read(role_dir / ROLE_SKILL).rstrip() + "\n" + render_stack_overlay(stacks)

    # MEMORY = base seed merged with role seed (role MEMORY optional).
    base_memory = _read(CORE_DIR / "MEMORY_base.md")
    role_memory_path = role_dir / ROLE_MEMORY
    role_memory = _read(role_memory_path) if role_memory_path.is_file() else ""
    rendered[ROLE_MEMORY] = merge_layered(base_memory, role_memory) if role_memory else base_memory

    return rendered


def resolve_model(agent: dict) -> str:
    """Model precedence: compose config > role.yaml default_model > 'sonnet'."""
    if agent.get("model"):
        return agent["model"]
    role_yaml = ROLES_DIR / agent["role"] / "role.yaml"
    if role_yaml.is_file():
        meta = yaml.safe_load(_read(role_yaml)) or {}
        if meta.get("default_model"):
            return meta["default_model"]
    return "sonnet"


def render_agents_yaml(config: dict) -> str:
    """Render the project-level agents.yaml from the _core base + config."""
    base = yaml.safe_load(_read(CORE_DIR / "agents_base.yaml")) or {}

    base["project"] = config["project"]
    if config.get("description"):
        base["description"] = config["description"]
    base["paperclip"] = bool(config.get("paperclip", False))

    base["agents"] = [
        {
            "id": agent["role"],          # one agent per role for now
            "role": agent["role"],
            "model": resolve_model(agent),
            "stacks": agent.get("stacks", []) or [],
            "skills": agent.get("skills", []) or [],
            "workspace": f"./{agent['role']}",
        }
        for agent in config["agents"]
    ]

    header = (
        "# agents.yaml — GENERATED by compose.py. Do not edit by hand.\n"
        f"# Project: {config['project']}\n"
        "# Re-run compose.py to regenerate.\n\n"
    )
    return header + yaml.safe_dump(base, sort_keys=False, default_flow_style=False)


# ── writing ───────────────────────────────────────────────────────────────────

def write_project(name: str, config: dict, out_dir: Path) -> Path:
    """Write the rendered team under <out_dir>/<name>/. Idempotent.

    The project dir is generated output (agents write their runtime artefacts
    elsewhere, to output/<project>/), so it is wiped and rewritten each run —
    the result reflects the config exactly, and a re-run with an unchanged
    config produces byte-identical files. The wipe is guarded to a real
    directory under out_dir (never a symlink) for safety.
    """
    project_dir = out_dir / name
    if project_dir.is_symlink():
        raise ValueError(f"refusing to write: {project_dir} is a symlink, not a dir")
    if project_dir.exists():
        shutil.rmtree(project_dir)
    project_dir.mkdir(parents=True)

    for agent in config["agents"]:
        agent_dir = project_dir / agent["role"]
        agent_dir.mkdir()
        for filename, contents in render_agent(agent).items():
            (agent_dir / filename).write_text(contents, encoding="utf-8")

    (project_dir / "agents.yaml").write_text(render_agents_yaml(config), encoding="utf-8")
    return project_dir


# ── cli ───────────────────────────────────────────────────────────────────────

def main() -> None:
    parser = argparse.ArgumentParser(description="Compose an AI dev team.")
    parser.add_argument("config", type=Path, help="path to the compose config yaml")
    parser.add_argument("--out", type=Path, default=PROJECTS_DIR, help="output dir")
    parser.add_argument(
        "--dry-run", action="store_true",
        help="render + report what would be written, but write nothing",
    )
    args = parser.parse_args()

    try:
        config = load_config(args.config)
    except ValueError as exc:
        sys.exit(str(exc))

    name = config["project"]
    agents = config["agents"]

    if args.dry_run:
        print(f"[dry-run] project: {name}  ({len(agents)} agents) -> {args.out / name}")
        for agent in agents:
            files = ", ".join(sorted(render_agent(agent)))
            print(f"  - {agent['role']:<16} model={resolve_model(agent):<8} files: {files}")
        print("[dry-run] + agents.yaml")
        return

    project_dir = write_project(name, config, args.out)
    print(f"composed '{name}': {len(agents)} agents -> {project_dir}")
    for agent in agents:
        print(f"  - {agent['role']} ({resolve_model(agent)})")


if __name__ == "__main__":
    main()
