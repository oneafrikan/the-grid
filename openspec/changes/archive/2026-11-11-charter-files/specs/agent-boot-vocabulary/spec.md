## Purpose

Put one compact evidence vocabulary and the signal-filing instructions in every composed agent's operating rules, so claims carry their warrant and memory rules are always in context.

## ADDED Requirements

### Requirement: Stage vocabulary in AGENTS_base
`agent-factory/_core/AGENTS_base.md` SHALL contain a section `## Evidence and Stages` that names all six stages `wip`, `provisional`, `established`, `canonical`, `superseded`, `retired`, gives their order and one-line meanings, and states that the stage an agent files is a proposal: `canonical`, supersession and contradiction are always decided by a human, and `superseded` and `retired` are set by a human.

#### Scenario: All six present
- **WHEN** the section is read
- **THEN** each of the six names appears in it exactly as written

#### Scenario: Stage is a proposal
- **WHEN** the section is read
- **THEN** it says `canonical`, and anything that supersedes or contradicts an entry, is decided by a human

### Requirement: Warrant rule
The section SHALL state that every claim carries its warrant (what was run or read, and where), that a claim with no warrant is `wip` and is never promoted, and that completion claims are tagged RAN, READ or UNTESTED with a result not seen to run counted as READ.

#### Scenario: Rule text
- **WHEN** the section is searched
- **THEN** it contains RAN, READ, UNTESTED and the sentence that `wip` is never promoted

### Requirement: Other vocabularies are not stages
The section SHALL state that confidence (H/M/L) and source tier are not stages and belong in the warrant text. The change SHALL NOT delete or edit RAN/READ/UNTESTED, STATED/OBSERVED/INFERRED, H/M/L or `tier` in any role file.

#### Scenario: Roles untouched
- **WHEN** `git diff --stat` for the change is inspected
- **THEN** no `agent-factory/roles/*` file is modified

### Requirement: Memory rules
`AGENTS_base.md` SHALL contain a section `## Memory` that names what is always in context (the CLAUDE.md learnings summary, up to 6 instincts at SessionStart when `learning: on` in `.grid/project.yaml`, the canon lines in MAP.md) and what is on demand only (`LEARNINGS.md`, `knowledge/` below canon), and SHALL instruct the agent never to present unread on-demand material as known.

#### Scenario: Both lists
- **WHEN** the section is read
- **THEN** it names `LEARNINGS.md`, `knowledge/`, instincts, `learning: on` and MAP.md canon lines

### Requirement: Filing instructions
`AGENTS_base.md` SHALL contain a section `## Filing a Knowledge Signal` that applies only when the repo has `signals/README.md`, and states: one new file per signal in `signals/`, never edited after commit, name `YYYYMMDDTHHMMSSZ-<filer>-<hash6>.md` (or the `scripts/knowledge.py file` helper), frontmatter keys `filed_by`, `claim`, `stage` (one of `wip`, `provisional`, `established`, `canonical`), `warrant`, `status: pending` plus optional `supersedes`, `contradicts`, `confirms` (each `K-<hash8>`) and `guardrail` (`GUARDRAILS#Gn`), no secrets or personal data, committed but never moved by the filer, and that handoffs remain `signals/→<agent>.md`.

#### Scenario: Conditional
- **WHEN** the section is read
- **THEN** its first line says it applies only if `signals/README.md` exists

#### Scenario: Handoff section intact
- **WHEN** the file is diffed against `next`
- **THEN** the "Signal Protocol (handoff)" section is unchanged

### Requirement: Bounded and merge-safe
The three added sections SHALL total at most 2000 bytes (the specified text is exactly 1670), SHALL be the only edit to `AGENTS_base.md` by this and the sibling staged changes, SHALL use headings that appear in no `agent-factory/roles/*/AGENTS.md`, and SHALL require no change to `agent-factory/compose.py`.

#### Scenario: Size
- **WHEN** the text from the line `## Evidence and Stages` up to, but excluding, the blank line before `## Signal Protocol (handoff)` is extracted and measured with `wc -c`
- **THEN** it is exactly 1670 and in any case at most 2000
- **AND** `AGENTS_base.md` is 4578 bytes (2907 + 1670 + one blank-line separator)

#### Scenario: Heading unique
- **WHEN** `grep -l '^## \(Evidence and Stages\|Memory\|Filing a Knowledge Signal\)' agent-factory/roles/*/AGENTS.md` runs
- **THEN** it prints nothing

#### Scenario: Compose unchanged and current
- **WHEN** the change is built
- **THEN** `git diff --name-only` lists no `compose.py`, and `compose.py <cfg> --target claude-code --check` passes for the four public projects after recomposing

### Requirement: Reaches every full-profile agent
After recomposing, every full-profile Claude Code agent and skill for the four public projects SHALL contain the three new headings. Lean-profile project agents (`deploy.py`) are not covered; their route is the project trailhead and `signals/README.md`.

#### Scenario: Composed output
- **WHEN** the four projects are composed and `agent-factory/projects/*/_claude-code/**/*.md` is searched
- **THEN** every generated agent file that embeds the merged `AGENTS.md` contains `## Evidence and Stages` (the build task records which generated files embed it; UNVERIFIED for orchestrator skills)

#### Scenario: Lean deploy unchanged
- **WHEN** `deploy.py` renders a lean agent
- **THEN** its output is unchanged by this change
