## Purpose

Wire the-grid's curated skills into every supported agent harness, not only Claude Code. One registry and a per-machine set of active harnesses drive it, and one shared `~/.agents/skills` directory serves Codex, OpenCode, Gemini CLI, Pi and OpenClaw.

## ADDED Requirements

### Requirement: Active harness set and shared skills directory

`wire.sh` SHALL link the wired skill set into the skills directory of every active harness named in the harness registry, once per distinct directory. It SHALL treat `claude` alone as the active set when no `harness:` entry or `GRID_HARNESS` value is present.

#### Scenario: Default machine is unchanged
- **WHEN** no `harness:` entry and no `GRID_HARNESS` value is present
- **THEN** only the Claude skills and agents directories are written, and no other harness directory is created

#### Scenario: Two harnesses share one directory
- **WHEN** `machines/<host>.txt` contains `harness:codex` and `harness:opencode`
- **THEN** each portable wired skill appears exactly once in `~/.agents/skills`, and the Claude directories are still populated

#### Scenario: Paths with a space and XDG
- **WHEN** `GRID_HARNESS_HOME` contains a space and `harness:opencode` is active
- **THEN** the OpenCode agents land under `$GRID_HARNESS_HOME/.config/opencode/agents`, and an inherited `XDG_CONFIG_HOME` is ignored; with `GRID_HARNESS_HOME` unset, `XDG_CONFIG_HOME` relocates that path

#### Scenario: Environment overrides the manifest
- **WHEN** the manifest activates `codex` and `GRID_HARNESS=pi` is set
- **THEN** only `claude` and `pi` are active for that run

#### Scenario: Manifest grammar does not leak into other tools
- **WHEN** the baseline contains `harness:codex`
- **THEN** `catalog.sh --check` and `sources.sh` output is unchanged, and no repo named `harness:codex` is looked up

#### Scenario: Unknown harness is rejected
- **WHEN** `GRID_HARNESS=nonesuch` is set
- **THEN** `wire.sh` exits 2, names the valid harnesses and changes nothing

#### Scenario: Precedence matches Claude
- **WHEN** a root skill and a repo skill share a name and a shared-dir harness is active
- **THEN** the shared directory holds one link for that name, resolving to the root copy

### Requirement: Portability filter for non-Claude harnesses

`wire.sh` MUST NOT link a skill into a non-Claude harness directory when the skill references Claude-only paths or breaks the Agent Skills name or description limits. It MUST NOT link a submodule-root link (such as the `gstack` runtime root) into a non-Claude directory. It SHALL record the skip reason in the wiring manifest.

#### Scenario: Claude-specific skill is skipped
- **WHEN** a wired skill's files reference `~/.claude/`
- **THEN** it is linked into the Claude skills directory and not into `~/.agents/skills`, and its manifest row says `claude-specific`

#### Scenario: Over-long description is skipped
- **WHEN** a skill's description is longer than 1024 characters
- **THEN** it is skipped for non-Claude harnesses with reason `description-long`

#### Scenario: Runtime-root link is not a skill
- **WHEN** `~/.claude/skills/gstack` is the runtime-root link to the `repos/gstack` submodule root and a shared-dir harness is active
- **THEN** nothing named `gstack` is linked into `~/.agents/skills` by that link, and its manifest row says `runtime-root`

#### Scenario: Name differing from directory is skipped
- **WHEN** a skill directory is `template` and its frontmatter name is `template-skill`
- **THEN** it is skipped for non-Claude harnesses with reason `name-mismatch`

### Requirement: Ownership, idempotency and drift check across harness directories

On each run, `wire.sh` SHALL remove only symlinks whose target is a path inside `GRID_DIR` in every registry directory, and SHALL leave real files, directories and foreign symlinks alone. In a non-Claude registry directory it MUST NOT replace any existing entry, including a foreign or dangling symlink. `wire.sh --check` SHALL exit 1 when any registry directory differs from a fresh wire. When `GRID_DRY_HOME` is set, every registry path SHALL resolve under it instead of the real home.

#### Scenario: Second run is a no-op
- **WHEN** `wire.sh` runs twice with `harness:codex` active
- **THEN** the second run leaves every link and the wiring manifest byte-identical

#### Scenario: Deactivated harness loses its links
- **WHEN** `-harness:codex` is added to the overlay and `wire.sh` is re-run
- **THEN** the grid-owned links in the Codex directories are gone and foreign links remain

#### Scenario: Real directory is never replaced
- **WHEN** `~/.agents/skills/foo` is a real directory and `foo` is a wired skill
- **THEN** it is skipped with reason `exists, not managed`, left untouched, and the skip line does not begin `  skip (real dir, not managed)`

#### Scenario: Foreign symlink is never replaced
- **WHEN** `~/.agents/skills/foo` is a symlink to a directory outside `GRID_DIR` (or a dangling symlink) and `foo` is a wired skill
- **THEN** the link is unchanged after `wire.sh`, the manifest row says `exists, not managed`, and `wire.sh --check` still exits 0

#### Scenario: Sibling of the grid directory is not grid-owned
- **WHEN** a symlink in a registry directory targets `<GRID_DIR>-private/x` (a path that only shares the `GRID_DIR` prefix)
- **THEN** `wire.sh` leaves it in place, in the Claude directories and in every other registry directory

#### Scenario: Symlinked skills directory
- **WHEN** `~/.agents/skills` is itself a symlink to another directory holding a stale grid link
- **THEN** that stale link is removed by the next run and listed by `wire.sh --check` before it

#### Scenario: Drift is detected
- **WHEN** a stale grid-owned link exists in a non-Claude registry directory
- **THEN** `wire.sh --check` exits 1 and lists it

#### Scenario: Dry home redirects every harness path
- **WHEN** `GRID_DRY_HOME` is set, `GRID_HARNESS_HOME` is unset, `harness:codex` is active and the real home holds a sentinel in `.agents/skills` and `.codex/agents`
- **THEN** every harness link is written under `GRID_DRY_HOME`, nothing new appears under the real home, and the sentinels are byte-identical

#### Scenario: Tests cannot reach the real home
- **WHEN** a test sets `GRID_HARNESS_HOME` to the real home directory
- **THEN** the test helper aborts before any write
