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
        {{model}}, {{cron_model}}, {{machine}}, {{operator}}, {{channels}} — the
        latter three from this install's local agent-factory/user.yaml, not the
        compose config) + roles/<role>/IDENTITY.md appended.
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
import contextlib
import errno
import fcntl
import functools
import json
import os
import re
import shutil
import socket
import stat
import sys
from collections.abc import Callable
from pathlib import Path, PurePosixPath

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
# GRID_USER_CONFIG: path to the identity file; replaces agent-factory/user.yaml when set and
# non-empty. Used by goldens, committed personas and plugin bundles so no personal value or
# hostname reaches a tracked file. A set-but-missing path is a hard error (no silent hostname
# fallback) -- see load_user_config(). Relative paths resolve against the current directory.
USER_CONFIG_PATH = Path(os.environ["GRID_USER_CONFIG"]) if os.environ.get("GRID_USER_CONFIG") else HERE / "user.yaml"

# A role normally lives under ROLES_DIR (committed, public). GRID_PRIVATE_ROLES_DIR
# names an optional second roles/ tree — outside this repo, never committed — for
# roles whose content shouldn't enter public git history. If a role exists in
# both, the private copy wins (same "most specific wins" precedent as the-grid's
# root-beats-submodule skill rule).
# Resolution: GRID_PRIVATE_ROLES_DIR if set (an EMPTY value disables private roles
# entirely — tests use this); else ~/.the-grid-private/roles if that dir exists; else none.
# The fallback means a machine with the private repo cloned needs no per-machine env
# setup (which also dodges the non-login-shell env trap over ssh).
_PRIVATE_ROLES_DIR = os.environ.get("GRID_PRIVATE_ROLES_DIR")
if _PRIVATE_ROLES_DIR is None and (Path.home() / ".the-grid-private" / "roles").is_dir():
    _PRIVATE_ROLES_DIR = str(Path.home() / ".the-grid-private" / "roles")
# An explicitly set, non-empty path that is not a directory is a typo: ignoring it would silently
# compose without the private roles (same rule as GRID_USER_CONFIG). The ~/.the-grid-private
# fallback is only chosen when the dir exists, so only the env var can trip this.
if _PRIVATE_ROLES_DIR and not Path(_PRIVATE_ROLES_DIR).expanduser().is_dir():
    sys.exit(f"GRID_PRIVATE_ROLES_DIR not found: {_PRIVATE_ROLES_DIR}")
PRIVATE_ROLES_DIR = Path(_PRIVATE_ROLES_DIR).expanduser().resolve() if _PRIVATE_ROLES_DIR else None

# Names that become path components of generated output. fullmatch, not match: `$` in a
# pattern also accepts a trailing newline. The length cap keeps a name inside NAME_MAX
# once a slug prefix and suffix are added.
PROJECT_RE = re.compile(r"[a-z][a-z0-9-]{0,63}")
ROLE_NAME_RE = re.compile(r"[a-z0-9][a-z0-9_-]{0,63}")
TARGET_SUB_RE = re.compile(r"_[a-z][a-z-]*")   # the _<target> dir under a project


def valid_role_name(role) -> bool:
    return isinstance(role, str) and ROLE_NAME_RE.fullmatch(role) is not None


def role_dir(role: str) -> Path:
    """Resolve a role's directory: the private override tree first (if set and
    the role exists there), else the public ROLES_DIR."""
    if PRIVATE_ROLES_DIR and (PRIVATE_ROLES_DIR / role).is_dir():
        return PRIVATE_ROLES_DIR / role
    return ROLES_DIR / role
OPENCLAW_DIR = HERE / "openclaw"
OPENCLAW_TEMPLATES_DIR = OPENCLAW_DIR / "templates" / "orchestrator"

# The 5 identity files emitted per agent, each = a _core base merged/filled with
# the role layer. (SKILL.md is the role's *skill*, referenced by name — not here.)
IDENTITY_FILES = ["SOUL.md", "IDENTITY.md", "AGENTS.md", "USER.md", "MEMORY.md"]

# Files a role MUST provide: a personality and something to do.
REQUIRED_ROLE_FILES = ["SOUL.md", "SKILL.md"]

DEFAULT_MODEL = "sonnet"
DEFAULT_CRON_MODEL = "haiku"

# The ONE place a model tier becomes the string written into generated Claude Code
# agents' `model:` line (models.yaml). By default a tier maps to itself, so Claude Code
# resolves it to that tier's current release. Pin a tier by writing an exact model id
# there, then recompose: every role on that tier changes at once and `--check` shows
# the drift. GRID_MODELS_FILE overrides the path (tests use this).
MODELS_FILE = Path(os.environ.get("GRID_MODELS_FILE") or Path(__file__).resolve().parent / "models.yaml")


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
    in_fence = False
    for line in md.splitlines():
        if line.lstrip().startswith("```"):
            in_fence = not in_fence      # a '## ' inside a code fence is content, not a heading
        if line.startswith("## ") and not in_fence:
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
    path = role_dir(role) / "role.yaml"
    if path.is_file():
        return yaml.safe_load(_read(path)) or {}
    return {}


def role_description(role: str) -> str:
    """The role.yaml `description:` collapsed to one line, or '' when the role has none."""
    desc = role_meta(role).get("description")
    return " ".join(str(desc).split()) if desc else ""


MODEL_SECTIONS = ("tiers", "openclaw")   # tiers = Claude Code agents; openclaw = OpenClaw/Paperclip agents.yaml


@functools.lru_cache(maxsize=8)
def _model_map(path: str, section: str = "tiers") -> dict:
    """tier -> exact string for one section of models.yaml. An absent file or section means every tier maps to itself."""
    f = Path(path)
    if not f.is_file():
        return {}
    data = yaml.safe_load(f.read_text(encoding="utf-8")) or {}
    tiers = data.get(section) if isinstance(data, dict) else None
    return tiers if isinstance(tiers, dict) else {}


def model_id(tier: str, section: str = "tiers") -> str:
    """The string to write into a generated agent's `model:` line for a tier (section picks the target)."""
    return str(_model_map(str(MODELS_FILE), section).get(tier) or tier)


def resolve_model(agent: dict) -> str:
    """Model precedence: compose config > role.yaml default_model > sonnet."""
    return agent.get("model") or role_meta(agent["role"]).get("default_model") or DEFAULT_MODEL


def resolve_cron_model(agent: dict) -> str:
    """Cron model precedence: config > role.yaml cron_model > haiku."""
    return agent.get("cron_model") or role_meta(agent["role"]).get("cron_model") or DEFAULT_CRON_MODEL


@functools.lru_cache(maxsize=1)
def load_user_config() -> dict[str, str]:
    """Load this install's local identity (user.yaml, gitignored) for the
    IDENTITY nameplate. Every field is optional and every project reads the
    same file, regardless of which compose config is being run — this is
    per-install config, not per-project. `machine` falls back to the local
    hostname so a fresh install with no user.yaml still gets a sane value."""
    cfg: dict = {}
    # An explicit GRID_USER_CONFIG that points nowhere is a typo, not "no config": exiting
    # here stops a tracked build silently falling back to user.yaml or the hostname.
    if os.environ.get("GRID_USER_CONFIG") and not USER_CONFIG_PATH.is_file():
        sys.exit(f"GRID_USER_CONFIG not found: {USER_CONFIG_PATH}")
    if USER_CONFIG_PATH.is_file():
        cfg = yaml.safe_load(_read(USER_CONFIG_PATH)) or {}
    machine = str(cfg.get("machine") or "").strip()
    if not machine:
        machine = socket.gethostname().split(".")[0]
    return {
        "operator": str(cfg.get("operator") or "").strip(),
        "machine": machine,
        "channels": str(cfg.get("channels") or "").strip(),
    }


def agent_skills(agent: dict) -> list[str]:
    """The role's own operating skill (named after the role) + the role's
    base_skills (role.yaml — always included) + per-agent bolt-on skills from the
    compose config. Deduped, order-preserving.

    base_skills may name a skill that lives outside the factory's curated
    skills/ dir (e.g. a session-available Claude Code skill like `deep-research`),
    so unlike the config's `skills` it is NOT validated against SKILLS_DIR — it is
    an intrinsic capability pointer surfaced in the agent's prompt.
    """
    base = role_meta(agent["role"]).get("base_skills") or []
    ordered = [agent["role"], *base, *(agent.get("skills") or [])]
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

    # `project` is a path component of every writer's output (and is rmtree'd): it must be a
    # plain kebab-case name, never '..', '.', a path or a non-string.
    if "project" in config and not (
            isinstance(config["project"], str) and PROJECT_RE.fullmatch(config["project"])):
        errors.append("project must be lowercase kebab-case, at most 64 chars (e.g. 'full-team')")

    slug = config.get("slug")
    if slug is not None and not re.fullmatch(r'[a-z][a-z0-9-]+', str(slug)):
        errors.append("slug must be lowercase kebab-case (e.g. 'full-team')")
    if not isinstance(config.get("bare_names", False), bool):
        errors.append("bare_names must be true/false")

    agents = config.get("agents")
    if agents is not None and not isinstance(agents, list):
        errors.append("`agents` must be a list")
        agents = None

    seen_role: dict[str, int] = {}   # role -> first agents[] index
    seen_out: dict[str, int] = {}    # composed Claude Code name -> first agents[] index
    for i, agent in enumerate(agents or []):
        where = f"agents[{i}]"
        if not isinstance(agent, dict):
            errors.append(f"{where}: each agent must be a mapping")
            continue

        role = agent.get("role")
        if not role:
            errors.append(f"{where}: missing required key: role")
        else:
            errors.extend(f"{where}: {p}" for p in lint_role(role))
            # Two entries that write the same output silently overwrite each other (and the
            # success counts then report the input, not the files).
            if valid_role_name(role) and isinstance(agent.get("bare", False), bool):
                if role in seen_role:
                    errors.append(f"{where}: role '{role}' is already listed at agents[{seen_role[role]}]")
                else:
                    seen_role[role] = i
                    out_name = slugged(agent_slug(agent, cc_slug(config, str(config.get("project")))), role)
                    if out_name in seen_out:
                        errors.append(f"{where}: composed name '{out_name}' collides with "
                                      f"agents[{seen_out[out_name]}]")
                    else:
                        seen_out[out_name] = i

        if not isinstance(agent.get("bare", False), bool):
            errors.append(f"{where}: bare must be true/false")

        # stacks:/skills: names become read paths (STACKS_DIR / name), so each must be a plain
        # kebab-case name (same rule as `project`) BEFORE any path is built from it.
        for key, base, code in (("stacks", STACKS_DIR, "E_STACK_NAME"), ("skills", SKILLS_DIR, "E_SKILL_NAME")):
            names = agent.get(key, []) or []
            if not isinstance(names, list):
                errors.append(f"{where}: {code}: `{key}` must be a list of names")
                continue
            for name in names:
                if not (isinstance(name, str) and PROJECT_RE.fullmatch(name)):
                    errors.append(f"{where}: {code}: {key} entry {name!r} must be lowercase "
                                  f"kebab-case, at most 64 chars (no paths, '..' or control characters)")
                elif (base / name).is_symlink() or base.is_symlink():
                    # a linked stack/skill dir would read (and bundle) content from outside the repo
                    errors.append(f"{where}: {code}: {key[:-1]} '{name}' is reached through a symlink "
                                  f"at {base / name if (base / name).is_symlink() else base}; "
                                  f"refusing to follow it")
                elif not (base / name).is_dir():
                    errors.append(f"{where}: {key[:-1]} '{name}' has no dir at {base / name}")

    # Roster validation: an orchestrator's roster is generated from delegates_to
    # and injected at the {{ROSTER_TABLE}} token in its AGENTS.md. Enforce that
    # the two stay in lockstep so a roster can never silently render empty (the
    # very drift this mechanism exists to prevent), and that every delegate is a
    # role actually present on this team.
    # str only: a malformed (list/number) role is already reported above and must not crash here.
    team_roles = {a.get("role") for a in (agents or [])
                  if isinstance(a, dict) and isinstance(a.get("role"), str)}
    for i, agent in enumerate(agents or []):
        if not isinstance(agent, dict):
            continue
        where = f"agents[{i}]"
        role = agent.get("role")
        delegates = agent.get("delegates_to")

        if delegates is not None and not isinstance(delegates, list):
            errors.append(f"{where}: delegates_to must be a list")
            delegates = None
        for d in delegates or []:
            if not isinstance(d, str) or d not in team_roles:
                errors.append(f"{where}: delegates_to '{d}' is not a role on this team")

        if valid_role_name(role) and role_dir(role).is_dir():
            agents_md = role_dir(role) / "AGENTS.md"
            has_token = agents_md.is_file() and ROSTER_TOKEN in _read(agents_md)
            if has_token and delegates is None:
                errors.append(
                    f"{where}: role '{role}' declares a {ROSTER_TOKEN} slot but the "
                    f"agent has no delegates_to (use `delegates_to: []` for no team)"
                )
            if delegates is not None and not has_token:
                errors.append(
                    f"{where}: agent has delegates_to but role '{role}' AGENTS.md "
                    f"has no {ROSTER_TOKEN} slot to render it into"
                )

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
            # A fragment is read into the generated agent file: it must stay inside its own
            # stack dir (no '..', absolute path or symlink out), else refuse rather than read.
            if not isinstance(fragment, str) or "\0" in fragment or not (
                    STACKS_DIR / stack / fragment).resolve().is_relative_to((STACKS_DIR / stack).resolve()):
                sys.exit(f"E_STACK_FRAGMENT: stack {stack!r}: fragment {str(fragment)!r} "
                         f"is outside the stack dir")
            frag_path = STACKS_DIR / stack / fragment
            if frag_path.is_file():
                sections.extend(["", _read(frag_path).rstrip()])
        sections.append("")
    return "\n".join(sections)


def _layer(role: str, filename: str, base_path: Path) -> str:
    """A _core base file, merged with the role's layer if the role provides one."""
    base = _read(base_path)
    role_file = role_dir(role) / filename
    return merge_layered(base, _read(role_file)) if role_file.is_file() else base


def render_identity(agent: dict) -> str:
    """Render IDENTITY.md: token-substitute the base nameplate, append role extras."""
    role = agent["role"]
    meta = role_meta(role)
    title = meta.get("title") or role
    user_cfg = load_user_config()
    subs = {
        "{{name}}": agent.get("name") or title,
        "{{role}}": title,
        "{{model}}": resolve_model(agent),
        "{{cron_model}}": resolve_cron_model(agent),
        "{{machine}}": user_cfg["machine"],
        "{{operator}}": user_cfg["operator"],
        "{{channels}}": user_cfg["channels"],
    }

    text = _read(CORE_DIR / "IDENTITY_base.md")
    role_identity = role_dir(role) / "IDENTITY.md"
    if role_identity.is_file():
        text = text.rstrip() + "\n\n" + _read(role_identity)
    for token, value in subs.items():
        text = text.replace(token, value)
    return text if text.endswith("\n") else text + "\n"


def render_agent(agent: dict, slug: str | None = None) -> dict[str, str]:
    """Render one agent's 5 identity files. Returns {filename: contents}.
    slug, when given, is forwarded to roster generation so roster tables name
    delegates by their slugged agent name (CC target only)."""
    role = agent["role"]
    rendered = {
        "SOUL.md": _layer(role, "SOUL.md", CORE_DIR / "SOUL_base.md"),
        "IDENTITY.md": render_identity(agent),
        "USER.md": _layer(role, "USER.md", CORE_DIR / "USER_base.md"),
        "MEMORY.md": _layer(role, "MEMORY.md", CORE_DIR / "MEMORY_base.md"),
    }
    # AGENTS.md: inject the generated roster (orchestrators) then any stack overlay.
    agents_md = _layer(role, "AGENTS.md", CORE_DIR / "AGENTS_base.md")
    agents_md = inject_roster(agents_md, agent, slug=slug)
    if is_orchestrator(role):   # orchestrators only; specialists are unchanged
        agents_md = agents_md.rstrip() + "\n\n" + render_decision_brief() + "\n"
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
            "model": model_id(resolve_model(agent), "openclaw"),
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


# ── claude-code emitter ───────────────────────────────────────────────────────
# A second emit target: transform the 5-file source into Claude Code-native
# artifacts. The orchestrator/specialist split (role.yaml `orchestrator`) decides
# the shape — a CC *skill* that transforms the session, or a CC *subagent* that
# can be spawned. These are what wire.sh symlinks into ~/.claude/.

# Order the identity files are flattened into a single prompt: who I am, how I
# behave, who I serve, what I carry, how I operate (matches the boot sequence).
FLATTEN_ORDER = ["IDENTITY.md", "SOUL.md", "USER.md", "MEMORY.md", "AGENTS.md"]


def strip_html_comments(md: str) -> str:
    """Remove <!-- ... --> blocks. The templates are comment-heavy scaffolding
    (authoring notes, [FILL] hints); those are noise inside an agent's prompt.

    Some authoring notes show an inline example of comment syntax (e.g.
    "marked: <!-- STACK: ... -->") inside the real comment. A naive
    non-greedy regex stops at that inner "-->", leaking the real closing
    "-->" as literal text. Scan instead: if another "<!--" appears before
    the first "-->" found, that "-->" belongs to the nested example, not
    the real close — keep looking past it for the actual terminator.
    """
    out = []
    i = 0
    n = len(md)
    while True:
        start = md.find("<!--", i)
        if start == -1:
            out.append(md[i:])
            break
        out.append(md[i:start])
        search_from = start + 4
        while True:
            close = md.find("-->", search_from)
            if close == -1:
                close = n
                break
            if md.find("<!--", search_from, close) == -1:
                break
            search_from = close + 3
        i = min(close + 3, n)
    text = "".join(out)
    # Collapse the blank-line runs the removed comments leave behind.
    return re.sub(r"\n{3,}", "\n\n", text).strip()


def is_orchestrator(role: str) -> bool:
    return bool(role_meta(role).get("orchestrator", False))


def role_summary(role: str) -> str:
    return " ".join((role_meta(role).get("summary") or "").split())


# ── roster generation ─────────────────────────────────────────────────────────
# An orchestrator's roster is GENERATED from the project config's delegates_to
# list (single source of truth, co-located with the team) and injected into the
# role's AGENTS.md at the {{ROSTER_TABLE}} token. This keeps the roster from
# drifting out of sync with the team as roles are added or removed.

ROSTER_TOKEN = "{{ROSTER_TABLE}}"


def role_owns(role: str) -> str:
    """The short 'owns' phrase for a roster row: role.yaml `owns:` if set,
    else the first sentence of the role's summary (the summaries already read
    like owns statements)."""
    owns = role_meta(role).get("owns")
    if owns:
        return " ".join(owns.split())
    summary = role_summary(role)
    # First sentence = up to the first period followed by whitespace (or the lot).
    return re.split(r"(?<=\.)\s", summary, maxsplit=1)[0].strip()


def render_roster_table(delegates: list[str], slug: str | None = None) -> str:
    """A markdown roster table (Agent | Owns) from a list of delegate roles.
    An empty list renders a placeholder — a valid state for a team with no
    specialists assigned yet (e.g. a demo with the orchestrator alone).
    When slug is given, agent names are prefixed (e.g. 'full-team-tech-lead')
    to match the slugged subagent names emitted by the CC target."""
    if not delegates:
        return "_No specialists assigned to this team yet._"
    rows = ["| Agent | Owns |", "|-------|------|"]
    rows += [f"| {(slug + '-' + role) if slug else role} | {role_owns(role)} |" for role in delegates]
    return "\n".join(rows)


def render_decision_brief() -> str:
    """The shared decision-brief section (_core/DECISION_BRIEF.md), comment-stripped.
    Appended to orchestrators only: the format is how they put a choice to the human."""
    return strip_html_comments(_read(CORE_DIR / "DECISION_BRIEF.md")).strip()


def inject_roster(agents_md: str, agent: dict, slug: str | None = None) -> str:
    """Replace the {{ROSTER_TABLE}} token (if present) with the generated roster.
    load_config has already validated token/delegates_to symmetry, so here we
    only substitute. Roles without the token pass through unchanged."""
    if ROSTER_TOKEN not in agents_md:
        return agents_md
    return agents_md.replace(ROSTER_TOKEN, render_roster_table(agent.get("delegates_to") or [], slug=slug))


def _frontmatter(fields: dict) -> str:
    """A YAML frontmatter block (--- ... ---) from an ordered dict of fields."""
    return "---\n" + yaml.safe_dump(fields, sort_keys=False, default_flow_style=False).strip() + "\n---\n"


def _flattened_identity(agent: dict, slug: str | None = None) -> str:
    """The 5 identity files (comment-stripped) joined in boot order."""
    rendered = render_agent(agent, slug=slug)
    return "\n\n---\n\n".join(strip_html_comments(rendered[fn]) for fn in FLATTEN_ORDER)


# ── lean profile ──────────────────────────────────────────────────────────────
# One source, two renderings. "full" is the flattened five-file identity (persona,
# memory seed, boot sequence). "lean" is a deterministic selection from the SAME
# role files — no second copy of anything to drift:
#   keep  SOUL.md (role layer only): role identity, decision-making, escalation
#         rules, "What the X is NOT"            — the role's judgement and lane
#   keep  AGENTS.md (role layer only): every section — scope, receiving work,
#         routing, and any hard rules / ranked priorities the role defines
#   add   _core/DECISION_BRIEF.md, orchestrators only, after the AGENTS sections
#         (the one shared fragment lean keeps; it is the format for asking the human)
#   keep  SKILL.md — the operating procedure (the actual job)
#   keep  project context, if the deploy supplies one
#   drop  _core base scaffolding, IDENTITY nameplate, USER, MEMORY seed, boot
#         sequence, signal-file handoff protocol (runtime plumbing a one-project
#         Claude Code session does not use)
PROFILES = ("full", "lean")


def _soul_keep(heading: str) -> bool:
    """Is this SOUL.md '## ' heading part of the lean cut? Matches on the name
    with any trailing '(role layer)' qualifier removed."""
    h = re.sub(r"\s*\(.*?\)\s*$", "", heading[3:].strip()).lower()
    return h in ("role identity", "decision-making", "escalation rules") or (
        h.startswith("what ") and h.endswith(" is not")
    )


REFERENCE_HEADING_RE = re.compile(r"template|checklist", re.I)
REFERENCE_REL = ".claude/grid-reference/{name}.md"     # where deploy.py writes it, per agent name


def split_skill_reference(skill_md: str) -> tuple[str, str]:
    """(procedure, reference) from a role's SKILL.md. Reference = the '## ' sections
    whose heading says template/checklist: fill-in artefacts the agent needs at one
    step, not in every prompt. Everything else (the procedure) stays inline. Code
    fences are respected, so a '## ' inside a template block is not a split point."""
    pre, secs = split_sections(strip_html_comments(skill_md))
    keep = [pre.rstrip()] if pre.strip() else []
    ref: list[str] = []
    for heading, body in secs:
        block = heading + ("\n" + body.rstrip() if body.strip() else "")
        (ref if REFERENCE_HEADING_RE.search(heading) else keep).append(block)
    return "\n\n".join(keep) + "\n", ("\n\n".join(ref) + "\n" if ref else "")


def lean_reference(role: str) -> str:
    """The reference file body for a role's lean deploy ('' if it has none)."""
    return split_skill_reference(_read(role_dir(role) / "SKILL.md"))[1]


def render_lean_body(agent: dict, slug: str, project_context: str = "", reference_path: str = "") -> str:
    """The lean system-prompt body for one agent (no frontmatter). When reference_path
    is given, the SKILL's template/checklist sections are NOT inlined — they live in
    that file (written by deploy.py) and the prompt points at it."""
    role = agent["role"]
    title = role_meta(role).get("title") or role
    rdir = role_dir(role)

    parts = [f"You are the **{title}**. {role_summary(role)}"]

    _, soul_secs = split_sections(strip_html_comments(_read(rdir / "SOUL.md")))
    parts += [f"{h}\n{b.strip()}" for h, b in soul_secs if _soul_keep(h)]

    agents_path = rdir / "AGENTS.md"
    if agents_path.is_file():
        agents_md = inject_roster(strip_html_comments(_read(agents_path)), agent, slug=slug)
        _, agent_secs = split_sections(agents_md)
        parts += [f"{h}\n{b.strip()}" for h, b in agent_secs]
    if is_orchestrator(role):   # after the role's AGENTS sections, before the stack overlay
        parts.append(render_decision_brief())
    overlay = render_stack_overlay(agent.get("stacks", []) or []).strip()
    if overlay:
        parts.append(overlay)

    parts.append(
        "## Hand-offs in this project\n\n"
        "Role names in routing tables and escalation rules above are grid agents, "
        "deployed here as `grid-<role>`. If the agent you would route to is not "
        "available in this project, tell the user which role should take the work "
        "instead of improvising it. Signal-file hand-offs (`signals/`) do not apply."
    )
    if project_context.strip():
        parts.append("## Project context\n\n" + project_context.strip())

    skill = _read(rdir / "SKILL.md")
    if reference_path and lean_reference(role):
        procedure, _ = split_skill_reference(skill)
        procedure = procedure.rstrip() + (
            f"\n\n## Reference material\n\nThe templates and checklists for this procedure are in "
            f"`{reference_path}`. Read that file when a step calls for one; do not work from memory."
        )
    else:
        procedure = strip_html_comments(skill)
    parts.append("## Operating procedure\n\n" + procedure)
    return "\n\n".join(parts) + "\n"


def cc_slug(config: dict, name: str) -> str:
    """Prefix for Claude Code agent/skill names. Empty when the project sets
    `bare_names: true`, so a role is invoked as /<role> rather than /<slug>-<role>."""
    return "" if config.get("bare_names") else (config.get("slug") or name)


def agent_slug(agent: dict, slug: str) -> str:
    """The slug for one agent: empty when its config entry sets `bare: true`."""
    return "" if agent.get("bare") else slug


def slugged(slug: str, role: str) -> str:
    """The Claude Code name for a role: '<slug>-<role>', or just '<role>' when slug is empty."""
    return f"{slug}-{role}" if slug else role


def render_subagent_body(agent: dict, slug: str, project_context: str = "") -> str:
    """The full-profile body of a specialist subagent (everything after the frontmatter).

    Shared by emit_cc_subagent and every harness agent emitter in AGENT_TARGETS, so all
    harnesses carry one identical prompt. Extracted verbatim from emit_cc_subagent:
    Claude output must stay byte-identical.
    """
    role = agent["role"]
    title = role_meta(role).get("title") or role
    skills = agent_skills(agent)
    procedure = strip_html_comments(_read(role_dir(role) / "SKILL.md"))
    bolt_ons = (
        f"\n\nAdditional skills available to you: {', '.join(skills[1:])}."
        if len(skills) > 1 else ""
    )
    context = f"## Project context\n\n{project_context.strip()}\n\n---\n\n" if project_context.strip() else ""
    return (
        f"You are the **{title}**, a specialist agent on a composed dev team. "
        f"Adopt the identity, behaviour, and operating rules below as your own.\n\n"
        f"{_flattened_identity(agent, slug=slug)}\n\n---\n\n"
        f"{context}"
        f"## Operating procedure\n\n"
        f"{procedure}{bolt_ons}\n"
    )


def subagent_description(role: str) -> str:
    """The description of a specialist subagent, identical on every harness except that Codex
    strips control characters (TOML forbids them; role lint rejects them at the source).

    A role.yaml `description:` (one line, budget-and-usage) replaces the legacy formula
    verbatim; roles without it keep the old text byte-for-byte.
    """
    title = role_meta(role).get("title") or role
    return role_description(role) or f"{title}. {role_summary(role)} Use this subagent for {role} work."


def emit_cc_subagent(agent: dict, slug: str, profile: str = "full",
                     project_context: str = "", reference_path: str = "") -> tuple[str, str]:
    """A specialist role → one Claude Code subagent `.md` (spawnable).

    Frontmatter (name/description/model) + a body that adopts the flattened
    identity as the subagent's system prompt. Returns (filename, contents).
    The name is slug-prefixed (e.g. 'full-team-backend-dev') so teams are
    collision-safe and discoverable as a group.
    """
    role = agent["role"]
    slugged_name = slugged(slug, role)

    fields = {
        "name": slugged_name,
        "description": subagent_description(role),
        "model": model_id(resolve_model(agent)),
    }
    tools = role_tools(role)
    if tools:   # a role.yaml `tools:` allowlist narrows the subagent; absent = inherits every tool
        fields = {**{k: v for k, v in fields.items() if k != "model"}, "tools": ", ".join(tools), "model": fields["model"]}
    if profile == "lean":
        return f"{slugged_name}.md", _frontmatter(fields) + "\n" + render_lean_body(agent, slug, project_context, reference_path)
    return f"{slugged_name}.md", _frontmatter(fields) + "\n" + render_subagent_body(agent, slug, project_context)


def emit_cc_skill(agent: dict, slug: str, profile: str = "full",
                  project_context: str = "", reference_path: str = "") -> dict[str, str]:
    """An orchestrator role → a Claude Code skill folder (transforms the session).

    SKILL.md = frontmatter + a "become the <role>" boot body + the flattened
    identity + the role's operating procedure (its SKILL.md) inline. Self-contained
    so invoking it turns the current session into the orchestrator. Returns
    {relpath: contents} (one SKILL.md for now).
    The name is slug-prefixed (e.g. 'full-team-tech-lead') so typing the slug
    in the / menu clusters the whole team and prevents cross-project collisions.
    """
    role = agent["role"]
    slugged_name = slugged(slug, role)
    title = role_meta(role).get("title") or role

    fields = {
        "name": slugged_name,
        # An explicit role.yaml `description:` wins; otherwise the legacy formula.
        "description": role_description(role) or
                       f"{title} orchestrator. {role_summary(role)} "
                       f"Invoke with /{slugged_name}"
                       # Only team orchestrators (those with reports) coordinate dev-team work.
                       + (" or when coordinating a multi-step dev-team feature." if agent.get("delegates_to") else "."),
    }
    if profile == "lean":
        body = (
            f"# {title}\n\n"
            f"When this skill is invoked, **become the {title}**: follow the role "
            f"and operating procedure below. This transforms the current session "
            f"into the {title} orchestrator.\n\n"
            f"{render_lean_body(agent, slug, project_context, reference_path)}"
        )
        return {"SKILL.md": _frontmatter(fields) + "\n" + body}
    procedure = strip_html_comments(_read(role_dir(role) / "SKILL.md"))
    context = f"## Project context\n\n{project_context.strip()}\n\n---\n\n" if project_context.strip() else ""
    body = (
        f"# {title}\n\n"
        f"When this skill is invoked, **become the {title}**: adopt the identity, "
        f"personality, and operating rules below, then follow the operating procedure. "
        f"This transforms the current session into the {title} orchestrator.\n\n"
        f"## Boot — adopt this identity\n\n"
        f"{_flattened_identity(agent, slug=slug)}\n\n"
        f"---\n\n{context}## Operating procedure\n\n"
        f"{procedure}\n"
    )
    return {"SKILL.md": _frontmatter(fields) + "\n" + body}


# ── writer safety ─────────────────────────────────────────────────────────────
# Every writer replaces a generated dir. vet_target() decides WHERE it may write (a plain
# project name, inside --out, never a symlink); install_tree()/install_project() decide HOW
# (render everything first, write into <target>.tmp, then swap), so a failure mid-write
# leaves the previous tree untouched and a refusal never prints a traceback.

def _remove(path: Path, strict: bool = True) -> None:
    """Delete a file, symlink (the link only) or dir; absent is fine. strict=False swallows errors."""
    try:
        if path.is_symlink() or path.is_file():
            path.unlink()
        elif path.is_dir():
            shutil.rmtree(path)
    except OSError:
        if strict:
            raise


# The swap dirs (<target>.tmp / <target>.old, <project>.tmp / .old) sit next to user content, so
# a crashed run's debris may only be deleted when compose.py itself made it. Ownership is a
# sibling marker FILE (<dir>.compose-owned), written before the dir exists: the dir's own
# contents (a previous generated tree) cannot carry one. Anything unmarked is a user's, refused.
OWNED_SUFFIX = ".compose-owned"


def _marker(p: Path) -> Path:
    return p.with_name(p.name + OWNED_SUFFIX)


def _unmark(p: Path) -> None:
    """Remove p's marker if it is a file or link (a link is unlinked, never followed); never a dir."""
    m = _marker(p)
    if m.is_symlink() or m.is_file():
        m.unlink()


def _recheck_not_link(*paths: Path) -> None:
    """Re-verify, immediately before the first rename, what vet_target() checked at the start:
    the project dir and the target are still not symlinks. Narrows (does not close) the window in
    which a same-user process could swap a link in after vetting; an fd-based swap would close it."""
    for p in paths:
        if p.is_symlink():
            sys.exit(f"error: refusing to write: {p} became a symlink after it was vetted")


def _claim(p: Path, claimed: list) -> None:
    """About to create `p`: clear compose.py's own debris there, refuse anything else, then mark it
    ours and record it in `claimed`. Failure cleanup releases ONLY what is in `claimed`, never a
    path it merely finds a marker-shaped thing beside (a dir or FIFO there is not our marker)."""
    m = _marker(p)
    marked = m.is_symlink() or m.is_file()    # a marker that is a dir/FIFO is nobody's: refused below
    if os.path.lexists(m) and not (m.is_symlink() or m.is_file()):
        sys.exit(f"error: refusing to touch {m}: not a plain file")
    if os.path.lexists(p) and not marked:
        sys.exit(f"error: refusing to delete {p}: there is no {m.name} beside it, so it cannot be "
                 f"told from your own files (it may be the previous output kept by an interrupted "
                 f"run); move or remove it and re-run")
    _remove(p)
    _unmark(p)                                # stale marker: a link is unlinked, never followed
    p.parent.mkdir(parents=True, exist_ok=True)   # the marker is a sibling; its dir may not exist yet
    fd = os.open(_marker(p), os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o644)
    os.close(fd)
    claimed.append(p)


def _release(p: Path, strict: bool = True) -> None:
    """Delete a dir we claimed, and its marker. Only ever called on a path _claim()ed first.
    strict=False swallows errors, but never drops the marker of a dir it failed to delete: the
    marker is what lets the next run clear the debris instead of refusing it as a user's."""
    try:
        _remove(p, strict=True)
        _unmark(p)
    except OSError:
        if strict:
            raise


IDENTITY_FILES = {"SOUL.md", "IDENTITY.md", "USER.md", "MEMORY.md", "AGENTS.md"}   # render_agent()


def _is_own_output(entry: Path) -> bool:
    """A top-level entry the legacy target writes: agents.yaml, or a real role dir that holds
    only the identity files (links and anything else are not ours)."""
    if entry.is_symlink():
        return False
    if entry.name == "agents.yaml":
        return entry.is_file()
    return entry.is_dir() and all(
        f in IDENTITY_FILES and (entry / f).is_file() and not (entry / f).is_symlink()
        for f in os.listdir(entry))


def vet_target(out_dir: Path, name, sub: str | None = None) -> Path:
    """The dir a writer will replace: <out_dir>/<name>[/<sub>]. Exits (no traceback) unless the
    name is a plain project name, neither the project dir nor the target is a symlink or a
    non-dir, and the resolved target lies strictly inside the resolved out_dir."""
    if not (isinstance(name, str) and PROJECT_RE.fullmatch(name)):
        sys.exit(f"error: refusing to write: project name {name!r} is not lowercase kebab-case")
    if sub is not None and not TARGET_SUB_RE.fullmatch(sub):
        sys.exit(f"error: refusing to write: target dir {sub!r} is not of the form _<target>")
    project = out_dir / name
    target = project / sub if sub else project
    for p in dict.fromkeys((project, target)):
        if p.is_symlink():
            sys.exit(f"error: refusing to write: {p} is a symlink, not a dir")
        if os.path.lexists(p) and not p.is_dir():
            sys.exit(f"error: refusing to write: {p} exists and is not a dir")
    root, resolved = out_dir.resolve(), target.resolve()
    if resolved == root or root not in resolved.parents:
        sys.exit(f"error: refusing to write: {target} resolves outside {out_dir}")
    # A project name can equal some other dir that already sits under --out (e.g. `skills`).
    # install_project() moves every top-level non-'_' entry of the project dir aside and deletes
    # it, so only a dir that looks like compose output may be reused: every entry is a dotfile, a
    # `_<target>` dir, the legacy target's agents.yaml, or a role dir holding only the identity
    # files render_agent() writes. Ownership of the project dir is not otherwise recorded, hence
    # this shape test.
    if os.path.lexists(project):
        for entry in sorted(os.listdir(project)):
            if entry.startswith((".", "_")) or _is_own_output(project / entry):
                continue
            sys.exit(f"error: refusing to write: {project} already exists and does not look like "
                     f"compose output (it holds {entry!r}); use another project name or --out")
    return target


@contextlib.contextmanager
def _swap_lock(project: Path):
    """Exclusive, non-blocking lock on the project dir for the length of one swap. Two runs
    swapping the same project would otherwise clear each other's .tmp/.old and die with a
    traceback; now the second exits with a message. The kernel drops the lock if the holder dies
    (SIGKILL included). The dir is opened O_NOFOLLOW, so a link swapped in after vet_target()
    is refused here too. A filesystem that cannot lock (ENOLCK/EOPNOTSUPP...) runs unlocked,
    as it did before this lock existed."""
    try:
        project.mkdir(parents=True, exist_ok=True)
        fd = os.open(project, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    except OSError as exc:
        sys.exit(f"error: refusing to write: cannot open {project} as a plain dir "
                 f"(a symlink after it was vetted?): {exc}")
    try:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError as exc:
            if exc.errno in (errno.EWOULDBLOCK, errno.EAGAIN):
                sys.exit(f"error: another compose run is writing {project}; "
                         f"wait for it to finish and re-run")
        yield
    finally:
        os.close(fd)


def _materialise(root: Path, files: dict[str, str], dirs=()) -> None:
    """Write {relative path: text} (plus empty `dirs`) under root. Relative paths are checked
    to stay inside root, so a role name can never escape the dir being built."""
    for rel in [*files, *dirs]:
        parts = PurePosixPath(rel).parts
        if not parts or PurePosixPath(rel).is_absolute() or any(x in ("", ".", "..") for x in parts):
            sys.exit(f"error: refusing to write {rel!r}: path escapes {root}")
    for rel in dirs:
        (root / rel).mkdir(parents=True, exist_ok=True)
    for rel, contents in files.items():
        f = root / rel
        f.parent.mkdir(parents=True, exist_ok=True)
        f.write_text(contents, encoding="utf-8")


def install_tree(target: Path, files: dict[str, str], dirs=()) -> None:
    """Replace `target` with the rendered tree: build in <target>.tmp, rename the old tree to
    <target>.old, rename tmp into place, delete old. os.replace cannot replace a non-empty
    dir, hence the two renames. Any failure restores the old tree and exits with an error.
    Held under the project dir's lock, so concurrent runs cannot clear each other's scratch."""
    with _swap_lock(target.parent):
        _install_tree(target, files, dirs)


def _install_tree(target: Path, files: dict[str, str], dirs=()) -> None:
    tmp = target.with_name(target.name + ".tmp")
    old = target.with_name(target.name + ".old")
    claimed: list[Path] = []
    committed = False                        # True once tmp is in place: old is only leftovers
    try:
        for leftover in (tmp, old):          # a crashed earlier run's own debris is ours to clear
            _claim(leftover, claimed)        # (anything unmarked is a user's: refused, untouched)
        tmp.mkdir(parents=True)
        _materialise(tmp, files, dirs)
        _recheck_not_link(target.parent, target)
        try:
            if os.path.lexists(target):
                os.rename(target, old)
            os.rename(tmp, target)
        except BaseException:
            # Whatever interrupted the swap (an OSError, Ctrl-C, SystemExit), put the previous tree
            # back if it was moved aside and nothing took its place. If the restore itself fails,
            # that OSError propagates and the previous tree stays in `old`, named by the handler.
            if os.path.lexists(old) and not os.path.lexists(target):
                os.rename(old, target)
            raise
        committed = True
        _release(tmp, strict=False)          # tmp was renamed into place; this drops its marker
        _release(old, strict=False)
    except OSError as exc:
        kept = _abort_swap(tmp, old, claimed, committed)
        sys.exit(f"error: could not write {target}: {exc}"
                 + (f" (the previous tree is kept at {kept})" if kept else ""))
    except BaseException:
        kept = _abort_swap(tmp, old, claimed, committed)
        if kept:
            print(f"error: interrupted while writing {target}: the previous tree is kept at {kept}",
                  file=sys.stderr)
        raise


def _abort_swap(tmp: Path, old: Path, claimed: list, committed: bool = False) -> Path | None:
    """Failure cleanup. Releases only paths in `claimed` (so a refused _claim() of a user's dir
    deletes nothing). `tmp` is ours and is dropped. `old` is dropped only if it is gone or an
    empty dir; if it still holds anything it may be the only copy of the previous output, so it
    is kept, its marker removed (the next run then refuses it instead of clearing it), and its
    path returned for the error message. Once `committed` the new tree is in place and `old` is
    just the previous one being deleted: it is left alone, marker included, so the next run
    clears whatever remains."""
    if tmp in claimed:
        _release(tmp, strict=False)
    if old not in claimed or committed:
        return None
    if os.path.lexists(old) and not (old.is_dir() and not old.is_symlink() and not os.listdir(old)):
        try:
            _unmark(old)
        except OSError:
            pass
        return old
    _release(old, strict=False)
    return None


def install_project(project_dir: Path, files: dict[str, str]) -> None:
    """Legacy (default target) writer: replace only this target's own output, i.e. every
    top-level entry of the project dir NOT starting with '_'. The _<target> dirs that the other
    targets write (and wire.sh symlinks) are never touched. New entries are built in
    <project>.tmp first; old own-output is moved to <project>.old and put back on failure.
    Held under the project dir's lock, like install_tree."""
    with _swap_lock(project_dir):
        _install_project(project_dir, files)


def _install_project(project_dir: Path, files: dict[str, str]) -> None:
    tmp = project_dir.with_name(project_dir.name + ".tmp")
    old = project_dir.with_name(project_dir.name + ".old")
    claimed: list[Path] = []
    committed = False
    try:
        for leftover in (tmp, old):          # only compose.py's own marked debris is cleared
            _claim(leftover, claimed)
        tmp.mkdir(parents=True)
        _materialise(tmp, files)
        old.mkdir()
        _recheck_not_link(project_dir)
        project_dir.mkdir(parents=True, exist_ok=True)
        own = sorted(e for e in os.listdir(project_dir) if not e.startswith("_"))
        new = sorted(os.listdir(tmp))
        try:
            for entry in own:
                os.rename(project_dir / entry, old / entry)
            for entry in new:
                os.rename(tmp / entry, project_dir / entry)
        except BaseException:
            # Undo from what is on disk, not from bookkeeping an interrupt could outrun: a new
            # entry no longer in tmp was moved in (out it goes); an old entry still in `old` and
            # not back in the project dir is put back.
            for entry in new:
                if not os.path.lexists(tmp / entry):
                    _remove(project_dir / entry, strict=False)
            for entry in own:
                if os.path.lexists(old / entry) and not os.path.lexists(project_dir / entry):
                    os.rename(old / entry, project_dir / entry)
            raise
        committed = True
        _release(tmp, strict=False)
        _release(old, strict=False)
    except OSError as exc:
        # old is emptied by a clean rollback; if the rollback itself failed it still holds the
        # previous own-output, which _abort_swap keeps (and names here) instead of deleting.
        kept = _abort_swap(tmp, old, claimed, committed)
        sys.exit(f"error: could not write {project_dir}: {exc}"
                 + (f" (the previous output is kept at {kept})" if kept else ""))
    except BaseException:
        kept = _abort_swap(tmp, old, claimed, committed)
        if kept:
            print(f"error: interrupted while writing {project_dir}: the previous output is kept "
                  f"at {kept}", file=sys.stderr)
        raise


def write_claude_code(name: str, config: dict, out_dir: Path) -> Path:
    """Emit the team as Claude Code artifacts under <out_dir>/<name>/_claude-code/.

    Orchestrators → skills/<slug>-<role>/SKILL.md; specialists → agents/<slug>-<role>.md.
    Idempotent: the _claude-code dir is wiped and rewritten each run. wire.sh
    symlinks skills/* into ~/.claude/skills/ and agents/* into ~/.claude/agents/.
    Slug defaults to the project name when not set in the config.
    """
    slug = cc_slug(config, name)
    cc_dir = vet_target(out_dir, name, "_claude-code")
    # Render everything first; nothing on disk changes until install_tree swaps it in.
    files: dict[str, str] = {}
    for agent in config["agents"]:
        role = agent["role"]
        aslug = agent_slug(agent, slug)
        slugged_name = slugged(aslug, role)
        if is_orchestrator(role):
            for relpath, contents in emit_cc_skill(agent, aslug).items():
                files[f"skills/{slugged_name}/{relpath}"] = contents
        else:
            filename, contents = emit_cc_subagent(agent, aslug)
            files[f"agents/{filename}"] = contents
    install_tree(cc_dir, files, dirs=("skills", "agents"))
    return cc_dir


# ── generic harness agent writer ──────────────────────────────────────────────
# Per-harness agent emitters (Codex, OpenCode, Gemini CLI, ...) register here as
# {target: emit_fn}. emit_fn(agent, slug) -> (filename, contents) for ONE specialist,
# built on render_subagent_body() so every harness carries the same prompt. Empty
# until a harness group registers its emitter; --target choices are built from it.
AGENT_TARGETS: dict[str, Callable[[dict, str], tuple[str, str]]] = {}


def write_harness_agents(target: str, name: str, config: dict, out_dir: Path) -> Path:
    """Emit the team's specialists for one harness under <out_dir>/<name>/_<target>/agents/.

    Orchestrators are skipped (they are session skills, not spawnable agents).
    Idempotent: the _<target> dir is wiped and rewritten each run, which is what
    prevents orphaned files when a role is removed or renamed.
    """
    emit = AGENT_TARGETS[target]
    slug = cc_slug(config, name)
    target_dir = vet_target(out_dir, name, f"_{target}")
    # Run every emit BEFORE anything is touched so an emitter error leaves the old tree
    # untouched and writes nothing.
    rendered = [
        emit(agent, agent_slug(agent, slug))
        for agent in config["agents"]
        if not is_orchestrator(agent["role"])
    ]
    install_tree(target_dir, {f"agents/{filename}": contents for filename, contents in rendered},
                 dirs=("agents",))
    return target_dir


# ── Codex agent emitter ───────────────────────────────────────────────────────
# Codex CLI reads ~/.codex/agents/<name>.toml: `name`, `description` and
# `developer_instructions` are required; `name` (not the filename) is the identity.
# The stdlib has no TOML writer, so strings are escaped by hand; the output is checked
# by round-tripping through tomllib (tests/test_harness_formats.bats).
def _toml_clean(s: str) -> str:
    """Drop the control characters TOML forbids in strings (everything below U+0020 except
    tab and newline, plus DEL), so a stray CR or NUL cannot make the file invalid."""
    return "".join(c for c in s if c in "\n\t" or (c >= " " and c != "\x7f"))


def toml_basic(s: str) -> str:
    """A TOML single-line basic string literal, including the quotes."""
    out = _toml_clean(s).replace("\\", "\\\\").replace('"', '\\"')
    return '"' + out.replace("\n", "\\n").replace("\t", "\\t") + '"'


def toml_multiline(s: str) -> str:
    """A TOML multi-line basic string literal, including the delimiters.

    Only `\\` and runs of three quotes need escaping inside; trailing quotes are escaped
    too, since they would otherwise merge with the closing delimiter. The newline right
    after the opening delimiter is trimmed by TOML, so the parsed value equals `s`.
    """
    cleaned = _toml_clean(s)
    # Peel trailing quotes off BEFORE escaping, so the escapes below cannot be re-split.
    body = cleaned.rstrip('"')
    trailing = len(cleaned) - len(body)
    out = body.replace("\\", "\\\\").replace('"""', '\\"\\"\\"') + '\\"' * trailing
    return '"""\n' + out + '"""'


# Roles whose documented work writes files THROUGH THE SHELL (allowlist has Bash but no
# Edit/Write). A Codex read-only sandbox also blocks those shell writes and would break them,
# so they get no sandbox_mode. Every other role without Edit/Write stays read-only.
# See the mapping table in docs/harnesses.md.
CODEX_SHELL_WRITERS = frozenset({"finance-sentinel", "data-analyst"})


def emit_codex_agent(agent: dict, slug: str) -> tuple[str, str]:
    """A specialist role → one Codex subagent `<name>.toml`. Returns (filename, contents).

    Key order is name, description, sandbox_mode (only when the role has a `tools:` allowlist
    with neither Edit nor Write and is not in CODEX_SHELL_WRITERS), developer_instructions. `model` is never written, so Codex
    uses the session's model.

    `sandbox_mode = "read-only"` is a best-effort default, NOT an enforced least-privilege
    control: a Codex subagent inherits the parent session's sandbox, and `--yolo` or
    `/permissions` override the agent file. Codex also cannot express "no Bash" (see the
    warning below). While a read-only sandbox does apply it blocks writes through Bash too,
    which Claude's allowlist does not.
    """
    role = agent["role"]
    name = slugged(slug, role)
    lines = [f"name = {toml_basic(name)}", f"description = {toml_basic(subagent_description(role))}"]
    tools = role_tools(role)
    if tools and not {"Edit", "Write"} & set(tools):
        if role not in CODEX_SHELL_WRITERS:
            lines.append('sandbox_mode = "read-only"')
    elif tools and "Bash" not in tools:
        # Edit or Write but no Bash: Claude gives this role no shell, Codex cannot say so.
        print(f"warning: role {role} gets a shell on Codex (its allowlist has no Bash, "
              "but Codex cannot express that)", file=sys.stderr)
    lines.append(f"developer_instructions = {toml_multiline(render_subagent_body(agent, slug))}")
    return f"{name}.toml", "\n".join(lines) + "\n"


AGENT_TARGETS["codex"] = emit_codex_agent


# ── OpenCode agent emitter ────────────────────────────────────────────────────
# OpenCode reads ~/.config/opencode/agents/<name>.md (the filename is the agent id):
# YAML frontmatter with a required `description`, `mode` and an optional `permission` map,
# then the system prompt as the body. The frontmatter is written with PyYAML via
# _frontmatter(), so descriptions containing ': ' or quotes are quoted correctly.
def emit_opencode_agent(agent: dict, slug: str) -> tuple[str, str]:
    """A specialist role → one OpenCode subagent `<name>.md`. Returns (filename, contents).

    Key order is description, mode, permission. `mode` is always `subagent` (orchestrators
    are skills, never agent files). `permission` is written only when the role has a `tools:`
    allowlist AND that allowlist denies something; keys, in order:
      edit: deny     if neither Edit nor Write is listed
      bash: deny     if Bash is absent
      webfetch: deny if neither WebFetch nor WebSearch is listed
    Absent keys inherit OpenCode's default, so an allowlist becomes a PARTIAL denylist of
    edit, bash and webfetch only: every other tool (task, MCP servers, ...) keeps the default
    and the role is not read-only. `model` is never written (model ids are
    provider-specific; inheriting the session model is always valid) and neither is the
    deprecated `tools` key.
    """
    role = agent["role"]
    name = slugged(slug, role)
    fields: dict = {"description": subagent_description(role), "mode": "subagent"}
    tools = role_tools(role)
    if tools:
        allowed = set(tools)
        permission = {}
        if not {"Edit", "Write"} & allowed:
            permission["edit"] = "deny"
        if "Bash" not in allowed:
            permission["bash"] = "deny"
        if not {"WebFetch", "WebSearch"} & allowed:
            permission["webfetch"] = "deny"
        if permission:   # an allowlist that denies nothing needs no block
            fields["permission"] = permission
    # Blank line after the fence, as the Claude subagent has it.
    return f"{name}.md", _frontmatter(fields) + "\n" + render_subagent_body(agent, slug)


AGENT_TARGETS["opencode"] = emit_opencode_agent


# ── Gemini CLI agent emitter ──────────────────────────────────────────────────
# Gemini CLI reads ~/.gemini/agents/<name>.md: YAML frontmatter `name` (lowercase, digits,
# `-`, `_`), `description`, optional `tools`, then the Markdown body as the system prompt.
# `tools` is a restriction list in Gemini's own tool names, so a Claude allowlist is mapped
# name by name. `model` is never written (default `inherit`: the session's model).
GEMINI_TOOLS: dict[str, list[str]] = {
    "Read": ["read_file", "read_many_files"],
    "Grep": ["grep_search"],
    "Glob": ["glob", "list_directory"],
    "Bash": ["run_shell_command"],
    "Edit": ["replace"],
    "Write": ["write_file"],
    "WebFetch": ["web_fetch"],
    "WebSearch": ["google_web_search"],
    # Gemini CLI's skill tool (geminicli.com/docs/cli/skills: "it calls the `activate_skill` tool").
    "Skill": ["activate_skill"],
}


# The tool names a role.yaml `tools:` allowlist may use: exactly the ones GEMINI_TOOLS maps, so
# every harness can express (or knowingly narrow) each of them. Case-sensitive.
KNOWN_TOOLS = frozenset(GEMINI_TOOLS)


def check_tools(role: str, tools) -> None:
    """Exit E_TOOL_UNMAPPED unless `tools` is a non-empty list of KNOWN_TOOLS names.

    Called by every emit_*_agent. An unknown name used to be ignored on Codex and OpenCode and
    abort the whole Gemini project; an empty or malformed list used to fail OPEN (no allowlist,
    every tool inherited). load_config's lint catches these first on a normal compose
    (E_TOOL_UNKNOWN / E_FIELD_TYPE); this guards callers that reach an emitter directly."""
    if not isinstance(tools, list) or not tools:
        sys.exit(f"E_TOOL_UNMAPPED: {role}: 'tools' must be a non-empty list of tool names, got {tools!r}")
    for tool in tools:
        if not (isinstance(tool, str) and tool in KNOWN_TOOLS):
            sys.exit(f"E_TOOL_UNMAPPED: {role}: tool {tool!r} is not a known tool "
                     f"(known: {', '.join(sorted(KNOWN_TOOLS))})")


def role_tools(role: str):
    """The role's validated `tools:` allowlist, or None when it has none (inherits every tool)."""
    meta = role_meta(role)
    if "tools" not in meta:
        return None
    check_tools(role, meta["tools"])
    return meta["tools"]


def gemini_tools(role: str, tools: list[str]) -> list[str]:
    """Map a role's Claude tool allowlist to Gemini tool names, in the role's listed order,
    first occurrence wins. A tool with no mapping is a hard error (E_TOOL_UNMAPPED): silently
    dropping it would widen or narrow the role's powers without anyone noticing. Gemini's
    `tools` narrows what a subagent may call; a role that lists Bash keeps run_shell_command,
    so the list is not a read-only guarantee."""
    mapped: list[str] = []
    for tool in tools:
        if tool not in GEMINI_TOOLS:
            sys.exit(f"E_TOOL_UNMAPPED: {role}: tool {tool!r} has no Gemini CLI mapping "
                     f"(known: {', '.join(GEMINI_TOOLS)})")
        mapped += [g for g in GEMINI_TOOLS[tool] if g not in mapped]
    return mapped


def emit_gemini_agent(agent: dict, slug: str) -> tuple[str, str]:
    """A specialist role → one Gemini CLI subagent `<name>.md`. Returns (filename, contents).

    Frontmatter is name, description, then `tools` only when the role has an allowlist (a
    role without one inherits every tool, as on Claude). `tools` is a YAML block list; the
    docs say only "tool names", so a list is the natural form (group 9 confirms on a real
    install). Runs before write_harness_agents wipes anything, so an unmapped tool exits
    with the old tree intact.
    """
    role = agent["role"]
    name = slugged(slug, role)
    fields = {"name": name, "description": subagent_description(role)}
    tools = role_tools(role)
    if tools:
        fields["tools"] = gemini_tools(role, tools)
    return f"{name}.md", _frontmatter(fields) + "\n" + render_subagent_body(agent, slug)


AGENT_TARGETS["gemini-cli"] = emit_gemini_agent


# ── portable persona writer ──────────────────────────────────────────────────
# One plain-Markdown file per role (orchestrators included) for pasting into a chat-UI
# Project. Not a harness agent: no frontmatter, no tools, no permissions, so it does not
# go through AGENT_TARGETS. The lean body (empty slug, no project context) carries no
# nameplate, boot sequence or memory plumbing, hence no machine or operator values and
# no user-config override is needed.
def write_portable(name: str, config: dict, out_dir: Path) -> Path:
    """Emit <out_dir>/<name>/_portable/<role>.md for every role in the config.

    Each file is `# <Title>` + blank line + render_lean_body(agent, ""). Idempotent: the
    _portable dir is wiped and rewritten each run, so a removed role leaves no orphan.
    """
    target_dir = vet_target(out_dir, name, "_portable")
    # Render everything BEFORE anything is touched so a render error leaves the old tree untouched.
    # The portable export is public output: it must not name the private repo or its layout.
    # Role sources keep the real path (the agents need it); only this export swaps in a
    # placeholder the reader can map to their own private directory.
    rendered = [
        (f"{agent['role']}.md",
         (f"# {role_meta(agent['role']).get('title') or agent['role']}\n\n"
          + render_lean_body(agent, "")).replace("~/.the-grid-private/", "<private-dir>/"))
        for agent in config["agents"]
    ]
    install_tree(target_dir, dict(rendered))
    return target_dir


# ── paperclip emitter ─────────────────────────────────────────────────────────
# A third emit target: render a deploy-ready manifest for a live Paperclip
# instance. Pure rendering only — no network calls, no talking to a Paperclip
# API. A later deploy script (agent-factory/scripts/deploy_paperclip.py, see
# agent-factory/openclaw/README.md Session A2) walks this manifest and
# does the actual POST/PATCH.
#
# The Paperclip roster is a curated subset of the team, fixed by the plan doc:
# ceo-orchestrator + tech-lead + tech-lead's reports + growth-hacker + its
# reports + product-manager (a direct CEO report, currently a leaf role with no
# delegates_to of its own — included as-is; if it grows reports later they'd be
# pulled in the same way tech-lead/growth-hacker's are). finance-manager (and
# its subtree) is explicitly out of scope for this phase — pulled in as named
# roots only, never by recursing through ceo-orchestrator's full delegates_to
# (which would also capture its finance-manager delegate).
PAPERCLIP_LEAD_ROLES = ["tech-lead", "growth-hacker", "product-manager"]
PAPERCLIP_APEX_ROLE = "ceo-orchestrator"


def paperclip_roster(config: dict) -> list[dict]:
    """The confirmed Paperclip roster (see module docstring above): the apex
    orchestrator + each lead role + that lead's own delegates_to (empty for a
    leaf role like product-manager). Returns the agent dicts in their original
    compose-config order (not yet topological — see topological_roster)."""
    by_role = {a["role"]: a for a in config["agents"] if isinstance(a, dict) and a.get("role")}
    # A config without the apex, or with none of the leads, has no Paperclip roster: say so
    # instead of a KeyError. A lead that is merely absent is skipped.
    leads = [lead for lead in PAPERCLIP_LEAD_ROLES if lead in by_role]
    if PAPERCLIP_APEX_ROLE not in by_role or not leads:
        sys.exit(f"error: paperclip needs role {PAPERCLIP_APEX_ROLE} and at least one of "
                 f"{', '.join(PAPERCLIP_LEAD_ROLES)} in this config")
    roster_roles = {PAPERCLIP_APEX_ROLE}
    for lead in leads:
        roster_roles.add(lead)
        roster_roles.update(by_role[lead].get("delegates_to") or [])
    return [a for a in config["agents"] if a.get("role") in roster_roles]


def paperclip_parent_map(config: dict) -> dict[str, str]:
    """role -> the first role whose delegates_to names it as a report. Built
    from the whole config (not just the Paperclip roster) so a roster role's
    real parent is always found; a role nobody delegates to (the apex) is
    simply absent, giving reportsTo: null."""
    parent: dict[str, str] = {}
    for a in config["agents"]:
        for child in a.get("delegates_to") or []:
            parent.setdefault(child, a["role"])
    return parent


def topological_roster(roster: list[dict], parent_map: dict[str, str]) -> list[dict]:
    """Order the roster so every agent's parent appears before it, regardless
    of the order roles happen to be listed in the compose config. A deploy
    script can then walk the list once and always resolve reportsTo from an
    already-seen (and by then already-created) parent."""
    by_role = {a["role"]: a for a in roster}
    ordered: list[dict] = []
    placed: set[str] = set()

    def place(role: str) -> None:
        if role in placed or role not in by_role:
            return
        parent = parent_map.get(role)
        if parent:
            place(parent)
        placed.add(role)
        ordered.append(by_role[role])

    for agent in roster:
        place(agent["role"])
    return ordered


def paperclip_capabilities(role: str) -> str:
    """The 'capabilities' blurb: role.yaml `owns:` if set, else the full
    (whitespace-normalized) `summary`."""
    meta = role_meta(role)
    owns = meta.get("owns")
    return " ".join(owns.split()) if owns else role_summary(role)


def paperclip_payload(agent: dict, parent_map: dict[str, str], slug: str) -> dict:
    """One agent-hire payload: identity + skills + placeholder reportsTo.
    instructionsBundle.files carries the unflattened 5-file render_agent()
    output directly — Paperclip's instructionsBundle takes a
    {filename: content} map, so no flattening step (unlike the CC target)."""
    role = agent["role"]
    meta = role_meta(role)
    title = meta.get("title") or role
    return {
        # The raw role key — the join key deploy_paperclip.py uses to resolve
        # reportsTo (also a role key) to an already-created parent's real UUID.
        # Not itself sent to Paperclip's API; "name"/"title" below are.
        "role": role,
        "name": agent.get("name") or title,
        "title": title,
        "capabilities": paperclip_capabilities(role),
        "adapterType": "claude_local",
        "instructionsBundle": {
            "entryFile": "AGENTS.md",
            "files": render_agent(agent, slug=slug),
        },
        "desiredSkills": agent_skills(agent),
        # Placeholder — a role name, not a UUID. Paperclip agents don't exist
        # yet at render time; deploy_paperclip.py resolves this to the real
        # UUID of the already-created parent (topological order guarantees
        # the parent was processed first).
        "reportsTo": parent_map.get(role),
    }


def write_paperclip(name: str, config: dict, out_dir: Path) -> Path:
    """Emit the Paperclip roster as a deploy-ready manifest under
    <out_dir>/<name>/_paperclip/manifest.json. Idempotent: the _paperclip dir
    is wiped and rewritten each run, same as write_claude_code/write_project.
    Pure rendering — no network calls anywhere in this path.
    """
    slug = config.get("slug") or name
    roster = paperclip_roster(config)
    parent_map = paperclip_parent_map(config)
    ordered = topological_roster(roster, parent_map)

    pc_dir = vet_target(out_dir, name, "_paperclip")
    manifest = [paperclip_payload(agent, parent_map, slug) for agent in ordered]
    install_tree(pc_dir, {
        "manifest.json": json.dumps(manifest, indent=2, ensure_ascii=False) + "\n"})
    return pc_dir


# ── openclaw-native emitter ───────────────────────────────────────────────────
# A fourth emit target: render the 9-file workspace set (see
# openclaw/README.md, Session B1) for the curated 5 grid orchestrator roles
# named in openclaw/roster.json. Pure rendering only — no docker exec, no
# writes under ~/.openclaw (that's agent-factory/scripts/deploy_openclaw.sh,
# Session B3, per agent-factory/openclaw/README.md).
#
# Named "openclaw-native" (not "openclaw") because that name is already taken
# by the legacy default target (write_project below) — the bare 5-file dump
# with no template wrapping. Both remain selectable; this one is additive.

# Templates whose entire body is a single {{RENDERED_CONTENT}} token, filled
# verbatim from render_agent()'s own output — same 5-file identity model the
# claude-code and default openclaw targets already use. No new merge logic.
OPENCLAW_PASSTHROUGH_FILES = ["IDENTITY.md", "SOUL.md", "AGENTS.md", "USER.md", "MEMORY.md"]


def _openclaw_roster_all() -> dict:
    """The full 5-role orchestrator target from openclaw/roster.json."""
    return json.loads(_read(OPENCLAW_DIR / "roster.json"))["orchestrators"]


def openclaw_roster_roles(config: dict) -> list[str]:
    """roster.json's orchestrator role keys that are ALSO present as an agent
    in this compose config, in roster.json's declared order. roster.json names
    the fixed 5-role rollout target; a given project's config may only compose
    a subset (e.g. the-grid's own grid.yaml may lack some of them) — those are
    skipped here, not treated as an error (see openclaw_missing_roles)."""
    team_roles = {a["role"] for a in config["agents"] if isinstance(a, dict) and a.get("role")}
    return [role for role in _openclaw_roster_all() if role in team_roles]


def openclaw_missing_roles(config: dict) -> list[str]:
    """roster.json's orchestrator roles NOT present in this compose config —
    reported by the CLI, not an error (see openclaw_roster_roles)."""
    team_roles = {a["role"] for a in config["agents"] if isinstance(a, dict) and a.get("role")}
    return [role for role in _openclaw_roster_all() if role not in team_roles]


def render_openclaw_role(agent: dict, slug: str) -> dict[str, str]:
    """Render the 9-file OpenClaw workspace set for one orchestrator agent.
    Returns {filename: contents}, ready to write under _openclaw/<role>/."""
    role = agent["role"]
    meta = role_meta(role)
    rendered = render_agent(agent, slug=slug)

    files: dict[str, str] = {}
    for filename in OPENCLAW_PASSTHROUGH_FILES:
        template = _read(OPENCLAW_TEMPLATES_DIR / filename)
        files[filename] = template.replace("{{RENDERED_CONTENT}}", rendered[filename])

    # EXPERTISE.md: the role's own SKILL.md, ported verbatim (not from
    # render_agent() — that function has no EXPERTISE.md key).
    expertise_template = _read(OPENCLAW_TEMPLATES_DIR / "EXPERTISE.md")
    role_skill = _read(role_dir(role) / "SKILL.md")
    files["EXPERTISE.md"] = expertise_template.replace("{{ROLE_SKILL_CONTENT}}", role_skill)

    # BOOT/TOOLS/HEARTBEAT: role_meta()-derived tokens (see openclaw/README.md
    # token reference). All three are substituted the same way — whichever
    # tokens a given template doesn't use simply have nothing to replace.
    subs = {
        "{{ORCH_ROLE}}": role,
        "{{ORCH_TITLE}}": meta.get("title") or role,
        "{{ORCH_SUMMARY}}": role_summary(role),
    }
    for filename in ("BOOT.md", "TOOLS.md", "HEARTBEAT.md"):
        text = _read(OPENCLAW_TEMPLATES_DIR / filename)
        for token, value in subs.items():
            text = text.replace(token, value)
        files[filename] = text

    return files


def write_openclaw(name: str, config: dict, out_dir: Path) -> Path:
    """Emit the OpenClaw 9-file workspace set under
    <out_dir>/<name>/_openclaw/<role>/, one dir per roster.json orchestrator
    role that is present in this compose config. Idempotent: the _openclaw dir
    is wiped and rewritten each run, same as the other emitters. Pure
    rendering — no docker exec, no ~/.openclaw writes anywhere in this path.
    """
    slug = config.get("slug") or name
    by_role = {a["role"]: a for a in config["agents"] if isinstance(a, dict) and a.get("role")}

    oc_dir = vet_target(out_dir, name, "_openclaw")
    files: dict[str, str] = {}
    for role in openclaw_roster_roles(config):
        for filename, contents in render_openclaw_role(by_role[role], slug).items():
            files[f"{role}/{filename}"] = contents
    install_tree(oc_dir, files)
    return oc_dir


# ── writing ───────────────────────────────────────────────────────────────────

def write_project(name: str, config: dict, out_dir: Path) -> Path:
    """Write the rendered team under <out_dir>/<name>/. Idempotent.

    This target's own output (every top-level entry not starting with '_') is replaced each
    run — the result reflects the config exactly, and a re-run with an unchanged config
    produces byte-identical files. The _<target> dirs the other targets write beside it
    (and that wire.sh symlinks into ~/.claude) are never touched. The target is vetted to
    a real dir under out_dir (never a symlink) first; see vet_target / install_project.
    """
    project_dir = vet_target(out_dir, name)
    files: dict[str, str] = {}
    for agent in config["agents"]:
        for filename, contents in render_agent(agent).items():
            files[f"{agent['role']}/{filename}"] = contents
    files["agents.yaml"] = render_agents_yaml(config)
    install_project(project_dir, files)
    return project_dir


# ── role lint ─────────────────────────────────────────────────────────────────
# Fail-closed validation of a role's source files, independent of any compose
# config. Every finding carries a stable code so tests (and humans grepping CI
# output) can match the exact failure mode, and every finding names the file.
ROLE_YAML_KEYS = {"name", "title", "summary", "owns", "default_model", "cron_model",
                  "base_skills", "orchestrator", "tools", "unattended", "model_rationale",
                  "description"}
ROLE_MODELS = {"opus", "sonnet", "haiku", "fable"}


def lint_role(role: str) -> list[str]:
    """All problems with one role's source files, as 'CODE: role/file: detail'."""
    # Checked before any path is built: a name like '../x' must never be looked up, and a name the
    # harnesses reject (upper case, spaces) must not compose and fail later.
    if not valid_role_name(role):
        shown = role if isinstance(role, str) and role.isprintable() else repr(role)
        return [f"E_ROLE_NAME: {shown}: role names are lowercase letters, digits, '-' and '_', "
                "start with a letter or digit, at most 64 chars"]
    rdir = role_dir(role)
    if not rdir.is_dir():
        return [f"E_ROLE_MISSING: {role}: no directory at {rdir}"]
    out: list[str] = []

    def bad(code: str, fname: str, detail: str) -> None:
        out.append(f"{code}: {role}/{fname}: {detail}")

    for fname in REQUIRED_ROLE_FILES:
        f = rdir / fname
        if not f.is_file():
            bad("E_FILE_MISSING", fname, "required file absent")
        elif not f.read_text(encoding="utf-8").strip():
            bad("E_FILE_EMPTY", fname, "required file is empty")

    ry = rdir / "role.yaml"
    if not ry.is_file():
        bad("E_YAML_MISSING", "role.yaml", "required file absent")
    else:
        try:
            meta = yaml.safe_load(ry.read_text(encoding="utf-8")) or {}
        except yaml.YAMLError as exc:
            bad("E_YAML_PARSE", "role.yaml", str(exc).splitlines()[0])
            meta = None
        if meta is not None and not isinstance(meta, dict):
            bad("E_YAML_SHAPE", "role.yaml", "must be a mapping")
        elif meta is not None:
            if meta.get("name") != role:
                bad("E_NAME_MISMATCH", "role.yaml", f"name {meta.get('name')!r} != directory {role!r}")
            for key in ("title", "summary"):
                if not str(meta.get(key) or "").strip():
                    bad("E_FIELD_MISSING", "role.yaml", f"'{key}' is required")
            for key in sorted(set(meta) - ROLE_YAML_KEYS):
                bad("E_FIELD_UNKNOWN", "role.yaml", f"unknown key '{key}' (typo?)")
            for key in ("default_model", "cron_model"):
                if key in meta and meta[key] not in ROLE_MODELS:
                    bad("E_MODEL_INVALID", "role.yaml", f"{key} {meta[key]!r} not in {sorted(ROLE_MODELS)}")
            if not isinstance(meta.get("orchestrator", False), bool):
                bad("E_FIELD_TYPE", "role.yaml", "'orchestrator' must be true/false")
            if not isinstance(meta.get("base_skills", []) or [], list):
                bad("E_FIELD_TYPE", "role.yaml", "'base_skills' must be a list")
            if "model_rationale" in meta and not isinstance(meta["model_rationale"], str):
                bad("E_FIELD_TYPE", "role.yaml", "'model_rationale' must be text")
            if meta.get("default_model", DEFAULT_MODEL) != DEFAULT_MODEL and not str(meta.get("model_rationale") or "").strip():
                bad("E_MODEL_RATIONALE_MISSING", "role.yaml",
                    f"default_model {meta.get('default_model')!r} differs from the {DEFAULT_MODEL!r} default: say why in 'model_rationale'")
            if not isinstance(meta.get("unattended", False), bool):
                bad("E_FIELD_TYPE", "role.yaml", "'unattended' must be true/false")
            # Text that reaches generated files: a control character other than tab/newline is
            # invalid in TOML (Codex strips it, so output would differ per harness) and has no
            # place in a one-line description.
            for key in ("description", "title", "summary"):
                if isinstance(meta.get(key), str) and any(
                        (c < " " and c not in "\t\n") or c == "\x7f" for c in meta[key]):
                    bad("E_TEXT_CONTROL", "role.yaml",
                        f"'{key}' contains a control character (only tab and newline are allowed)")
            if "tools" in meta:
                tools = meta["tools"]
                if not (isinstance(tools, list) and tools and all(isinstance(t, str) and t.strip() and "," not in t for t in tools)):
                    bad("E_FIELD_TYPE", "role.yaml", "'tools' must be a non-empty list of tool names (no commas)")
                else:
                    for t in tools:
                        if t not in KNOWN_TOOLS:
                            bad("E_TOOL_UNKNOWN", "role.yaml",
                                f"tool {t!r} is not one of: {', '.join(sorted(KNOWN_TOOLS))} (case-sensitive)")
                if meta.get("orchestrator", False):
                    bad("E_TOOLS_ON_ORCHESTRATOR", "role.yaml",
                        "'tools' only narrows subagents; orchestrators deploy as skills and would silently ignore it")

    # Unresolved {{TOKENS}}: only AGENTS.md may carry the roster slot.
    for f in sorted(rdir.glob("*.md")):
        for tok in sorted(set(re.findall(r"\{\{[A-Za-z_]+\}\}", strip_html_comments(f.read_text(encoding="utf-8"))))):
            if not (f.name == "AGENTS.md" and tok == "{{ROSTER_TABLE}}"):
                bad("E_TOKEN_UNRESOLVED", f.name, f"unresolved placeholder {tok}")
    return out


DESCRIPTION_WARN_CHARS = 250   # per_entry_max_chars in docs/budget-target.json


def lint_warnings(role: str) -> list[str]:
    """Non-fatal findings for one role: printed by --lint-roles, never counted as problems."""
    if not valid_role_name(role) or not role_dir(role).is_dir():
        return []
    try:
        desc = subagent_description(role)
    except Exception:   # a malformed role.yaml is reported by lint_role, not here
        return []
    if len(desc) > DESCRIPTION_WARN_CHARS:
        return [f"W_DESCRIPTION_LONG: {role}/role.yaml: description is {len(desc)} chars "
                f"(over {DESCRIPTION_WARN_CHARS}, the per-entry budget cap)"]
    return []


def lint_decision_brief(path: Path = CORE_DIR / "DECISION_BRIEF.md") -> list[str]:
    """Problems with the shared decision-brief fragment: missing, over 1500 bytes, or
    without the `D<N>` label that the format (and the evals) key on."""
    if not path.is_file():
        return [f"E_DECISION_BRIEF: {path.name}: missing"]
    data = path.read_bytes()
    if len(data) > 1500:
        return [f"E_DECISION_BRIEF: {path.name}: {len(data)} bytes, over the 1500 cap"]
    if "D<N>" not in data.decode("utf-8", errors="replace"):
        return [f"E_DECISION_BRIEF: {path.name}: lacks the D<N> label"]
    return []


def lint_models() -> list[str]:
    """Problems with models.yaml: unknown tier names or non-string values, in either section."""
    if not MODELS_FILE.is_file():
        return []
    try:
        data = yaml.safe_load(MODELS_FILE.read_text(encoding="utf-8")) or {}
    except yaml.YAMLError as exc:
        return [f"E_MODELS_FILE: models.yaml: {str(exc).splitlines()[0]}"]
    if not isinstance(data, dict) or not isinstance(data.get("tiers"), dict):
        return ["E_MODELS_FILE: models.yaml: needs a 'tiers:' mapping"]
    out = []
    for section in MODEL_SECTIONS:
        tiers = data.get(section)
        if tiers is None:
            continue
        if not isinstance(tiers, dict):
            out.append(f"E_MODELS_FILE: models.yaml: '{section}' must be a mapping")
            continue
        for tier, value in tiers.items():
            if tier not in ROLE_MODELS:
                out.append(f"E_MODEL_INVALID: models.yaml: unknown tier {tier!r} in '{section}' (expected one of {sorted(ROLE_MODELS)})")
            elif not (isinstance(value, str) and value.strip()):
                out.append(f"E_MODELS_FILE: models.yaml: '{section}' tier {tier!r} needs a non-empty model string")
    return out


# ── authoring-contract lint ───────────────────────────────────────────────────
# Roles listed in authored-roles.txt (one per line, '#' comments) have been through
# the pass described in docs/role-authoring.md and must keep meeting its contract.
# Opt-in by list, not by role.yaml, so converting a role never touches role.yaml.
AUTHORED_ROLES_FILE = Path(os.environ.get("GRID_AUTHORED_ROLES_FILE") or HERE / "authored-roles.txt")
AGENTS_MAX_BYTES = 4096
ORCHESTRATOR_MAX_BYTES = 5120   # orchestrators carry Roster + Delegation + Routing as well; rules stay inline, not in a linked file
# The shared four, as keyword groups checked against a role's "Hard rules" text. Presence only: wording is
# the role's own (see docs/role-authoring.md), so this catches a deleted rule, not a badly worded one.
SHARED_FOUR = [
    ("verify before claiming (or accepting)", r"verif|evidence"),
    ("exists vs planned", r"planned|not (?:yet )?(?:built|tested|measured|shipped)"),
    ("failures verbatim", r"verbatim"),
    ("independent check / not your own homework", r"independent|different role|homework|self-check"),
]
# Extra rules for a role that sets `unattended: true`.
UNATTENDED_RULES = [
    ("a safe-target step (dry run / preview) before any outward write", r"dry[- ]run|safe[- ]target|preview"),
    ("one run-record line per run (scripts/run-record.sh)", r"run[- ]record"),
]
SOUL_HEADINGS_RE = [
    r"Role identity", r"Core character \(role layer\)", r"Decision-making \(role layer\)",
    r"Escalation rules \(role layer\)", r"Working style \(role layer\)", r"What (?:the )?.+ is NOT",
]


def authored_roles() -> set[str]:
    if not AUTHORED_ROLES_FILE.is_file():
        return set()
    lines = (ln.split("#", 1)[0].strip() for ln in AUTHORED_ROLES_FILE.read_text(encoding="utf-8").splitlines())
    return {ln for ln in lines if ln}


def lint_authoring(role: str) -> list[str]:
    """Contract problems for an authored role (see docs/role-authoring.md)."""
    rdir = role_dir(role)
    out: list[str] = []

    def bad(code: str, fname: str, detail: str) -> None:
        out.append(f"{code}: {role}/{fname}: {detail}")

    agents = rdir / "AGENTS.md"
    if not agents.is_file():
        return [f"E_SECTION_MISSING: {role}/AGENTS.md: required for authored roles"]
    text = agents.read_text(encoding="utf-8")
    try:
        meta = role_meta(role)
    except yaml.YAMLError:
        meta = {}   # lint_role already reports E_YAML_PARSE for this file; don't crash a second time
    if not isinstance(meta, dict):
        meta = {}   # a string/list role.yaml: lint_role reports E_YAML_SHAPE; don't call .get on it
    orchestrator = bool(meta.get("orchestrator", False))   # orchestrator variant: gates others' work; no 'Receiving work', bigger cap
    max_bytes = ORCHESTRATOR_MAX_BYTES if orchestrator else AGENTS_MAX_BYTES
    if len(text.encode("utf-8")) > max_bytes:
        bad("E_SIZE", "AGENTS.md", f"over {max_bytes} bytes (a role this big is two roles)")
    _, secs = split_sections(strip_html_comments(text))
    heads = {h[3:].strip(): b for h, b in secs}
    for need in ("Scope", "Hard rules") + (() if orchestrator else ("Receiving work",)):
        if need not in heads:
            bad("E_SECTION_MISSING", "AGENTS.md", f"'## {need}'")
    hardest = [b for h, b in heads.items() if re.fullmatch(r"What to .+ hardest", h)]
    if not hardest:
        bad("E_SECTION_MISSING", "AGENTS.md", "'## What to get right hardest' (or 'What to <verb> hardest')")
    elif len(re.findall(r"^\s*\d+\.\s", hardest[0], re.M)) < 4:
        bad("E_SECTION_SHAPE", "AGENTS.md", "'What to … hardest' needs a ranked numbered list of at least 4 items")
    if "Hard rules" in heads and len(re.findall(r"^\s*(?:[-*]|\d+\.)\s", heads["Hard rules"], re.M)) < 4:
        bad("E_SECTION_SHAPE", "AGENTS.md", "'Hard rules' needs at least 4 rules (the shared four plus role-specific)")
    if "Hard rules" in heads:
        rules = heads["Hard rules"]
        for label, pat in SHARED_FOUR:
            if not re.search(pat, rules, re.I):
                bad("E_SHARED_RULE_MISSING", "AGENTS.md", f"'Hard rules' no longer covers: {label}")
        if meta.get("unattended", False):
            for label, pat in UNATTENDED_RULES:
                if not re.search(pat, rules, re.I):
                    bad("E_UNATTENDED_RULE_MISSING", "AGENTS.md", f"unattended role's 'Hard rules' needs: {label}")

    soul = rdir / "SOUL.md"
    soul_heads = [h[3:].strip() for h, _ in split_sections(strip_html_comments(_read(soul)))[1]] if soul.is_file() else []
    for pat in SOUL_HEADINGS_RE:
        if not any(re.fullmatch(pat, h) for h in soul_heads):
            bad("E_SECTION_MISSING", "SOUL.md", f"heading matching '## {pat}'")
    return out


def all_roles() -> list[str]:
    """Every role dir name visible to the factory (private tree merged over public)."""
    # Dirs starting with '_' or '.' (e.g. roles/_retired/) are an archive: kept for
    # history and rollback, never linted, composed or deployed.
    def live(root: Path) -> set[str]:
        return {d.name for d in root.iterdir() if d.is_dir() and not d.name.startswith(("_", "."))}
    names = live(ROLES_DIR)
    if PRIVATE_ROLES_DIR and PRIVATE_ROLES_DIR.is_dir():
        names |= live(PRIVATE_ROLES_DIR)
    return sorted(names)


# ── drift check ───────────────────────────────────────────────────────────────
def _tree(root: Path, skip_top: str = "") -> dict[str, bytes]:
    """{relative path: bytes} for everything under root ({} if root is absent).

    Beyond regular files: a symlink is recorded as `symlink -> <target>` (never followed), an
    empty dir as `<rel>/` and any other special file as a marker, so diff_trees can report them;
    a symlinked root is a single `.` entry. `skip_top` drops top-level entries with that prefix
    (the legacy target ignores its siblings' `_<target>` dirs).
    """
    if root.is_symlink():
        return {".": b"symlink -> " + os.readlink(root).encode()}
    if not root.is_dir():
        return {}
    out: dict[str, bytes] = {}
    for dirpath, dirnames, filenames in os.walk(root, followlinks=False):
        here = Path(dirpath)
        if here == root and skip_top:
            dirnames[:] = [d for d in dirnames if not d.startswith(skip_top)]
            filenames = [f for f in filenames if not f.startswith(skip_top)]
        dirnames.sort()
        if here != root and not dirnames and not filenames:
            out[f"{here.relative_to(root)}/"] = b"empty dir"
        for d in dirnames:                       # a symlinked dir is listed here, not descended
            if (here / d).is_symlink():
                out[str((here / d).relative_to(root))] = b"symlink -> " + os.readlink(here / d).encode()
        for f in sorted(filenames):
            path = here / f
            rel = str(path.relative_to(root))
            mode = os.lstat(path).st_mode
            if stat.S_ISLNK(mode):
                out[rel] = b"symlink -> " + os.readlink(path).encode()
            elif stat.S_ISREG(mode):
                out[rel] = path.read_bytes()
            else:
                out[rel] = b"special file"
    return out


def diff_trees(expected: Path, actual: Path, skip_top: str = "") -> list[str]:
    """Human-readable differences between a freshly rendered tree and the one on disk."""
    exp, act = _tree(expected), _tree(actual, skip_top)
    problems = [f"missing   {rel}" for rel in sorted(exp.keys() - act.keys())]
    problems += [f"unexpected {rel}" for rel in sorted(act.keys() - exp.keys())]
    problems += [f"stale     {rel}" for rel in sorted(exp.keys() & act.keys()) if exp[rel] != act[rel]]
    return problems


# ── cli ───────────────────────────────────────────────────────────────────────

def main() -> None:
    parser = argparse.ArgumentParser(description="Compose an AI dev-team agent.")
    parser.add_argument("config", type=Path, nargs="?", help="path to the compose config yaml")
    parser.add_argument("--out", type=Path, default=PROJECTS_DIR, help="output dir")
    parser.add_argument(
        "--target",
        choices=["openclaw", "claude-code", "paperclip", "openclaw-native", "portable", *sorted(AGENT_TARGETS)],
        default="openclaw",
        help="emit shape: openclaw = 5 files + agents.yaml (default, legacy bare dump); "
             "claude-code = CC skills (orchestrators) + subagents (specialists); "
             "paperclip = _paperclip/manifest.json for the curated Paperclip roster; "
             "openclaw-native = _openclaw/<role>/ 9-file workspace set for roster.json's "
             "5 orchestrator roles (whichever are present in this config); "
             "portable = _portable/<role>.md plain-Markdown persona per role, orchestrators included",
    )
    parser.add_argument(
        "--lint-roles", action="store_true",
        help="lint every role's source files (config argument is ignored); "
             "exit 1 if any role is malformed",
    )
    parser.add_argument(
        "--check", action="store_true",
        help="render into a temp dir and diff against what is on disk; write nothing, "
             "exit 1 if the composed output is missing or stale",
    )
    parser.add_argument(
        "--dry-run", action="store_true",
        help="render + report what would be written, but write nothing",
    )
    args = parser.parse_args()

    if args.lint_roles:
        problems = [p for r in all_roles() for p in lint_role(r)]
        problems += [p for r in sorted(authored_roles() & set(all_roles())) for p in lint_authoring(r)]
        problems += lint_models()
        problems += lint_decision_brief()
        for r in all_roles():
            for w in lint_warnings(r):
                print(w, file=sys.stderr)
        for p in problems:
            print(p, file=sys.stderr)
        print(f"lint-roles: {len(all_roles())} roles, {len(problems)} problem(s)")
        sys.exit(1 if problems else 0)
    if args.config is None:
        parser.error("config is required (unless --lint-roles)")

    try:
        config = load_config(args.config)
    except ValueError as exc:
        sys.exit(str(exc))

    name = config["project"]
    agents = config["agents"]

    if args.check:
        import tempfile
        writers = {
            "claude-code": write_claude_code, "paperclip": write_paperclip,
            "openclaw-native": write_openclaw, "openclaw": write_project,
            "portable": write_portable,
            **{t: functools.partial(write_harness_agents, t) for t in AGENT_TARGETS},
        }
        with tempfile.TemporaryDirectory() as tmp:
            rendered = writers[args.target](name, config, Path(tmp))
            on_disk = args.out / rendered.relative_to(tmp)
            # Write mode refuses a symlinked project dir (vet_target); --check must too, else a
            # link to an identical copy reads as "up to date" while a real compose would refuse.
            if (args.out / name).is_symlink():
                print(f"STALE '{name}' ({args.target}): {args.out / name} is a symlink, not a dir",
                      file=sys.stderr)
                sys.exit(1)
            # The legacy target shares <project>/ with its siblings' _<target> dirs: ignore them.
            problems = diff_trees(rendered, on_disk, skip_top="_" if args.target == "openclaw" else "")
        if problems:
            print(f"STALE '{name}' ({args.target}): {on_disk}", file=sys.stderr)
            for line in problems:
                print(f"  {line}", file=sys.stderr)
            print("  fix: re-run compose.py without --check", file=sys.stderr)
            sys.exit(1)
        print(f"up to date '{name}' ({args.target})")
        return

    if args.dry_run:
        slug = config.get("slug") or name
        print(f"[dry-run] target={args.target}  project: {name}  slug: {slug}  ({len(agents)} agents) -> {args.out / name}")
        if args.target == "paperclip":
            parent_map = paperclip_parent_map(config)
            ordered = topological_roster(paperclip_roster(config), parent_map)
            for agent in ordered:
                role = agent["role"]
                print(f"  - {role:<20} model={resolve_model(agent):<8} reportsTo={parent_map.get(role)}")
            print(f"[dry-run] {len(ordered)} agents -> _paperclip/manifest.json")
            return
        if args.target == "openclaw-native":
            by_role = {a["role"]: a for a in agents if isinstance(a, dict) and a.get("role")}
            roles = openclaw_roster_roles(config)
            missing = openclaw_missing_roles(config)
            for role in roles:
                print(f"  - {role:<20} model={resolve_model(by_role[role]):<8} -> _openclaw/{role}/*.md (9 files)")
            print(f"[dry-run] {len(roles)} of 5 roster.json roles rendered -> _openclaw/<role>/")
            if missing:
                print(f"[dry-run] not in this compose config, skipped: {', '.join(missing)}")
            return
        if args.target == "portable":
            for agent in agents:
                print(f"  - {agent['role']:<20} -> _portable/{agent['role']}.md")
            print(f"[dry-run] {len(agents)} personas -> _portable/")
            return
        if args.target in AGENT_TARGETS:
            # Harness agent target: specialists only, one file each (orchestrators are skipped).
            n = 0
            for agent in agents:
                if is_orchestrator(agent["role"]):
                    continue
                filename, _ = AGENT_TARGETS[args.target](agent, agent_slug(agent, cc_slug(config, name)))
                print(f"  - {agent['role']:<20} -> _{args.target}/agents/{filename}")
                n += 1
            print(f"[dry-run] {n} specialists -> _{args.target}/agents/")
            return
        for agent in agents:
            role = agent["role"]
            if args.target == "claude-code":
                slugged_name = slugged(agent_slug(agent, cc_slug(config, name)), role)
                shape = "skill (orchestrator)" if is_orchestrator(role) else "subagent (specialist)"
                print(f"  - {slugged_name:<32} model={resolve_model(agent):<8} -> CC {shape}")
            else:
                files = ", ".join(sorted(render_agent(agent)))
                print(f"  - {role:<16} model={resolve_model(agent):<8} files: {files}")
                print(f"      skills: {', '.join(agent_skills(agent))}")
        if args.target == "openclaw":
            print("[dry-run] + agents.yaml")
        return

    if args.target == "claude-code":
        cc_dir = write_claude_code(name, config, args.out)
        slug = cc_slug(config, name)
        # Counts come from what was written, not from the input list.
        n_cc = sum(len(os.listdir(cc_dir / sub)) for sub in ("skills", "agents"))
        print(f"composed '{name}' (claude-code): {n_cc} agents -> {cc_dir}")
        for agent in agents:
            role = agent["role"]
            slugged_name = slugged(agent_slug(agent, slug), role)
            shape = "skill" if is_orchestrator(role) else "subagent"
            print(f"  - {slugged_name} ({resolve_model(agent)}) -> CC {shape}")
        return

    if args.target in AGENT_TARGETS:
        ha_dir = write_harness_agents(args.target, name, config, args.out)
        n = len(list((ha_dir / "agents").iterdir()))
        print(f"composed '{name}' ({args.target}): {n} specialists -> {ha_dir}/agents/")
        return

    if args.target == "portable":
        pp_dir = write_portable(name, config, args.out)
        print(f"composed '{name}' (portable): {len(os.listdir(pp_dir))} personas -> {pp_dir}")
        return

    if args.target == "paperclip":
        pc_dir = write_paperclip(name, config, args.out)
        parent_map = paperclip_parent_map(config)
        ordered = topological_roster(paperclip_roster(config), parent_map)
        print(f"composed '{name}' (paperclip): {len(ordered)} agents -> {pc_dir}")
        for agent in ordered:
            role = agent["role"]
            print(f"  - {role} ({resolve_model(agent)})  reportsTo={parent_map.get(role)}")
        return

    if args.target == "openclaw-native":
        oc_dir = write_openclaw(name, config, args.out)
        roles = openclaw_roster_roles(config)
        missing = openclaw_missing_roles(config)
        print(f"composed '{name}' (openclaw-native): {len(roles)} of 5 roster.json roles -> {oc_dir}")
        for role in roles:
            print(f"  - {role}/  (9 files)")
        if missing:
            print(f"  not in this compose config, skipped: {', '.join(missing)}")
        return

    project_dir = write_project(name, config, args.out)
    n_roles = sum(1 for e in os.listdir(project_dir) if (project_dir / e).is_dir() and not e.startswith("_"))
    print(f"composed '{name}': {n_roles} agents -> {project_dir}")
    for agent in agents:
        print(f"  - {agent['role']} ({resolve_model(agent)})  skills: {', '.join(agent_skills(agent))}")


if __name__ == "__main__":
    main()
