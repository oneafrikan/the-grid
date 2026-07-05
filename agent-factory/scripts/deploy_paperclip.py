#!/usr/bin/env python3
"""deploy_paperclip.py — walk a compose.py --target=paperclip manifest and make
it live in a real Paperclip company.

Session A2 of docs/openclaw-paperclip-targets-plan.md. This script is the
DEPLOY half of the Paperclip target (compose.py's write_paperclip() is the
pure-rendering half, Session A1). It is idempotent by construction: running it
twice against the same manifest and the same company state issues zero
mutating calls on the second run.

SAFETY: by default this script only ever prints what it *would* send. No
POST/PATCH/PUT is sent to a live Paperclip instance unless you pass
--i-mean-it explicitly. GET calls are always real (read-only) so dry-run
output reflects true company state. `--self-test` runs entirely offline
against an in-memory fixture and touches no network at all — use it to sanity
check the hire/patch branching and reportsTo-resolution logic without a live
company at hand.

Company creation is deliberately NOT implemented here. Paperclip's
POST /api/companies/ requires a board-authenticated actor (assertBoard() in
companies.ts) — an agent API key (the only credential this script has) is
rejected outright regardless of that key's permissions. So there is no
"--create-company" flag: this script always operates against an existing
PAPERCLIP_COMPANY_ID. Creating "The Grid" company (per the plan doc) is a
human-in-the-console (or board-key) action that happens once, out of band,
before this script's agent step can do anything for real.

Env vars (only required for a live run, not for --self-test):
    PAPERCLIP_API_URL      e.g. http://127.0.0.1:3100
    PAPERCLIP_API_KEY      an agent API key (Authorization: Bearer ...)
    PAPERCLIP_COMPANY_ID   uuid of the target company

Usage:
    deploy_paperclip.py [--manifest PATH] [--dry-run | --i-mean-it]
                        [--skills-only | --agents-only] [--self-test]
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import urllib.error
import urllib.request
import uuid
from pathlib import Path
from typing import Any, Optional

SCRIPT_DIR = Path(__file__).resolve().parent
AGENT_FACTORY_DIR = SCRIPT_DIR.parent
GRID_DIR = AGENT_FACTORY_DIR.parent
DEFAULT_MANIFEST = AGENT_FACTORY_DIR / "projects" / "grid" / "_paperclip" / "manifest.json"

# ── role mapping ──────────────────────────────────────────────────────────────
# Paperclip's agent-hire schema (createAgentHireSchema in
# packages/shared/src/validators/agent.ts) constrains `role` to a fixed
# AGENT_ROLES enum: ceo/cto/cmo/cfo/security/engineer/designer/pm/qa/devops/
# researcher/general — NOT a free-form string. The grid's manifest carries the
# grid's own role key (e.g. "backend-dev", "ad-copy") in that same field, which
# is not a member of the enum and would be rejected by the server as-is. This
# is a real gap discovered while building this script (see deploy notes handed
# back with this session) — compose.py's paperclip_payload() should probably
# grow a similar mapping, or Paperclip's schema should grow more roles. Until
# that's decided, this script does the translation itself at payload-build
# time. The grid's own role key is preserved separately in `metadata.gridRole`
# (see build_hire_payload) so nothing is lost, and so re-runs can match
# reliably even though several grid roles collapse onto the same Paperclip
# enum value (e.g. every marketing specialist below maps to "general").
ROLE_TO_PAPERCLIP_ROLE: dict[str, str] = {
    "ceo-orchestrator": "ceo",
    "tech-lead": "cto",
    "growth-hacker": "cmo",
    "product-manager": "pm",
    "project-manager": "pm",
    "backend-dev": "engineer",
    "frontend-dev": "engineer",
    "data-engineer": "engineer",
    "designer": "designer",
    "qa-engineer": "qa",
    "security-reviewer": "security",
    "devops": "devops",
    "data-analyst": "researcher",
    "data-scientist": "researcher",
    "researcher": "researcher",
    "copywriter": "general",
    "ad-copy": "general",
    "seo": "general",
    "paid-search": "general",
    "paid-social": "general",
}


def map_paperclip_role(grid_role: str) -> str:
    mapped = ROLE_TO_PAPERCLIP_ROLE.get(grid_role)
    if mapped is None:
        print(f"  [warn] no Paperclip role mapping for grid role '{grid_role}' -> defaulting to 'general'")
        return "general"
    return mapped


# ── skill source resolution ───────────────────────────────────────────────────

def _parse_frontmatter_description(text: str) -> Optional[str]:
    """Best-effort single-line `description:` scalar out of a YAML frontmatter
    block. Good enough for bolt-on skills (which follow the Agent Skills spec
    frontmatter); role SKILL.md files have no frontmatter at all, so this
    simply returns None for those and the caller falls back to the role's
    `capabilities` blurb from the manifest instead."""
    if not text.startswith("---"):
        return None
    end = text.find("\n---", 3)
    if end == -1:
        return None
    block = text[3:end]
    for line in block.splitlines():
        line = line.strip()
        if line.startswith("description:"):
            value = line[len("description:"):].strip()
            return value.strip('"').strip("'") or None
    return None


def find_skill_source(skill_key: str) -> Optional[Path]:
    """Locate the SKILL.md backing a manifest desiredSkills entry.

    Search order (first match wins, deterministic):
      1. agent-factory/roles/<skill_key>/SKILL.md   — the role's own skill
      2. agent-factory/skills/<skill_key>/SKILL.md   — bolt-on skills owned by
         agent-factory itself (empty today, checked anyway per the task brief)
      3. <the-grid root>/<skill_key>/SKILL.md        — root-owned grid skills
      4. <the-grid>/repos/**/<skill_key>/SKILL.md    — wired submodule skills
         (sorted glob; first match wins if more than one repo has the name)

    Returns None if nothing is found anywhere — this happens for skill keys
    that are session-native Claude Code skills with no file backing in the
    grid repo at all (e.g. "deep-research", a built-in Claude Code skill
    referenced via a role's base_skills). Those can't be pushed as company
    skill markdown and are reported as skipped, not silently dropped.
    """
    candidates = [
        AGENT_FACTORY_DIR / "roles" / skill_key / "SKILL.md",
        AGENT_FACTORY_DIR / "skills" / skill_key / "SKILL.md",
        GRID_DIR / skill_key / "SKILL.md",
    ]
    for c in candidates:
        if c.is_file():
            return c
    matches = sorted(GRID_DIR.glob(f"repos/**/{skill_key}/SKILL.md"))
    return matches[0] if matches else None


# ── manifest loading ───────────────────────────────────────────────────────────

def load_manifest(path: Path) -> list[dict]:
    if not path.is_file():
        raise SystemExit(f"manifest not found: {path} (run compose.py --target paperclip first)")
    data = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(data, list) or not data:
        raise SystemExit(f"manifest at {path} is not a non-empty JSON array")
    for entry in data:
        for required in ("role", "name", "title", "instructionsBundle", "desiredSkills"):
            if required not in entry:
                raise SystemExit(f"manifest entry missing '{required}': {entry.get('role', '?')}")
    return data


def unique_skills(manifest: list[dict]) -> list[str]:
    seen: list[str] = []
    for agent in manifest:
        for skill in agent.get("desiredSkills") or []:
            if skill not in seen:
                seen.append(skill)
    return seen


# ── Paperclip client ───────────────────────────────────────────────────────────

class PaperclipClient:
    """Thin HTTP wrapper. GET is always real (read-only, safe to run anytime).
    Mutating verbs (POST/PATCH/PUT) are intercepted in dry-run mode: printed,
    never sent, and a synthesized response is returned so the caller's
    reportsTo-resolution logic has an id to chain against, exactly as if the
    call had gone through for real."""

    def __init__(self, base_url: str, api_key: str, dry_run: bool):
        self.base_url = base_url.rstrip("/")
        self.api_key = api_key
        self.dry_run = dry_run

    def _do(self, method: str, path: str, body: Optional[dict] = None) -> Any:
        url = f"{self.base_url}{path}"
        data = json.dumps(body).encode("utf-8") if body is not None else None
        req = urllib.request.Request(url, data=data, method=method)
        req.add_header("Authorization", f"Bearer {self.api_key}")
        if data is not None:
            req.add_header("Content-Type", "application/json")
        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                raw = resp.read()
                return json.loads(raw) if raw else None
        except urllib.error.HTTPError as e:
            detail = e.read().decode("utf-8", errors="replace")
            raise RuntimeError(f"{method} {path} -> HTTP {e.code}: {detail}") from e

    def get(self, path: str) -> Any:
        return self._do("GET", path)

    def mutate(self, method: str, path: str, body: Optional[dict], *, simulate_result: Any = None) -> Any:
        if self.dry_run:
            print(f"  [dry-run] {method} {path}")
            if body is not None:
                print(_pretty_summary(body))
            return simulate_result
        return self._do(method, path, body)


def _pretty_summary(body: dict) -> str:
    """Print a payload readably without dumping full instructionsBundle file
    contents (each can be several KB of rendered identity markdown)."""
    shown = {}
    for k, v in body.items():
        if k == "instructionsBundle" and isinstance(v, dict) and "files" in v:
            shown[k] = {
                "entryFile": v.get("entryFile"),
                "files": {fn: f"<{len(fc)} chars>" for fn, fc in v["files"].items()},
            }
        elif k == "markdown" and isinstance(v, str):
            shown[k] = f"<{len(v)} chars>"
        else:
            shown[k] = v
    return "    " + json.dumps(shown, indent=2).replace("\n", "\n    ")


# ── skills step ────────────────────────────────────────────────────────────────

def sync_skills(client: PaperclipClient, company_id: str, manifest: list[dict]) -> None:
    capabilities_by_role = {a["role"]: a.get("capabilities") for a in manifest}
    existing = client.get(f"/api/companies/{company_id}/skills") or []
    existing_slugs = {s["slug"] for s in existing if s.get("slug")}

    print(f"\n== skills ({len(unique_skills(manifest))} unique keys across manifest) ==")
    for skill_key in unique_skills(manifest):
        if skill_key in existing_slugs:
            print(f"  [skip] '{skill_key}' already in company skill library")
            continue
        source = find_skill_source(skill_key)
        if source is None:
            print(f"  [warn] no SKILL.md found for '{skill_key}' anywhere in the-grid "
                  f"(roles/, skills/, root, or repos/*) — likely a Claude-Code "
                  f"session-native skill; cannot import as company skill markdown, skipping")
            continue
        markdown = source.read_text(encoding="utf-8")
        description = _parse_frontmatter_description(markdown) or capabilities_by_role.get(skill_key)
        body = {"name": skill_key, "slug": skill_key, "description": description, "markdown": markdown}
        print(f"  [{'would create' if client.dry_run else 'creating'}] '{skill_key}' <- {source.relative_to(GRID_DIR)}")
        client.mutate(
            "POST", f"/api/companies/{company_id}/skills", body,
            simulate_result={"id": str(uuid.uuid4()), "slug": skill_key},
        )


# ── agents step ────────────────────────────────────────────────────────────────

# Session A3: resolve the cwd open question left by A2. Each claude_local
# agent needs a real filesystem path to run in. For this wiring-proof phase
# (not real dev work yet) a per-agent git worktree per role is overkill --
# that's 20 branches/checkouts to create and clean up for agents that aren't
# doing real work yet. Instead: one dedicated, non-git scratch directory per
# agent, well outside any real repo, so a session that actually executes in
# it can't touch production files or history. If/when a role graduates to
# doing real work, its cwd can be repointed at a real ~/worktrees/<role>
# checkout then -- this function is the only place that decision lives.
#
# Scoped by project as well as role: a manifest lives at
# projects/<project>/_paperclip/manifest.json (write_paperclip in compose.py),
# and the same role (e.g. "backend-dev") will exist in more than one composed
# roster over time. A flat SCRATCH_ROOT/<role> would collide across projects
# the moment a second roster is deployed, so cwd is keyed by
# SCRATCH_ROOT/<project>/<role> from the start.
SCRATCH_ROOT = Path.home() / "paperclip-agents"


def agent_scratch_dir(project: str, role: str) -> Path:
    return SCRATCH_ROOT / project / role


def desired_adapter_config(entry: dict, project: str) -> dict:
    """The adapterConfig this script wants an agent to have. Only claude_local
    agents need a cwd (openclaw_gateway agents like Jarvis run elsewhere and
    are never in this manifest anyway)."""
    if entry.get("adapterType") == "claude_local":
        return {"cwd": str(agent_scratch_dir(project, entry["role"]))}
    return {}


def ensure_scratch_dirs(manifest: list[dict], project: str) -> None:
    """Create each claude_local agent's scratch cwd if missing. Pure local
    filesystem side effect -- idempotent (mkdir -p semantics), never touches
    the live Paperclip company, so it runs even in dry-run mode. Not called
    from self_test(), which stays fully offline per its docstring."""
    for entry in manifest:
        if entry.get("adapterType") != "claude_local":
            continue
        d = agent_scratch_dir(project, entry["role"])
        existed = d.is_dir()
        d.mkdir(parents=True, exist_ok=True)
        if not existed:
            print(f"  [mkdir] {d}")


def build_hire_payload(entry: dict, reports_to_id: Optional[str], project: str) -> dict:
    return {
        "name": entry["name"],
        "role": map_paperclip_role(entry["role"]),
        "title": entry["title"],
        "icon": None,
        "reportsTo": reports_to_id,
        "capabilities": entry.get("capabilities"),
        "desiredSkills": entry.get("desiredSkills") or [],
        "adapterType": entry["adapterType"],
        "adapterConfig": desired_adapter_config(entry, project),
        "instructionsBundle": entry["instructionsBundle"],
        "runtimeConfig": {"heartbeat": {"enabled": False, "wakeOnDemand": True}},
        # Not sent to Paperclip's schema-validated top-level fields — carried
        # in the free-form `metadata` bag so re-runs can match this agent back
        # to its grid role even though several grid roles collapse onto the
        # same coarse Paperclip `role` enum value (see ROLE_TO_PAPERCLIP_ROLE).
        "metadata": {"gridRole": entry["role"]},
    }


def find_existing(existing_agents: list[dict], entry: dict) -> Optional[dict]:
    """Match an already-created Paperclip agent back to a manifest entry.
    Primary key: metadata.gridRole (set by this script on every hire it makes,
    see build_hire_payload) — robust even if Gareth later renames the agent by
    hand. Falls back to an exact `name` match for agents that predate this
    script (e.g. a hand-created agent that happens to share a name)."""
    for a in existing_agents:
        meta = a.get("metadata")
        if isinstance(meta, dict) and meta.get("gridRole") == entry["role"]:
            return a
    for a in existing_agents:
        if a.get("name") == entry["name"]:
            return a
    return None


def diff_and_patch_agent(client: PaperclipClient, existing: dict, entry: dict, reports_to_id: Optional[str], project: str) -> None:
    """Bring an already-hired agent in line with the manifest. Only issues a
    call for a field that actually changed, so an unmodified manifest run
    against unmodified live state issues zero calls — the idempotency
    property this script is required to have."""
    agent_id = existing["id"]
    changed_top_level = {}
    if existing.get("title") != entry.get("title"):
        changed_top_level["title"] = entry.get("title")
    if existing.get("capabilities") != entry.get("capabilities"):
        changed_top_level["capabilities"] = entry.get("capabilities")
    if existing.get("reportsTo") != reports_to_id:
        changed_top_level["reportsTo"] = reports_to_id
    wanted_adapter_config = desired_adapter_config(entry, project)
    if (existing.get("adapterConfig") or {}) != wanted_adapter_config:
        changed_top_level["adapterConfig"] = wanted_adapter_config

    if changed_top_level:
        print(f"  [{'would patch' if client.dry_run else 'patching'}] {entry['name']} ({agent_id}): {list(changed_top_level)}")
        client.mutate("PATCH", f"/api/agents/{agent_id}", changed_top_level, simulate_result=existing)
    else:
        print(f"  [ok] {entry['name']} ({agent_id}): title/capabilities/reportsTo unchanged")

    existing_skills = sorted(existing.get("desiredSkills") or [])
    wanted_skills = sorted(entry.get("desiredSkills") or [])
    if existing_skills != wanted_skills:
        print(f"  [{'would sync' if client.dry_run else 'syncing'}] {entry['name']} skills -> {wanted_skills}")
        client.mutate(
            "POST", f"/api/agents/{agent_id}/skills/sync", {"desiredSkills": wanted_skills},
            simulate_result={"entries": []},
        )
    else:
        print(f"  [ok] {entry['name']}: desiredSkills unchanged")

    for filename, content in entry["instructionsBundle"]["files"].items():
        current = None
        try:
            current_resp = client.get(f"/api/agents/{agent_id}/instructions-bundle/file?path={filename}")
            current = current_resp.get("content") if isinstance(current_resp, dict) else None
        except RuntimeError:
            current = None  # file doesn't exist yet on this agent — treat as changed
        if current != content:
            print(f"  [{'would write' if client.dry_run else 'writing'}] {entry['name']} instructions-bundle/{filename}")
            client.mutate(
                "PUT", f"/api/agents/{agent_id}/instructions-bundle/file",
                {"path": filename, "content": content},
                simulate_result={"path": filename},
            )
        else:
            print(f"  [ok] {entry['name']}: instructions-bundle/{filename} unchanged")


def deploy_agents(client: PaperclipClient, company_id: str, manifest: list[dict], project: str) -> None:
    existing_agents = client.get(f"/api/companies/{company_id}/agents") or []
    role_id_map: dict[str, str] = {}

    print(f"\n== agents ({len(manifest)} in manifest, topological order) ==")
    for entry in manifest:
        role = entry["role"]
        parent_role = entry.get("reportsTo")
        if parent_role is not None and parent_role not in role_id_map:
            # Manifest is supposed to be topologically ordered (compose.py's
            # topological_roster) — a parent must already have been placed in
            # role_id_map by the time its child is processed. If this fires,
            # the manifest itself is out of order; fail loudly rather than
            # silently hire with reportsTo: null.
            raise RuntimeError(
                f"manifest ordering violated: '{role}' reportsTo '{parent_role}' "
                f"before '{parent_role}' was processed"
            )
        reports_to_id = role_id_map.get(parent_role) if parent_role else None

        existing = find_existing(existing_agents, entry)
        if existing:
            diff_and_patch_agent(client, existing, entry, reports_to_id, project)
            role_id_map[role] = existing["id"]
        else:
            payload = build_hire_payload(entry, reports_to_id, project)
            print(f"  [{'would hire' if client.dry_run else 'hiring'}] {entry['name']} "
                  f"(role={payload['role']}, reportsTo={reports_to_id})")
            result = client.mutate(
                "POST", f"/api/companies/{company_id}/agent-hires", payload,
                simulate_result={"agent": {"id": f"SIMULATED-{uuid.uuid4()}", "status": "pending_approval"}},
            )
            new_id = result["agent"]["id"] if isinstance(result, dict) and "agent" in result else str(uuid.uuid4())
            role_id_map[role] = new_id


# ── self-test (offline, no network, no env vars) ──────────────────────────────

def self_test() -> None:
    """Prove the hire/patch branching + reportsTo-resolution + idempotency
    logic deterministically, without touching any live Paperclip instance.
    Uses a tiny synthetic 3-agent chain (A -> B -> C) so the reasoning is easy
    to follow by eye in the printed output."""
    print("=== self-test: offline fixture, no network calls ===")

    def make_entry(role, name, reports_to, capabilities):
        return {
            "role": role, "name": name, "title": name, "reportsTo": reports_to,
            "capabilities": capabilities, "adapterType": "claude_local",
            "desiredSkills": [role],
            "instructionsBundle": {"entryFile": "AGENTS.md", "files": {"AGENTS.md": f"You are {name}."}},
        }

    manifest = [
        make_entry("role-a", "A", None, "apex"),
        make_entry("role-b", "B", "role-a", "middle"),
        make_entry("role-c", "C", "role-b", "leaf"),
    ]

    class FakeClient:
        """Same mutate()/get() surface as PaperclipClient, backed by an
        in-memory dict instead of HTTP. dry_run stays True throughout (this
        is a simulation, not a real system) but every call is actually
        applied to the fixture so a second self_test() pass can prove the
        no-op property against real (in-memory) state, not just printed
        intent."""
        dry_run = False  # applies calls to the fixture "for real" (in-memory only)

        def __init__(self):
            self.agents: dict[str, dict] = {}
            self.skills: dict[str, dict] = {}
            self.call_count = 0

        def get(self, path: str):
            if path.endswith("/skills"):
                return list(self.skills.values())
            if path.endswith("/agents"):
                return list(self.agents.values())
            if "/instructions-bundle/file" in path:
                agent_id, filename = path.split("/instructions-bundle/file?path=")[0].split("/agents/")[1].split("/")[0], path.split("path=")[1]
                agent = self.agents.get(agent_id)
                if not agent:
                    raise RuntimeError("404")
                content = agent.get("_files", {}).get(filename)
                if content is None:
                    raise RuntimeError("404 file not found")
                return {"path": filename, "content": content}
            raise RuntimeError(f"unhandled fixture GET {path}")

        def mutate(self, method, path, body, *, simulate_result=None):
            self.call_count += 1
            if method == "POST" and path.endswith("/agent-hires"):
                new_id = f"fake-{body['metadata']['gridRole']}"
                self.agents[new_id] = {
                    "id": new_id, "name": body["name"], "title": body["title"],
                    "capabilities": body["capabilities"], "reportsTo": body["reportsTo"],
                    "desiredSkills": body["desiredSkills"], "metadata": body["metadata"],
                    "adapterConfig": body.get("adapterConfig") or {},
                    "_files": dict(body["instructionsBundle"]["files"]),
                }
                return {"agent": {"id": new_id}}
            if method == "PATCH" and "/agents/" in path and "skills/sync" not in path:
                agent_id = path.rsplit("/", 1)[-1]
                self.agents[agent_id].update(body)
                return self.agents[agent_id]
            if method == "POST" and path.endswith("/skills/sync"):
                agent_id = path.split("/agents/")[1].split("/")[0]
                self.agents[agent_id]["desiredSkills"] = body["desiredSkills"]
                return {"entries": []}
            if method == "PUT" and path.endswith("/instructions-bundle/file"):
                agent_id = path.split("/agents/")[1].split("/")[0]
                self.agents[agent_id]["_files"][body["path"]] = body["content"]
                return {"path": body["path"]}
            if method == "POST" and path.endswith("/skills"):
                self.skills[body["slug"]] = {"slug": body["slug"]}
                return {"id": str(uuid.uuid4())}
            raise RuntimeError(f"unhandled fixture mutate {method} {path}")

    client = FakeClient()

    print("\n--- pass 1: empty company -> expect 3 hires, reportsTo chained correctly ---")
    deploy_agents(client, "fixture-company", manifest, "fixture-project")
    assert client.agents["fake-role-a"]["reportsTo"] is None
    assert client.agents["fake-role-b"]["reportsTo"] == "fake-role-a", "B must report to A's real id"
    assert client.agents["fake-role-c"]["reportsTo"] == "fake-role-b", "C must report to B's real id"
    print(f"[self-test] pass 1 OK — {client.call_count} mutating calls, reportsTo chain verified")

    print("\n--- pass 2: identical manifest against now-existing agents -> expect 0 mutating calls ---")
    calls_before = client.call_count
    deploy_agents(client, "fixture-company", manifest, "fixture-project")
    delta = client.call_count - calls_before
    assert delta == 0, f"expected 0 mutating calls on an unchanged re-run, got {delta}"
    print(f"[self-test] pass 2 OK — {delta} mutating calls (idempotent no-op confirmed)")

    print("\n--- pass 3: one field drifts (B's capabilities) -> expect exactly 1 PATCH, nothing else ---")
    manifest[1]["capabilities"] = "middle (updated)"
    calls_before = client.call_count
    deploy_agents(client, "fixture-company", manifest, "fixture-project")
    delta = client.call_count - calls_before
    assert delta == 1, f"expected exactly 1 mutating call for the single drifted field, got {delta}"
    assert client.agents["fake-role-b"]["capabilities"] == "middle (updated)"
    print(f"[self-test] pass 3 OK — {delta} mutating call, only B patched")

    print("\n=== self-test: ALL ASSERTIONS PASSED ===")


# ── cli ────────────────────────────────────────────────────────────────────────

def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--manifest", type=Path, default=DEFAULT_MANIFEST)
    parser.add_argument("--i-mean-it", action="store_true",
                         help="actually send POST/PATCH/PUT to the live instance (default: dry-run)")
    parser.add_argument("--skills-only", action="store_true")
    parser.add_argument("--agents-only", action="store_true")
    parser.add_argument("--self-test", action="store_true",
                         help="offline simulation, no network, no env vars required")
    args = parser.parse_args()

    if args.self_test:
        self_test()
        return

    manifest = load_manifest(args.manifest)
    # Manifests always live at projects/<project>/_paperclip/manifest.json
    # (write_paperclip in compose.py) -- derive the project slug from that
    # convention so scratch-dir cwds are scoped per project, not just per role.
    project = args.manifest.resolve().parent.parent.name
    print(f"loaded manifest: {len(manifest)} agents from {args.manifest} (project={project})")

    api_url = os.environ.get("PAPERCLIP_API_URL")
    api_key = os.environ.get("PAPERCLIP_API_KEY")
    company_id = os.environ.get("PAPERCLIP_COMPANY_ID")
    missing = [n for n, v in (("PAPERCLIP_API_URL", api_url), ("PAPERCLIP_API_KEY", api_key),
                              ("PAPERCLIP_COMPANY_ID", company_id)) if not v]
    if missing:
        raise SystemExit(f"missing required env var(s): {', '.join(missing)}")

    dry_run = not args.i_mean_it
    if dry_run:
        print("MODE: dry-run (default-safe). No POST/PATCH/PUT will be sent. Pass --i-mean-it for a real run.")
    else:
        print("MODE: REAL RUN — this will create/modify agents and skills in a live Paperclip company.")

    client = PaperclipClient(api_url, api_key, dry_run=dry_run)

    if not args.skills_only:
        ensure_scratch_dirs(manifest, project)
    if not args.agents_only:
        sync_skills(client, company_id, manifest)
    if not args.skills_only:
        deploy_agents(client, company_id, manifest, project)


if __name__ == "__main__":
    main()
