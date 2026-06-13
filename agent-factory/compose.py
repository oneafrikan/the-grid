#!/usr/bin/env python3
"""compose.py — the agent-factory engine.

Composes an AI dev-team agent from three orthogonal inputs (role × stack ×
skills) described in a compose config (yaml), and writes one ready-to-run agent
folder per team member under projects/<project>/.

The agent shape is the live OpenClaw 5-file identity model + a skill list:

    SOUL.md      how it behaves        (personality, voice — stack-agnostic)
    IDENTITY.md  who it is             (nameplate: name, role, model, machine)
    AGENTS.md    how it operates       (boot sequence, roster, async handoff)
    USER.md      who it serves         (operator + team)
    MEMORY.md    what it carries       (durable knowledge; flat now, gbrain later)
    + skills:    what it can do        (SKILL.md capability folders, by name)

Render model:
    SOUL/AGENTS/USER/MEMORY = _core/<X>_base.md merged section-by-section with
        roles/<role>/<X>.md. Shared level-2 (`## `) headings unify under one
        heading (base body first, then role seed); unique sections kept in order.
    IDENTITY = _core/IDENTITY_base.md token-substituted ({{name}}, {{role}},
        {{model}}, {{cron_model}}) + roles/<role>/IDENTITY.md appended.
    skills = the role's own operating skill (named after the role) + any bolt-on
        skills from the config, listed by name in agents.yaml (OpenClaw wires
        skills by name from a shared skills dir — they are not copied per agent).
    agents.yaml = _core/agents_base.yaml + per-agent entries from the config.

A role's procedural operating manual lives in roles/<role>/SKILL.md — that IS the
role's skill (capability), distinct from the 5 identity files. It is required to
exist (a role must DO something) but is referenced by name, not emitted here.

Runtime target is Claude Code + ACP (swappable CLI); content stays LCD. Handoff
is async (signal files / PR+webhook), not live spawn.

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

# The 5 identity files emitted per agent, each = a _core base merged/filled with
# the role layer. (SKILL.md is the role's *skill*, referenced by name — not here.)
IDENTITY_FILES = ["SOUL.md", "IDENTITY.md", "AGENTS.md", "USER.md", "MEMORY.md"]

# Files a role MUST provide: a personality and something to do.
REQUIRED_ROLE_FILES = ["SOUL.md", "SKILL.md"]

DEFAULT_MODEL = "sonnet"
DEFAULT_CRON_MODEL = "haiku"


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


# ── helpers ───────────────────────────────────────────────────────────────────

def _read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def role_meta(role: str) -> dict:
    """Parse roles/<role>/role.yaml (defaults to {} if absent)."""
    path = ROLES_DIR / role / "role.yaml"
    if path.is_file():
        return yaml.safe_load(_read(path)) or {}
    return {}


def resolve_model(agent: dict) -> str:
    """Model precedence: compose config > role.yaml default_model > sonnet."""
    return agent.get("model") or role_meta(agent["role"]).get("default_model") or DEFAULT_MODEL


def resolve_cron_model(agent: dict) -> str:
    """Cron model precedence: config > role.yaml cron_model > haiku."""
    return agent.get("cron_model") or role_meta(agent["role"]).get("cron_model") or DEFAULT_CRON_MODEL


def agent_skills(agent: dict) -> list[str]:
    """The role's own operating skill (named after the role) + bolt-on skills,
    deduped and order-preserving."""
    ordered = [agent["role"], *(agent.get("skills") or [])]
    seen: set[str] = set()
    result: list[str] = []
    for skill in ordered:
        if skill not in seen:
            seen.add(skill)
            result.append(skill)
    return result


# ── config loading + validation ───────────────────────────────────────────────

def load_config(path: Path) -> dict:
    """Parse a compose config and validate it against the factory contract.

    Validates the shape in factory.schema.yaml: required keys, and that every
    referenced role / stack / skill resolves to an existing directory (and that
    each role provides its required files). Accumulates all errors in one pass.
    """
    if not path.is_file():
        raise ValueError(f"compose config not found: {path}")

    config = yaml.safe_load(_read(path)) or {}
    if not isinstance(config, dict):
        raise ValueError("compose config must be a YAML mapping at the top level")

    errors: list[str] = []
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
            else:
                for required in REQUIRED_ROLE_FILES:
                    if not (role_dir / required).is_file():
                        errors.append(f"{where}: role '{role}' is missing {required}")

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
    """Build a stack overlay appended to a role's AGENTS.md (operating rules).

    Phase-1: append each stack's summary plus the contents of any fragment files
    it declares (ordered). Keyed inline injection at marker points is a later
    upgrade (TODO); until then the overlay is a clearly-labelled trailing section.
    """
    if not stacks:
        return ""

    sections = ["", "---", "", "## Stack overlays", ""]
    for stack in stacks:
        meta = yaml.safe_load(_read(STACKS_DIR / stack / "stack.yaml")) or {}
        sections.append(f"### {meta.get('name', stack)}")
        summary = (meta.get("summary") or "").strip()
        if summary:
            sections.extend(["", summary])
        for fragment in meta.get("fragments", []) or []:
            frag_path = STACKS_DIR / stack / fragment
            if frag_path.is_file():
                sections.extend(["", _read(frag_path).rstrip()])
        sections.append("")
    return "\n".join(sections)


def _layer(role: str, filename: str, base_path: Path) -> str:
    """A _core base file, merged with the role's layer if the role provides one."""
    base = _read(base_path)
    role_file = ROLES_DIR / role / filename
    return merge_layered(base, _read(role_file)) if role_file.is_file() else base


def render_identity(agent: dict) -> str:
    """Render IDENTITY.md: token-substitute the base nameplate, append role extras."""
    role = agent["role"]
    meta = role_meta(role)
    title = meta.get("title") or role
    subs = {
        "{{name}}": agent.get("name") or title,
        "{{role}}": title,
        "{{model}}": resolve_model(agent),
        "{{cron_model}}": resolve_cron_model(agent),
    }

    text = _read(CORE_DIR / "IDENTITY_base.md")
    role_identity = ROLES_DIR / role / "IDENTITY.md"
    if role_identity.is_file():
        text = text.rstrip() + "\n\n" + _read(role_identity)
    for token, value in subs.items():
        text = text.replace(token, value)
    return text if text.endswith("\n") else text + "\n"


def render_agent(agent: dict) -> dict[str, str]:
    """Render one agent's 5 identity files. Returns {filename: contents}."""
    role = agent["role"]
    rendered = {
        "SOUL.md": _layer(role, "SOUL.md", CORE_DIR / "SOUL_base.md"),
        "IDENTITY.md": render_identity(agent),
        "USER.md": _layer(role, "USER.md", CORE_DIR / "USER_base.md"),
        "MEMORY.md": _layer(role, "MEMORY.md", CORE_DIR / "MEMORY_base.md"),
    }
    # AGENTS.md carries any stack overlay (stack conventions are operating rules).
    agents_md = _layer(role, "AGENTS.md", CORE_DIR / "AGENTS_base.md")
    overlay = render_stack_overlay(agent.get("stacks", []) or [])
    rendered["AGENTS.md"] = agents_md.rstrip() + "\n" + overlay if overlay else agents_md
    return rendered


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
            "skills": agent_skills(agent),
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

    The project dir is generated output, so it is wiped and rewritten each run —
    the result reflects the config exactly, and a re-run with an unchanged config
    produces byte-identical files. The wipe is guarded to a real directory under
    out_dir (never a symlink) for safety.
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
    parser = argparse.ArgumentParser(description="Compose an AI dev-team agent.")
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
            skills = ", ".join(agent_skills(agent))
            print(f"  - {agent['role']:<16} model={resolve_model(agent):<8} files: {files}")
            print(f"      skills: {skills}")
        print("[dry-run] + agents.yaml")
        return

    project_dir = write_project(name, config, args.out)
    print(f"composed '{name}': {len(agents)} agents -> {project_dir}")
    for agent in agents:
        print(f"  - {agent['role']} ({resolve_model(agent)})  skills: {', '.join(agent_skills(agent))}")


if __name__ == "__main__":
    main()
