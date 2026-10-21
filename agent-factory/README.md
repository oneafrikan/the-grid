# agent-factory

Composes AI dev teams from three orthogonal inputs:

```
role  ×  stack  ×  skills   ──compose.py──▶   a ready-to-run agent team
```

- **role** — *who* the agent is (Tech Lead, Backend Dev, QA…). Stack-agnostic
  identity + an operating skill. Lives in `roles/<role>/`.
- **stack** — *what* it builds on (LAMP, modern-frontend, data-engineering…).
  An overlay. Lives in `stacks/<stack>/`.
- **skills** — bolt-on capabilities pulled from the ecosystem (Paperclip, php,
  mysql…). Lives in `skills/<skill>/`.

A **compose config** (see `examples/grid.yaml`) names a project and lists
agents, each as `role + stacks[] + skills[] + model`. `compose.py` reads it and
emits one folder per agent under `projects/<name>/`, rendered to the **live
OpenClaw 5-file identity model** — `SOUL.md` (how it behaves), `IDENTITY.md` (who
it is + model), `AGENTS.md` (boot sequence + async handoff), `USER.md` (who it
serves), `MEMORY.md` (what it carries) — plus a top-level `agents.yaml` that wires
the team together and lists each agent's skills by name. A role's operating skill
(its `SKILL.md`) is referenced by name, not copied — OpenClaw wires skills from a
shared skills dir.

> Skills are a **separate** concern (authored as `skills/<name>/SKILL.md` or with the
> wired `skill-creator` skill). This factory only *composes* teams from existing parts.

## Layout

```
agent-factory/
├── _core/                  shared base templates every role inherits
│   ├── SOUL_base.md        universal personality scaffolding
│   ├── IDENTITY_base.md    nameplate token template (name/role/model/cron_model)
│   ├── AGENTS_base.md      universal boot sequence + async handoff protocol
│                           (incl. the spec-driven check — see "Spec-driven repos")
│   ├── USER_base.md        operator/team skeleton
│   ├── MEMORY_base.md      universal memory structure
│   └── agents_base.yaml    universal runtime config template
├── roles/<role>/           role source (stack-agnostic)
│   ├── role.yaml           metadata: title, default/cron model, summary, owns, orchestrator
│   ├── SOUL.md             personality / voice (required)
│   ├── IDENTITY.md         nameplate extras (optional; merged over _core)
│   ├── AGENTS.md           routing + a {{ROSTER_TABLE}} slot (optional; merged over _core)
│   ├── USER.md             operator-reading notes (optional; merged over _core)
│   ├── MEMORY.md           memory seed (optional; merged over _core)
│   └── SKILL.md            the role's operating skill — required, referenced by name
├── stacks/<stack>/         stack overlay (appended to AGENTS.md)
│   └── stack.yaml          + fragment files
├── skills/<skill>/         local skill library (built elsewhere, dropped here)
├── compose.py              the factory engine
├── factory.schema.yaml     what a valid compose config looks like
├── examples/               sample compose configs
└── projects/<name>/        OUTPUT — one folder per composed agent (gitignored)
```

## Running it

`compose.py` needs PyYAML. Install it once into a project venv:

```bash
python3 -m venv .venv
.venv/bin/pip install -r requirements.txt
```

Then compose a team from a config. `compose.py` is a **multi-target compiler** —
one 5-file source, a different artifact shape per `--target`:

```bash
# OpenClaw target (default, legacy): 5 identity files + agents.yaml per agent.
# It replaces only its own output in projects/<name>/ (the role dirs and agents.yaml);
# the _<target> dirs below, which wire.sh links into ~/.claude, are left alone.
.venv/bin/python compose.py examples/grid.yaml
.venv/bin/python compose.py examples/grid.yaml --dry-run     # report only

# Claude Code target: orchestrators -> CC skills, specialists -> CC subagents
.venv/bin/python compose.py examples/grid.yaml --target claude-code
.venv/bin/python compose.py examples/grid.yaml --target claude-code --dry-run

# Portable target: one plain-Markdown persona per role (orchestrators too), no frontmatter.
# The committed copies live in dist/personas/; regenerate them with scripts/build-personas.sh
.venv/bin/python compose.py examples/grid.yaml --target portable

# Harness agent targets: one native subagent file per specialist (orchestrators ship as skills).
# wire.sh links this output into a harness's agents dir for `harness:<name>` entries
# (docs/harnesses.md); each target writes only its own _<target>/ dir.
.venv/bin/python compose.py examples/grid.yaml --target codex        # _codex/agents/*.toml
.venv/bin/python compose.py examples/grid.yaml --target opencode     # _opencode/agents/*.md
.venv/bin/python compose.py examples/grid.yaml --target gemini-cli   # _gemini-cli/agents/*.md
```

Output is regenerable and idempotent: re-running with an unchanged config
produces byte-identical files (each target's output dir is rebuilt in a `.tmp` dir and swapped
into place, so a failed run leaves the previous output intact). Each `.tmp`/`.old` dir is paired
with a `<name>.compose-owned` marker file; compose.py only clears leftovers it marked, and refuses
(never deletes) a `.tmp`/`.old` dir without one.

- **Interrupted swaps.** Ctrl-C or a failed rename rolls the previous output back. If the rollback
  itself fails, the previous output is left in `<name>.old` and the error names it; the next run
  refuses that unmarked dir, so move it back (or delete it) by hand. A run killed outright
  (`SIGKILL`, power loss) leaves marked `.tmp`/`.old` debris that the next run clears.
- **Markers are a convention, not a defence.** Anyone who can write to the output dir can plant a
  `<name>.compose-owned` file (or link) and so authorise compose.py to delete the dir at that name;
  a marker left by a killed run has the same effect if you later create your own dir at that name.
  Leave `*.tmp`, `*.old` and `*.compose-owned` names to compose.py.
- **Unmarked debris.** A `.tmp`/`.old` dir with no marker (older output, or yours) is refused with
  "refusing to delete ..."; move or remove it and re-run.
- **One writer per project.** A swap holds a lock on `<out>/<project>/`; a second run on the same
  project exits with "another compose run is writing ...". Re-run once the first has finished.
- **Reused project dirs.** A project name may only reuse an existing `<out>/<project>/` that looks like
  compose output: empty, or holding only dotfiles, `_<target>` dirs, the legacy target's
  `agents.yaml` and role dirs of identity files. Any other dir of that name (say `skills/`) is
  refused, never emptied.
- **Linked stacks and skills.** A `stacks:`/`skills:` entry that is, or sits under, a symlink is refused.

`projects/` output is gitignored — the compose config is the tracked artefact.

> **On a machine that just pulled new source, recompose before wiring.** A `git
> pull` updates the tracked source (`compose.py`, `roles/*`, `examples/*`) but not
> the git-ignored `projects/*`, so the live agents won't reflect the change until
> you re-run `compose.py` and then `bash scripts/wire.sh`.

> ⚠ **`compose.py` overwrites `projects/<name>/` wholesale.** Recomposing the
> public projects while a *private* project's roles are unreachable (its repo not
> cloned, `GRID_PRIVATE_ROLES_DIR` unset) silently destroys that project's
> composed output — and the next `wire.sh` tears down its symlinks, because
> wiring rebuilds from whatever `projects/` currently holds. This has already
> happened once. Before recomposing, check every `project:` gate in
> `machines/<host>.local.txt` has a config you can actually reach.

### Private projects

> Default location: if `GRID_PRIVATE_ROLES_DIR` is unset, `compose.py` uses
> `~/.the-grid-private/roles` when that directory exists, so a machine with the private
> repo cloned needs no extra setup. Set the variable to an empty string to disable it.

A project's roles and compose config don't have to live in this repo.
`GRID_PRIVATE_ROLES_DIR` points `compose.py` at an external roles directory
(see `role_dir()` — it's checked before the committed `roles/`), so a project
can be composed from sources the-grid never sees:

```bash
GRID_PRIVATE_ROLES_DIR=~/path/to/private/roles \
  .venv/bin/python compose.py ~/path/to/private/projects/<name>.yaml --target claude-code
```

Gate it with `project:<name>` in `machines/<host>.local.txt` — gitignored, so
even the gate stays out of this repo's history. Composed output lands in the
same `projects/` directory as everything else and wires identically.

The mechanism is public; only the content is private. Nothing about a private
desk — its name, its roles, its purpose — belongs in this repo.

The `claude-code` target writes to `projects/<name>/_claude-code/`:

```
projects/<name>/_claude-code/
├── skills/<role>/SKILL.md   one per orchestrator role (orchestrator: true)
└── agents/<role>.md         one per specialist role
```

## Wiring composed agents into Claude Code

`scripts/wire.sh` (in the-grid root) symlinks the `_claude-code/` output into
your live Claude Code config — orchestrator skills into `~/.claude/skills/`,
specialist subagents into `~/.claude/agents/` — the same idempotent, grid-owned
symlink model it uses for ecosystem skills. After composing with
`--target claude-code`, run `bash scripts/wire.sh` from the-grid root.

> Skills and subagents load at the **start** of a Claude Code session — wire,
> then open a fresh session to pick them up.

## Invoking composed agents

The orchestrator/specialist split (`role.yaml` `orchestrator:`) decides *how* you
invoke a composed agent in Claude Code:

| Form | Roles (current) | How to invoke |
|------|-----------------|---------------|
| **Skill** (orchestrator) | `ceo-orchestrator`, `tech-lead`, `growth-hacker` | Slash command: `/ceo-orchestrator`, `/tech-lead`, `/growth-hacker`. Transforms the session into that role. |
| **Subagent** (specialist) | the other 21 | **Not** a slash command. Delegate to it: *"Use the backend-dev subagent to …"*, or let an orchestrator hand off to it. Claude can also auto-delegate based on the subagent's `description`. |

Typical flow: invoke `/tech-lead`, give it a feature → it writes a PRD and hands
off (async) to the specialist subagents. You rarely call a specialist directly.

### How merging works

`SOUL.md`, `AGENTS.md`, `USER.md`, and `MEMORY.md` are merged section-by-section
with their `_core` base: shared level-2 (`## `) headings unify under one heading
(base guidance first, then the role's seed); sections unique to either side are
kept in order. This is why role templates reuse the base headings.

`IDENTITY.md` is different — it's a token template. `compose.py` substitutes
`{{name}}`, `{{role}}`, `{{model}}`, `{{cron_model}}` (from `role.yaml` + the
config) and appends the role's `IDENTITY.md` extras.

Stack overlays (when a stack is named) append to `AGENTS.md` as a trailing
"Stack overlays" section — stack conventions are operating rules.

## role.yaml keys, tool allowlists and the model map

`role.yaml` keys (lint rejects any other, `E_FIELD_UNKNOWN`): `name`, `title`, `summary`,
`owns`, `default_model`, `cron_model`, `base_skills`, `orchestrator`, plus:

- **`tools: [Read, Grep, ...]`** — optional allowlist written to the subagent's `tools:` frontmatter
  line. Absent means the subagent inherits every tool. Use it for roles whose prose says "advisory"
  or "does not implement" (security-reviewer, qa-engineer). It narrows a role; it does not sandbox it:
  `Bash` can still write files. Not allowed on orchestrators (they deploy as skills and would ignore it:
  `E_TOOLS_ON_ORCHESTRATOR`). What it does and does not protect: see
  [Tool allowlists and residual risk](#tool-allowlists-and-residual-risk).
- **`model_rationale: text`** — required when `default_model` is not `sonnet`: say why this role is on a
  different tier (`E_MODEL_RATIONALE_MISSING`). Keeps the "which tier and why" in one parsed place.
- **`unattended: true`** — the role runs with no human watching (cron). Today it is a marker (gh-triage,
  finance-manager); the unattended authoring variant (safe-target first, a run record per run via
  `scripts/run-record.sh`) will key off it.

**`models.yaml`** is the one place a model tier (`opus`, `sonnet`, `haiku`, `fable`) becomes the string
in a generated Claude Code agent's `model:` line. By default each tier maps to itself, so Claude Code
resolves it to the tier's current release. Pin a tier by writing an exact id there and recomposing; every
role on that tier changes at once. An optional `openclaw:` section does the same for the OpenClaw/Paperclip
`agents.yaml` `model:` line (those runtimes may want a provider-prefixed id); the OpenClaw orchestrator output
still carries the tier word, and `openclaw/roster.json` keeps its own hand-edited copy of the orchestrators' models (a test checks it
agrees with `role.yaml`).

**Rollout:** composed output is git-ignored, so after pulling a change to these keys run
`compose.py <cfg> --target claude-code` for each public project and `scripts/wire.sh`; per-project deploys
pick it up on the next `deploy.py <project>` (its `--check` reports the drift).

## Tool allowlists and residual risk

`tools:` in `role.yaml` is the per-role tool control in the generated subagent files. It is a
narrowing aid, not a sandbox.

**What it does**
- Limits a Claude Code subagent to the named built-in tools (`Read`, `Grep`, `Glob`, `Bash`, `Edit`,
  `Write`, `WebFetch`, `WebSearch`, `Skill`). A tool not listed is not available to that subagent.
- Is written into the generated agent files for Claude Code (`tools:`) and Gemini (each name mapped
  to its own tool). Runtime enforcement by those vendors is not verified here.
- This factory's `KNOWN_TOOLS` validation does not accept MCP tool names. Whether the vendor runtime
  treats `tools:` as a strict allowlist for MCP tools is not verified here; assume unlisted MCP tools
  may remain reachable until it is.

**What it does not do**
- It does not limit what a granted tool can reach: `Bash` can run anything the user can, `Write` is
  unscoped, `Read` reads any local file the user can. `tools:` cannot scope `Bash`, so a role with
  `Bash` has an unscoped shell.
- It does not stop a role from acting on injected instructions in the content it reads.
- It is not applied on every runtime:
  - OpenCode: compose emits only `edit`, `bash` and `webfetch` denials, and omits the block when
    nothing is denied. The four PR roles (researcher, seo, paid-search, paid-social) get no
    `permission` block; finance-analyst gets only `bash: deny`; gh-triage and librarian get only
    `webfetch: deny`.
  - Codex: these roles get no sandbox setting. Compose gives a best-effort read-only sandbox only to
    roles with neither `Edit` nor `Write`; none of these seven qualify.

**Current allowlists** (seven roles narrowed in H-04, adjusted in H-04b)

| Role | `tools:` | Why |
|---|---|---|
| researcher | Read, Grep, Glob, WebFetch, WebSearch, Write, Bash | Reads the web; Write for the report; Bash is there to open PRs (intent only, the shell is unscoped) |
| seo | Read, Grep, Glob, WebFetch, WebSearch, Write, Bash | Audits from web data; Bash is there to open PRs (intent only, the shell is unscoped) |
| paid-search | Read, Grep, Glob, WebFetch, WebSearch, Write, Bash | Same as seo; reopen if an ads API is wired as an MCP tool |
| paid-social | Read, Grep, Glob, WebFetch, WebSearch, Write, Bash | Same as seo; reopen if an ads API is wired as an MCP tool |
| finance-analyst | Read, Grep, Glob, WebFetch, WebSearch, Write | Reads the web, writes the evidence pack; no PR step, so no Bash |
| gh-triage | Read, Grep, Glob, Bash, Write | Bash for `gh`; Write for the message and last-run files named in the scope file |
| librarian | Read, Grep, Glob, Write, Edit, Bash | Edit for page updates; Bash for the idempotent inbox-to-sources move |

`Edit` is withheld from every web-reading role, but only where the list is applied (see above), and
`Write` plus `Bash` can still change files. Opening a PR needs `Bash`, which is why the four
PR-capable web roles have it; `finance-analyst` has no PR step and stays without it.
`tests/test_role_allowlists.bats` pins these exact lists.

**Accepted residual risks** (2026-10-17, accepted by the operator; documented, not fixed)
1. `Read` plus `WebFetch`: a prompt-injected role can send any readable local file to an
   attacker-chosen URL.
2. `Bash` on a role that reads untrusted content: gh-triage and librarian have it, and now researcher,
   seo, paid-search and paid-social too. A prompt-injected role reading untrusted web or issue text
   can run a shell. gh-triage and the four PR roles run `gh` and git with the host user's
   credentials; the repo stores no token, but in effect the shell can use whatever the user is
   logged in with.
3. Remote paths opened by `Bash` on the four web roles (new in H-04b): injected web content can make
   the role push a branch (for example one that edits a workflow file) that reaches CI with repo
   secrets, or open a public PR as an outlet for data read locally. `github.com` must stay
   reachable for the PR step, so a "no network except allowed hosts" sandbox would not stop this.
4. The PR hand-off is an unscoped second-order injection outlet: text derived from untrusted web
   content lands in a PR that reviewers, gh-triage and orchestrators then read as repo content.
   No role text scopes the target repo or branch, or forbids pushing to the default branch,
   force-pushing or merging.
5. `Write` is unscoped on all seven roles: it can overwrite shell rc files, hook scripts and similar.
6. `tools:` is not applied on every runtime (OpenCode, Codex; see above). On those targets the lists
   give no protection beyond the few OpenCode denials named above.
7. Roles outside this list. 17 of the 39 public roles (implementers and orchestrators) carry no
   `tools:` and inherit every tool. Roles outside this repo (private desks) that read untrusted web
   content may also lack `tools:`; this repo does not track them. `security-reviewer` already has
   `Bash` plus the web tools, so these residuals are wider than the seven-role table.
8. Public repos with untrusted content (issues, PRs, web pages) are explicitly not solved. Operator:
   "that risk is not going to go away in the agentic world".

**What would reduce them**
- Scoped Bash rules (allow only `gh pr create`, a push of the role's own branch, and the like)
  instead of a blanket `Bash`.
- Claude Code `disallowedTools` and permission rules in the project's settings, and the repo's
  opt-in guard hooks (`pre-bash-no-bypass`, `pre-bash-secret-scan`; off by default).
- Scoping the PR hand-off in role text (target repo and branch; never push to the default branch,
  force-push or merge) plus branch protection and no repo secrets on CI runs for branches from
  these roles.
- MCP-only tools: wrap the few outward actions as MCP tools with fixed arguments and drop `Bash`.
- Sandboxing: run these roles in a container or worktree with no credentials beyond the task's and a
  read-only view of everything outside the output directory. Network limits help against
  exfiltration to arbitrary hosts, but not against pushing to `github.com`.

## Spec-driven repos (OpenSpec)

`_core/AGENTS_base.md` carries a boot-sequence check for
[OpenSpec](https://openspec.dev): every composed agent looks for `SPECS.md` or an
`openspec/` directory at the repo root, and if either is present it treats the
repo as spec-driven — read the spec before implementing, continue an existing
change rather than opening a parallel one, propose and stop for review rather
than skipping to code, and write deltas instead of editing current-truth specs.

Two properties make this cheap:

- **One edit reaches every agent.** It lives in `_core`, not per-role, so all
  composed agents across every project inherit it on the next recompose.
- **It's conditional.** A repo with neither marker is untouched — agents behave
  exactly as before, so this imposes nothing on repos that haven't opted in.

The convention itself is documented in
`project-factory/templates/_common/SPECS.md`, which `cut-project.sh` lays down on
every project it seeds or retrofits. the-grid wires the 12 `openspec-*` skills
that drive the workflow; they need the CLI
(`npm i -g @fission-ai/openspec@latest`).

## Rosters & delegation

An orchestrator's roster — the agents it can hand work to — is **generated from the
compose config**, not hand-written. Each orchestrator declares its reports with a
`delegates_to:` list; the delegation topology lives with the team definition as its
single source of truth:

```yaml
agents:
  - role: ceo-orchestrator
    delegates_to: [tech-lead, product-manager, growth-hacker]
  - role: tech-lead
    delegates_to: [backend-dev, frontend-dev, designer, ...]
```

`compose.py` renders a `| Agent | Owns |` table from that list and substitutes it
into the role's `AGENTS.md` at the `{{ROSTER_TABLE}}` token. The `Owns` text is each
role's `role.yaml` `owns:` field, falling back to the first sentence of its
`summary`. Behavioural routing rules (e.g. the CEO's "never reach specialists
directly") stay as authored prose in `AGENTS.md` — only the table is generated.

Validation is symmetric and loud, so a roster can never silently drift out of sync
with the team:

- a role whose `AGENTS.md` carries `{{ROSTER_TABLE}}` **must** have a `delegates_to`
  in the config (use `delegates_to: []` for a solo/demo team), and vice-versa;
- every name in `delegates_to` must be a role present on the same team.

Any violation is a hard `compose.py` error. **grid topology:**

- `ceo-orchestrator` → `tech-lead`, `product-manager`, `growth-hacker` (the three leads)
- `tech-lead` → engineering + data/research specialists
- `growth-hacker` → the marketing arm — a player-coach lead that also runs growth experiments itself

## Status

**Claude Code delivery target is done and live.** Four public projects compose
independently and are gated independently:

| Config | Roles | Shape |
|---|---|---|
| `examples/grid.yaml` | 24 | 3 orchestrators (`ceo-orchestrator`, `tech-lead`, `growth-hacker`) + 21 specialists — the dev team |
| `examples/finance-desk.yaml` | 6 | `finance-manager` → sentinel/analyst/strategist/risk-officer/scribe. Standalone: deliberately not in anyone's `delegates_to` |
| `examples/core.yaml` | 6 | `gh-triage`, `librarian`, `researcher`, `platform-engineer`, `context-engineer`, `tron` (the front door, `/tron`) — cross-desk infra, no delegation chain, meant to stay wired everywhere |
| `examples/learning-desk.yaml` | 3 | `morpheus` (Socratic tutor), `oracle` (learns about the operator), `tank` (agent-to-agent lessons). All manual. `bare_names: true` so they are `/morpheus`, `/oracle`, `tank`. Data is private: `~/.the-grid-private/learning/` |

Orchestrator rosters are generated from each one's `delegates_to` (see **Rosters
& delegation** above). `compose.py` emits both the OpenClaw 5-file shape and the
Claude Code skill/subagent shape; `scripts/wire.sh` wires the CC output into
`~/.claude/`. Private projects compose the same way from an external roles
directory (see **Private projects** above).

Remaining work (see repo-root `TODO.md` and the issue tracker):
- **Harness targets: real-install checks** — `codex`, `opencode`, `gemini-cli` and
  `portable` are implemented (see **Running it**); none has been smoke-tested on a
  real install (`docs/harnesses.md` lists what is unverified). Cursor has rule packs
  only (`scripts/rules.py emit --harness cursor`), no agent target.
- **OpenClaw + Paperclip targets** — 5 files → workspace + `openclaw.json`; the
  async/autonomous heartbeat loop. Deferred (Claude Code was built first). Implementation
  plan, scoped to a curated orchestrator roster + chunked into single-session specialist
  work: `agent-factory/openclaw/README.md`.
- **Stack overlays** — `stacks/*` are still `stack.yaml` stubs with empty `fragments`.

*(Machine gating is **done**: `project:<name>` entries in the baseline or a
per-machine overlay control which composed projects `wire.sh` links. With no
`project:` entry anywhere it wires all of them — the legacy fallback.)*

## Runtime assumptions

- The canonical agent is the **live OpenClaw 5-file model** (SOUL / IDENTITY /
  AGENTS / USER / MEMORY) + skills — verified against the running system on
  a Linux box, not the (outdated 3-file) playbook.
- Target surface is **Claude Code + ACP** (swappable coding CLI), not Claude Code
  alone. Content stays LCD (lowest common denominator) where possible.
- Memory starts as flat **MEMORY.md** / signal files; a queryable DB (gbrain)
  replaces it later. Don't hard-bake gbrain assumptions yet.
- Handoff is **async** — signal files (`signals/→agent.md`, as the live system
  does) or PR + webhook. Not a live `sessions_spawn`.
- Stacks are overlays. LAMP is one overlay among several, not the spine.
- `compose.py` is a multi-target compiler: one 5-file source → OpenClaw agent
  (near-native), Claude Code subagent (flattened `.md`), or Claude Code skill
  (boots via the AGENTS.md sequence).

## Profiles and per-project deploy

`compose.py` renders **full** agents (persona, memory seed, boot sequence). `deploy.py`
renders **lean** ones by default — a deterministic selection from the same role files — and
writes them into a chosen project's `.claude/`. See the "Drift checks, the commit gate, and
per-project agents" section of the repo `CLAUDE.md`. `compose.py --lint-roles` and
`--check` keep roles and composed output honest.

## Hook profiles

`deploy_hooks.py` writes the grid's Claude Code guard hooks into one project's settings.
It is a separate tool from `deploy.py` (that one needs roles and refuses the-grid itself);
the two share only `.grid/project.yaml`, where `deploy_hooks.py` reads the `hooks:` key
and `deploy.py` ignores it.

```yaml
# <project>/.grid/project.yaml
hooks:
  profile: standard   # off | minimal | standard | strict (absent = off)
  target: local       # local = .claude/settings.local.json (default) | shared = .claude/settings.json
```

```bash
agent-factory/.venv/bin/python agent-factory/deploy_hooks.py <project>            # emit
agent-factory/.venv/bin/python agent-factory/deploy_hooks.py <project> --check    # drift; exit 1
agent-factory/.venv/bin/python agent-factory/deploy_hooks.py --list               # scope, profile, cost
```

- Resolution: `--profile` / `--target` flag, then the file, then `off` / `local`.
- Each entry is `bash "${GRID_DIR:-$HOME/.the-grid}/hooks/run.sh" <id> # GENERATED by the-grid deploy_hooks.py`.
  No absolute path, so a committed `settings.json` works on any machine with the-grid.
- The trailing comment is the ownership mark: only handlers of exactly that shape are ever
  edited or removed. Hand-written hooks and every other settings key are left alone.
- Both settings files are swept on every run; additions go only to the target file, so
  changing `target` moves the entries. Lowering the profile (or `off`) removes the rest.
- Invalid JSON, a non-object file or a symlinked `.claude` / settings file aborts before any write.
- Re-running with unchanged inputs writes nothing. The catalogue is `hooks/catalogue.json`
  (`GRID_DIR` overrides which grid is read). See `hooks/README.md` for the hooks and their cost.

## Golden outputs and the neutral identity

`scripts/compose-goldens.sh` composes a small fixture project (`tests/fixtures/compose/`) under
every target and byte-compares it with the committed trees in `tests/fixtures/compose/golden/`.
Any change to `compose.py`, `_core/`, a template, `models.yaml` or `openclaw/roster.json` changes
that output, so run `bash scripts/compose-goldens.sh --update` in the same PR and review the diff
(`--check` is the default; it is skipped, loudly, when the venv is absent). A new compose target is
appended to `TARGETS` in the script. The fixture is composed with `GRID_USER_CONFIG` pointing at
`agent-factory/user.public.yaml`, the tracked neutral identity (`machine: "your-machine"`), so no
personal value or hostname reaches a tracked file. `GRID_USER_CONFIG` replaces `user.yaml` for any
compose run; a set-but-missing path exits 1 instead of falling back to the hostname.
