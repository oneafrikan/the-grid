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

#### Scenario: Environment overrides the manifest
- **WHEN** the manifest activates `codex` and `GRID_HARNESS=pi` is set
- **THEN** only `claude` and `pi` are active for that run

#### Scenario: Unknown harness is rejected
- **WHEN** `GRID_HARNESS=nonesuch` is set
- **THEN** `wire.sh` exits 2, names the valid harnesses and changes nothing

#### Scenario: Precedence matches Claude
- **WHEN** a root skill and a repo skill share a name and a shared-dir harness is active
- **THEN** the shared directory holds one link for that name, resolving to the root copy

### Requirement: Portability filter for non-Claude harnesses

`wire.sh` MUST NOT link a skill into a non-Claude harness directory when the skill references Claude-only paths or breaks the Agent Skills name or description limits. It SHALL record the skip reason in the wiring manifest.

#### Scenario: Claude-specific skill is skipped
- **WHEN** a wired skill's files reference `~/.claude/`
- **THEN** it is linked into the Claude skills directory and not into `~/.agents/skills`, and its manifest row says `claude-specific`

#### Scenario: Over-long description is skipped
- **WHEN** a skill's description is longer than 1024 characters
- **THEN** it is skipped for non-Claude harnesses with reason `description-long`

#### Scenario: Name differing from directory is skipped
- **WHEN** a skill directory is `template` and its frontmatter name is `template-skill`
- **THEN** it is skipped for non-Claude harnesses with reason `name-mismatch`

### Requirement: Ownership, idempotency and drift check across harness directories

On each run, `wire.sh` SHALL remove only symlinks whose target is under `GRID_DIR` in every registry directory, and SHALL leave real files and directories alone. `wire.sh --check` SHALL exit 1 when any registry directory differs from a fresh wire.

#### Scenario: Second run is a no-op
- **WHEN** `wire.sh` runs twice with `harness:codex` active
- **THEN** the second run leaves every link and the wiring manifest byte-identical

#### Scenario: Deactivated harness loses its links
- **WHEN** `-harness:codex` is added to the overlay and `wire.sh` is re-run
- **THEN** the grid-owned links in the Codex directories are gone and foreign links remain

#### Scenario: Real directory is never replaced
- **WHEN** `~/.agents/skills/foo` is a real directory and `foo` is a wired skill
- **THEN** it is skipped as "real dir, not managed" and left untouched

#### Scenario: Drift is detected
- **WHEN** a stale grid-owned link exists in a non-Claude registry directory
- **THEN** `wire.sh --check` exits 1 and lists it

#### Scenario: Tests cannot reach the real home
- **WHEN** a test sets `GRID_HARNESS_HOME` to the real home directory
- **THEN** the test helper aborts before any write
