# Design: workflow-upgrades

## Context

Five small, mostly independent pieces. Everything is bash or Python stdlib (PyYAML is already in the agent-factory venv), idempotent, and tested with bats under `tests/` against temp dirs. Facts checked while drafting:

- `claude` 2.1.x accepts `--append-system-prompt-file <path>` (it errors with "Append system prompt file not found" on a bad path).
- `compose.py --lint-roles` caps a role's own `AGENTS.md` at 4096 bytes (specialists) and 5120 (orchestrators). The cap measures `roles/<role>/AGENTS.md` only, not the merged output. Today `tech-lead/AGENTS.md` is 5113 bytes, `growth-hacker` 5092, `finance-manager` 5066, `ceo-orchestrator` 4998. There is no room to add text to any orchestrator `AGENTS.md`.
- The lean profile (`render_lean_body`) reads role-layer files only and ignores `_core/`. So a `_core/AGENTS_base.md` edit never reaches lean deploys or the eval harness (which renders lean).
- `compose.py` reads `agent-factory/user.yaml` (git-ignored, personal) for the IDENTITY nameplate and falls back to the hostname. Composed output is therefore machine-specific unless the fixture pins it.
- `GRID_PRIVATE_ROLES_DIR` makes a role directory there win over the public one of the same name. A fixture tree can therefore shadow `ceo-orchestrator`, `tech-lead`, `growth-hacker` and `product-manager`, which is what the `paperclip` and `openclaw-native` targets look up by name. A smoke run with five fixture roles rendered all four targets (`claude-code`, `openclaw`, `paperclip`, `openclaw-native`) with no hostname, date or absolute path in the output once `user.yaml` is pinned.
- `run_evals.py` already refuses real runs without `GRID_EVALS=1` and `--yes`, caps each run (`--budget`, default $0.25), and prints the worst case first. 22 cases across 15 roles exist (worst case about $16.50 for all).
- Issue #23 (compose golden-output tests) is folded in here: the decision-brief change alters every orchestrator's composed output, which is exactly what goldens exist to make visible.

## Approach

### 1. Context modes

```
contexts/dev.md  contexts/research.md  contexts/review.md   # each <= 1200 bytes
contexts/aliases.sh                                           # sourced from ~/.zshrc or ~/.bashrc
scripts/contexts-hint.sh                                      # prints the line to add; changes nothing
```

`aliases.sh` resolves its own directory (bash: `BASH_SOURCE`, zsh: `${(%):-%x}`; `GRID_DIR` wins if set; fallback `$HOME/.the-grid`) and defines:

```sh
alias claude-dev='claude --append-system-prompt-file "<dir>/dev.md"'
alias claude-research='claude --append-system-prompt-file "<dir>/research.md"'
alias claude-review='claude --append-system-prompt-file "<dir>/review.md"'
```

Aliases are defined only for files that exist. Extra arguments pass through (`claude-review -p "..."`). Content is the-grid's own wording of the ECC idea (mode, focus, behaviours, tools to favour, output shape), harness-neutral, no personal data. ECC's `contexts/` is the reference, not a copy.

### 2. Compose golden-output conformance (#23)

```
tests/fixtures/compose/
  fixture.yaml            # project "fx", slug "fx"; agents below
  user.yaml               # operator: Fixture Operator / machine: fixture-host / channels: none
  roles/                  # shadow roles, passed as GRID_PRIVATE_ROLES_DIR
    ceo-orchestrator/  tech-lead/  growth-hacker/  product-manager/  fx-eng/
  golden/
    claude-code/  openclaw/  paperclip/  openclaw-native/      # whole --out trees, byte-compared
scripts/compose-goldens.sh [--check|--update]
tests/test_compose_golden.bats
```

`fixture.yaml`:

```yaml
project: fx
slug: fx
agents:
  - role: ceo-orchestrator
    delegates_to: [tech-lead, growth-hacker, product-manager]
  - role: tech-lead
    delegates_to: [fx-eng]
  - role: growth-hacker
  - role: product-manager
  - role: fx-eng
```

Each fixture role is five lines of `role.yaml` (`name`, `title`, `summary`, `default_model: sonnet`, `orchestrator`, `model_rationale`), a one-line `SOUL.md` and `SKILL.md`, and an `AGENTS.md` with a `## Scope` section (orchestrators also `## Roster` with `{{ROSTER_TABLE}}`). The real `_core/`, templates and emitters are what the goldens pin; only role prose is fixed. `scripts/compose-goldens.sh` sets `GRID_PRIVATE_ROLES_DIR` to the fixture roles and `GRID_USER_CONFIG` to the fixture `user.yaml`, runs `compose.py fixture.yaml --target T --out <tmp>/T` for each target, then either `diff -r` against `golden/` (`--check`, exit 1 on any difference, default) or replaces `golden/` (`--update`). `GOLDEN_DIR` overrides the golden location so the negative test can point at a mutated copy.

`compose.py` gains one env override: `GRID_USER_CONFIG` (path) replaces `agent-factory/user.yaml` when set and non-empty.

### 3. Decision briefs

`agent-factory/_core/DECISION_BRIEF.md` (about 1.2 KB, linted at most 1500 bytes) is appended by `compose.py` to every role with `orchestrator: true`: in `render_agent` (full profile and the legacy openclaw target) after roster injection and before the stack overlay, and in `render_lean_body` after the role's AGENTS sections. Roles do not reference it; no token, no `AGENTS.md` edit, so the 5120 cap is untouched. Format (gstack's `D<N>` idea, cut down, plain text so every harness can show it, no tool call):

```
## Decision briefs

When a choice needs the human, send one brief per decision, in this shape:

**D<N>: <the decision in a few words>**
- Summary: <what is being decided, plain words, 1-2 sentences>
- Stakes: <what breaks, costs or locks in if this is wrong; say if irreversible>
- Options:
  - A (recommended): <option> - <one-line consequence>
  - B: <option> - <one-line consequence>
- Recommendation: A, because <one reason>.
- Reply with the label and letter, for example "D3: B".

Rules:
- Number briefs D1, D2, ... in order within a session; never reuse a number.
- 2 to 4 options. The recommendation is one of them. Include "do nothing" when it is a real option.
- One decision per brief. A bare letter answers only the newest open brief; if several are open, ask which.
- Do not ask what you can look up. Look it up first.
- Unattended (no human reading): take the recommended option, unless it is destructive or irreversible, then take the conservative one. Record every auto-chosen D<N> in the report.
```

### 4. Two-reviewer gate

A new section replaces tech-lead `SKILL.md` "Step 6 - QA handoff" (the existing handoff block stays inside it as the shared packet). `SKILL.md` has no size cap. Procedure:

1. Build one packet: PRD path, PR or diff range, verification command, acceptance criteria.
2. In one message, spawn `qa-engineer` and `security-reviewer` (the roles, never the same-named wired skill), each in a fresh context, same packet. Neither brief mentions the other reviewer's output.
3. Read both verdicts verbatim. qa-engineer: PASS or BLOCK. security-reviewer: PASS means no open Critical or High finding; anything else is BLOCK.
4. Both PASS: report "gate passed" with both evidence blocks (command and output). The human still approves production.
5. Any BLOCK: forward the findings verbatim to the owning specialist, one fix batch, then re-run both reviewers with fresh agents. Up to 3 rounds; a third BLOCK stops and escalates to the human with all rounds.
6. If either role is unavailable, say so; the gate is not passed.

Origin: ECC `santa-method` (dual independent review, both must pass, fix loop capped at 3). Taken: the invariants (isolation, identical inputs, both must pass, fresh reviewers each round, cap 3). Left behind: generic rubric JSON, batch sampling, a generator agent; the grid already has two purpose-built reviewer roles.

### 5. Eval selection by touched roles

`run_evals.py --changed <git-range>`:

1. `git -C <repo> diff --name-only -z --no-renames <range>`; failure exits 2 with `E_RANGE`.
2. Each changed path is mapped to roles, first rule wins:
   - built-in: `agent-factory/roles/<role>/**` and `evals/cases/<role>/**` select `<role>`;
   - then rules from `evals/touchfiles.yaml`, in file order.
3. Selected roles are intersected with roles that have at least one case (and with `--role` / `--case` if given). Roles selected but without cases are listed, not an error.
4. Normal flow continues with that case list: the plan, the worst-case spend, the `GRID_EVALS=1` plus `--yes` gate.

```yaml
# evals/touchfiles.yaml: files that change a role's behaviour without living in its own directory.
# First matching rule wins per file. paths use fnmatch (* also crosses /). roles: all | orchestrators | [role, ...]
rules:
  - paths: ["agent-factory/_core/DECISION_BRIEF.md"]
    roles: orchestrators
  - paths:
      - "agent-factory/_core/*"
      - "agent-factory/compose.py"
      - "agent-factory/deploy.py"
      - "agent-factory/models.yaml"
      - "agent-factory/stacks/*"
    roles: all
```

`--changed` adds `--max-total USD` (default 5.00): if runs x `--budget` for the selection exceeds it, exit 2 before any spend and say what to narrow or raise. `--role` alone keeps the old behaviour (no total cap added). `--validate` also checks `touchfiles.yaml` (known keys, `roles` value shape, named roles exist).

## Decisions

- Decided: contexts use `--append-system-prompt-file`, never `--system-prompt-file`. Replacing the system prompt drops Claude Code's tool, safety and git guidance and breaks on upgrades; appending adds about 200-300 tokens only in sessions started through the alias.
- Decided: `claude-dev`, `claude-research`, `claude-review` are shell aliases, as the brief asked, not functions. Arguments pass through; no logic is needed.
- Decided: the snippet is sourced, never run; `scripts/contexts-hint.sh` only prints the source line for the user's rc file. Installing through dev-env is out of scope.
- Decided: each context file is at most 1200 bytes and is asserted in a bats test, because they cost tokens on every turn of the session that uses them.
- Decided: `contexts/` sits at the repo root, not under `skills/`; it is a new asset type with a named use case (switching working mode per session) and is not wired by `wire.sh`.
- Decided: aliases are Claude Code only. Other harnesses have different flags; that belongs to the multi-harness change.
- Decided: golden fixtures shadow real role names (`ceo-orchestrator`, `tech-lead`, `growth-hacker`, `product-manager`) via `GRID_PRIVATE_ROLES_DIR` so all four targets can be exercised without editing `compose.py`'s role lookup. The fixture `fixture.yaml` carries a comment saying so.
- Decided: goldens cover all four existing targets (`claude-code`, `openclaw`, `paperclip`, `openclaw-native`), full profile only. Lean output is covered by `tests/test_deploy.bats`.
- Decided: golden check and update live in one script with `--check` (default) and `--update`; the bats test calls `--check`. No pytest.
- Decided: add `GRID_USER_CONFIG` to `compose.py` instead of copying fixture files into `agent-factory/user.yaml`; tests must never touch the real personal file.
- Decided: the decision brief is appended by `compose.py` to orchestrators automatically, not injected by a `{{TOKEN}}`, because no orchestrator `AGENTS.md` has headroom and a token needs an edit in each.
- Decided: the brief is inline in both profiles (about 1.2 KB), not moved to a `grid-reference/` file; it is needed on every decision and the saving would be small.
- Decided: the brief fragment is capped at 1500 bytes by a new lint code `E_DECISION_BRIEF` in `--lint-roles`, covering missing file, oversize, or missing the `D<N>` marker.
- Decided: the brief has no completeness score and no ELI10 block; Summary and Stakes replace them. Lettered options with one recommendation is the part that makes a reply answerable by label.
- Decided: reply format is `D<N>: <letter>` (matches the owner's "number anything you might reply to" rule).
- Decided: the two-reviewer gate is a section in `tech-lead/SKILL.md`, not a new `skills/` entry. The gate is a tech-lead release decision, the section travels with the role in lean deploys (a root skill would not exist in a deployed project), no new asset type is added, and `AGENTS.md` has no room anyway.
- Decided: gate scope is `tech-lead` only; other orchestrators route release work to it.
- Decided: maximum 3 review rounds, then human escalation (same cap as santa-method).
- Decided: security-reviewer PASS is "no open Critical or High finding"; Medium and Low are reported but do not block. The role itself rates severity; the gate does not re-rate.
- Decided: both reviewers always run, even when the change looks non-security; skipping one is the failure the gate prevents. Docs-only and draft work is exempt from the gate entirely.
- Decided: `--changed` takes any range `git diff` accepts (`origin/next...HEAD`, `HEAD~1`, a sha); no default range.
- Decided: touch-rule matching is first-match-wins per file with `fnmatch`, not union, so a narrower rule (`DECISION_BRIEF.md` to orchestrators) can precede a broad one.
- Decided: `evals/touchfiles.yaml` is a tracked data file the gate validates; a rule naming a missing role fails `--validate`.
- Decided: `--max-total` default is 5.00 USD and applies only with `--changed`. A broad change (`_core`, `compose.py`) selects every role, exceeds the cap, and refuses until a human raises it; that is the intended brake.
- Decided: nothing selected is a clean exit 0 that prints "no eval-relevant changes" and does not require `GRID_EVALS=1`.
- Decided: `run_evals.py` gets `--repo` (default: the repo root) so tests can point `--changed` at a temp git repo; cases and touchfiles resolve from it.
- Decided: new eval cases use `finding: "#0"` (no prior eval finding), matching existing convention, and `expect_today: unknown`.

## Risks

- Appending to orchestrator output changes composed output on every machine; the gate's `compose.py --check` fails until each machine recomposes. Tasks tell the implementer to recompose locally; `projects/` is git-ignored so nothing is committed.
- Fixture roles that share real names could confuse a reader; the fixture config comment and the goldens' own header text say they are fixtures.
- `contexts/aliases.sh` is outside the gate's shellcheck globs today; task 1 adds `contexts/*.sh`.
