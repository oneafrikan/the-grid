## Context

- Marketplace = a git repo with `.claude-plugin/marketplace.json` (required: `name`, `owner{name}`, `plugins[]`; each entry requires `name` + `source`). Users run `claude plugin marketplace add <owner/repo>` then `claude plugin install <plugin>@<marketplace>`.
- Plugin layout: `.claude-plugin/plugin.json`, `skills/<name>/SKILL.md`, `agents/*.md`. Agents and skills are found by convention. Plugin components are namespaced (`/grid-core:standup`). `skillOverrides` does not apply to plugin skills.
- A relative-path plugin source is copied out of the marketplace clone into a cache, so a plugin dir must be self-contained (no symlinks or `../` into the rest of the repo).
- Verified locally with `claude plugin validate` (CLI 2.1.295) on a prototype of this exact layout: marketplace, both plugin manifests, and both `skills/` and `agents/` component dirs all pass `--strict`. Two probes matter:
  - `--strict` fails on a marketplace with no `metadata.description`.
  - Validate does NOT fail when an entry's `source` path does not exist. The build script must check that itself.
- ECC's `PLUGIN_SCHEMA_NOTES.md` rules that apply: `version` required in `plugin.json`; no `agents` field (auto-discovered, field is rejected); no `hooks` field for the standard `hooks/hooks.json` (we ship none); agent `tools:` frontmatter is a comma scalar (composed agents already conform and validate); if a plugin root had `.mcp.json` it is auto-loaded (we ship none, so no `mcpServers: {}` opt-out is needed).
- Composed agents are git-ignored regenerable output and, on a configured machine, carry that machine's operator email, channels and hostname in the IDENTITY nameplate (seen in `agent-factory/projects/grid/_claude-code/agents/grid-devops.md`). Copying that output into a public tree would leak it. Hence the neutral-identity switch.
- Source layout today: owned skills in `skills/` (14 dirs); composed output per project at `agent-factory/projects/<p>/_claude-code/{agents,skills}`; root-owned agent `agents/grid-ponytail.md`.

## Approach

`plugins/bundles.json` (input, hand-authored) -> `scripts/build-plugins.py` -> outputs (committed, generated):

```
.claude-plugin/marketplace.json
plugins/grid-core/.claude-plugin/plugin.json
plugins/grid-core/skills/<owned skill dirs + tron>/
plugins/grid-core/agents/core-*.md
plugins/grid-agents/.claude-plugin/plugin.json
plugins/grid-agents/skills/grid-{ceo-orchestrator,tech-lead,growth-hacker}/
plugins/grid-agents/agents/grid-*.md        (21 specialists + grid-ponytail)
```

Manifest format (`plugins/bundles.json`):

```json
{
  "marketplace": {
    "name": "the-grid",
    "owner": "the-grid",
    "description": "Skills and composed dev-team agents from the-grid."
  },
  "version": "0.1.0",
  "license": "MIT",
  "repository": "https://github.com/oneafrikan/the-grid",
  "bundles": {
    "grid-core": {
      "description": "the-grid's own skills plus the cross-desk core agents (researcher, librarian, gh-triage, platform-engineer) and /tron.",
      "skills": ["gh-issues-by-severity", "grid-help", "mine-learnings", "openspec-help",
                 "rubber-duck", "spec-scout", "standup", "tighten", "un-claudish"],
      "compose": ["core"],
      "agents": []
    },
    "grid-agents": {
      "description": "The composed dev team: CEO, tech-lead and growth-hacker orchestrators plus 21 specialist subagents.",
      "skills": [],
      "compose": ["grid"],
      "agents": ["grid-ponytail"]
    }
  }
}
```

Generated `marketplace.json` (key order fixed, 2-space indent, trailing newline):

```json
{
  "name": "the-grid",
  "owner": { "name": "the-grid" },
  "metadata": { "description": "Skills and composed dev-team agents from the-grid." },
  "plugins": [
    { "name": "grid-core", "source": "./plugins/grid-core", "description": "...", "version": "0.1.0" },
    { "name": "grid-agents", "source": "./plugins/grid-agents", "description": "...", "version": "0.1.0" }
  ]
}
```

Generated `plugin.json`: `name`, `version`, `description`, `author{name}`, `license`, `repository`. Nothing else (no `skills`, `agents`, `hooks`, `mcpServers`).

Build steps (write mode; `--check` does the same into a temp dir and diffs):
1. Read the manifest; fail on unknown keys.
2. For each `compose` project run `GRID_PRIVATE_ROLES_DIR= GRID_NEUTRAL_IDENTITY=1 agent-factory/.venv/bin/python agent-factory/compose.py agent-factory/examples/<p>.yaml --target claude-code --out <tmp>`; take `<tmp>/<p>/_claude-code/{agents,skills}`.
3. Copy each listed owned skill dir from `skills/` and each listed root agent from `agents/`.
4. Guards (hard fail with a message naming the offender): listed skill lacks `SKILL.md`; a bundle ends with zero components; two components share a name inside one plugin; a listed skill name also exists as a skill dir under `repos/*/` (provenance unknown; skipped with a notice when `repos/` is empty).
5. Replace `plugins/<bundle>/` wholesale (delete stale files), write manifests. Skip `.DS_Store`. Re-running is a no-op.

Gate wiring (in `gate.sh`, same skip-loudly style as the compose check):
- `build-plugins.py --check` runs when `agent-factory/.venv/bin/python` exists, else skipped with a notice.
- `claude plugin validate --strict` runs on `.`, each `plugins/<bundle>`, and each bundle's `skills/` and `agents/` dir, when `claude` is on PATH, else skipped with a notice (CI has no `claude`).
- `grid audit plugins/` (change `vetting`) runs when that command exists.

Two channels, one machine: a machine that wired the-grid already has `grid-qa-engineer` etc. in `~/.claude/agents/`; installing `grid-agents` as well lists each twice (second under the `grid-agents:` namespace). `docs/PLUGINS.md` says to pick one channel per machine.

## Decisions

- Decided: two bundles named `grid-core` and `grid-agents`, as in the plan; fewer plugins means fewer listing entries and less to explain.
- Decided: bundles contain the-grid's OWN content only. Third-party wired skills are not exposed in v0.1. Reasons: each upstream needs a licence/attribution review and a standing vetting duty (change `vetting` would have to pass for every listed entry); a `git-subdir` source makes the plugin root the skill dir, which does not match the `skills/<name>/SKILL.md` layout without an untested `strict:false` workaround; `grid install` (change `manifest-lock-install`) already serves third-party skills with sha-pinned locks. A future `grid-extras` bundle generated from `grid.lock` is a separate change.
- Decided: because content is owned and shipped by relative path, entries carry no `sha`/`ref`; pinning is the marketplace repo's own git ref (users may add the marketplace at a tag).
- Decided: initial `grid-core` skill list is the 9 owned skills in the manifest above, plus `tron` and the 4 core agents via `compose`. Excluded for v0.1: `handoff`, `grill-me`, `caveman` (root forks of upstream skills that exist in `repos/`), `skill-scout` (same name exists in `repos/ecc`), `setup-repo-skills` (derived from mattpocock's `setup-matt-pocock-skills`). Reason: a fork redistributed from a plugin needs licence confirmation first; the HUMAN publish group decides.
- Decided: `grid-ponytail` (hand-authored root agent) goes in `grid-agents`, not `grid-core`, because it is a coder persona alongside the dev team.
- Decided: only the `core` and `grid` composed projects are bundled. `finance-desk`, `learning-desk` and private desks are personal verticals; sharing them is a separate decision.
- Decided: generated plugin dirs are committed copies on the default branch. Marketplace add reads the default branch of the git repo, and a relative `source` must exist there. Drift is prevented by `--check` in the gate, as with `SKILLS.md`.
- Decided: copies, never symlinks, because the plugin cache copy does not follow links out of the plugin dir.
- Decided: builds always run compose with `GRID_PRIVATE_ROLES_DIR=` (empty) and `GRID_NEUTRAL_IDENTITY=1`. Output then depends only on tracked files, so `--check` gives the same answer on every machine.
- Decided: `GRID_NEUTRAL_IDENTITY=1` makes `load_user_config()` return the literal `(not set)` for operator, channels and machine, skipping both `user.yaml` and the hostname fallback. Reason: empty values leave blank table cells in `IDENTITY.md`; a visible placeholder reads as intentional.
- Decided: `compose.py` also gains `GRID_USER_CONFIG` (path override for `user.yaml`, default unchanged) so tests can inject a configured identity without touching the real file.
- Decided: `plugin.json` has no `skills`/`agents`/`hooks`/`mcpServers` fields; convention discovery plus ECC's documented validator rules (agents field rejected, hooks auto-loaded) make omission the safe choice, and the local `--strict` prototype passed.
- Decided: marketplace `name` and `owner.name` are both `the-grid`; no personal name or email appears in any generated file (`repository` is the public repo URL).
- Decided: manifest is JSON, not YAML, so the build and `--check` need only stdlib `json`; the compose step is the only part that needs the agent-factory venv.
- Decided: version lives only in `plugins/bundles.json` and is hand-bumped at release; both bundles and both marketplace entries always share it. Initial value `0.1.0`.
- Decided: no `description` truncation logic; descriptions come from the manifest and are kept under 200 chars by a test.
- Decided: tests use a mock grid dir (`GRID_DIR` override, `compose: []`) so they need no venv and never touch `~/.claude`; one extra test exercises real compose and skips when the venv is absent.
- Decided: nothing in `plugins/` is scanned by `wire.sh` or `catalog.sh` (both read `skills/` and `repos/` only), so plugin copies never inflate skill counts or the listing budget; a test asserts `catalog.sh --check` is unaffected.
- Decided: publishing (merge to `main`, `marketplace add` from a clean profile, announcement) is a HUMAN group gated on tag `v0.1.0` from change `front-door`. Groups 1-4 land on `next` and are inert until `next` reaches `main`.
