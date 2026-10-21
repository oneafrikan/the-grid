# Security

## Scope

`scripts/wire.sh` and `scripts/bootstrap.sh` write to your home directory, mostly
symlinks that point back into this repo. Read both scripts before running them.

What they write (the same list as [INSTALL.md](INSTALL.md), "What it touches"):

- **`~/.claude/skills/` and `~/.claude/agents/`**: symlinks into this repo.
- **`~/.claude/settings.json`**: one generated auto-handoff SessionEnd hook entry,
  on by default. Hand-written hooks and keys are left alone. Opt out with
  `-hook:auto-handoff` in the baseline or a machine overlay.
- **`~/.claude/rules/grid/`**: symlinks to rule packs. Opt-in: nothing is written
  without a `rules:<pack>` entry.
- **Other harness directories**: opt-in via `harness:<name>` entries, never
  replacing an entry that is already there.
- **Inside the clone**: `.wired.manifest`, `SKILLS.md`, the personal baseline and
  machine overlay files, `core.hooksPath` set to `.githooks`, and with
  `--with-agents` the `agent-factory/.venv` and `agent-factory/projects/`.

Neither script writes `~/.grid/`; only `grid install` does.

Code pulled in through git submodules under `repos/` is third-party and is not
reviewed here beyond the offline audit that `wire.sh` runs before it links
anything. Read a skill before you wire it.

## Reporting a vulnerability

- Use GitHub private vulnerability reporting:
  <https://github.com/oneafrikan/the-grid/security/advisories/new>
- Do not open a public issue for a vulnerability.
- There is no email address for reports.
- Acknowledgement is best-effort, within 7 days.
- There is no bounty program.

## Supported versions

Only the latest tag and `main` are supported. Fixes land on `main`.

## Out of scope

- Vulnerabilities in upstream submodules: report them to the upstream project.
