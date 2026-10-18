# Design: workflow-upgrades

## Context

Six small, mostly independent pieces. Everything is bash or Python stdlib (PyYAML is already in the agent-factory venv), idempotent, and tested with bats under `tests/` against temp dirs. Facts checked against the code:

- `compose.py` sets `USER_CONFIG_PATH = HERE / "user.yaml"` (git-ignored, personal). `load_user_config()` (lru-cached) fills the IDENTITY nameplate's `{{operator}}`, `{{machine}}`, `{{channels}}`, and an empty `machine` falls back to `socket.gethostname()`. Composed output is therefore machine-specific unless the user config is pinned and `machine` is non-empty.
- `GRID_PRIVATE_ROLES_DIR` (set; empty disables) makes a role directory there win over the public one of the same name, and roles that exist only there resolve too. A fixture tree can therefore shadow `ceo-orchestrator`, `tech-lead`, `growth-hacker` and `product-manager`, which the `paperclip` (`PAPERCLIP_APEX_ROLE`, `PAPERCLIP_LEAD_ROLES`) and `openclaw-native` (`openclaw/roster.json`) targets look up by name. `compose.py` takes `--out DIR` and `--target {openclaw,claude-code,paperclip,openclaw-native}`.
- `compose.py --lint-roles` caps a role's own `AGENTS.md` at 4096 bytes (specialists) and 5120 (orchestrators, `ORCHESTRATOR_MAX_BYTES`). Today `tech-lead/AGENTS.md` is 5113 bytes, `growth-hacker` 5092, `finance-manager` 5066, `ceo-orchestrator` 4998: no room to add text to any orchestrator `AGENTS.md`.
- The lean profile (`render_lean_body`) reads role-layer files only and ignores `_core/`. A `_core/AGENTS_base.md` edit never reaches lean deploys or the eval harness (which renders lean via `deploy.py`).
- `run_evals.py` refuses real runs without `GRID_EVALS=1` and `--yes`, passes an explicit `--model` and `--max-budget-usd` per run (`--budget`, default $0.25), and prints the worst case first. Options today: `--validate`, `--dry-run`, `--yes`, `--role`, `--case`, `--runs`, `--budget`, `--cases-dir`, `--results-dir`; `GRID_CLAUDE` points at a stub in tests; validation errors print `E_CASE: ...`.
- CI (`.github/workflows/tests.yml`) builds no venv today, so every venv-gated test (`[ -x "$PY" ] || skip`) is skipped there. `foundations` group 2 owns the fix (venv build, `gate.sh` as the CI command, `next` trigger); this change makes no workflow edit. `scripts/gate.sh` runs venv-gated tests locally when `agent-factory/.venv` exists.
- The golden check can reuse `compose.py --check --out DIR`, which renders into a temp dir and reports `missing` / `unexpected` / `stale` relative paths against `DIR/<project>/...` (`diff_trees`). Each `write_*` emitter wipes and rewrites its own `<out>/<project>/_<target>` dir (the legacy `openclaw` target wipes `<out>/<project>`), so two targets must not share one `--out`.
- Checked in a scratch copy: a fixture of the shape below composes under all four targets (68 files, about 210 KB), is byte-identical across `PYTHONHASHSEED=1` and `=2`, and contains no `/Users/` or `/home/` text. A grep for the machine hostname is NOT a usable leak test: short hostnames match prose (a 5-letter host matched 12 of the 68 files, a 4-letter one 23).
- `tech-lead/SKILL.md` has `## Step 6 — QA handoff`; `qa-engineer` and `security-reviewer` are both in tech-lead's `delegates_to` in `examples/grid.yaml`.
- `claude` accepts `--append-system-prompt-file <path>`.

## Approach

### 1. Machine-independent identity + compose golden-output conformance (#23)

`compose.py` gains one env override, read once at import:

```python
# GRID_USER_CONFIG: path to the identity file; replaces agent-factory/user.yaml when set and
# non-empty. Used by goldens, committed personas and plugin bundles so no personal value or
# hostname reaches a tracked file. A set-but-missing path is a hard error (no silent hostname fallback).
USER_CONFIG_PATH = Path(os.environ["GRID_USER_CONFIG"]) if os.environ.get("GRID_USER_CONFIG") else HERE / "user.yaml"
```

`agent-factory/user.public.yaml` (tracked; the one neutral identity every public build uses):

```yaml
# user.public.yaml: neutral identity for anything composed into a tracked or shipped file
# (goldens, personas, plugin bundles). Use with GRID_USER_CONFIG=agent-factory/user.public.yaml.
# Never put personal values here; your own identity goes in user.yaml (git-ignored).
operator: ""
machine: "your-machine"   # must stay non-empty: blank falls back to the local hostname
channels: ""
```

Goldens:

```
tests/fixtures/compose/
  fixture.yaml            # project "fx", slug "fx"; agents below
  roles/                  # shadow roles, passed as GRID_PRIVATE_ROLES_DIR
    ceo-orchestrator/  tech-lead/  growth-hacker/  product-manager/  fx-eng/
  golden/
    claude-code/  openclaw/  paperclip/  openclaw-native/      # whole --out trees, byte-compared
scripts/compose-goldens.sh [--check|--update]
tests/test_compose_golden.bats
```

`fixture.yaml`:

```yaml
# Fixture for scripts/compose-goldens.sh. These roles intentionally shadow real role names
# (via GRID_PRIVATE_ROLES_DIR) so the paperclip and openclaw-native targets, which look roles
# up by name, are exercised. Role prose is fixed; _core/, templates and emitters are what is pinned.
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

Each fixture role `<r>` is exactly this shape (verified to pass `lint_role` and compose under all four targets):

```
role.yaml : name: <r> / title: Fixture <r> / summary: Fixture role <r>. / default_model: sonnet
            / orchestrator: true|false (true for ceo-orchestrator, tech-lead, growth-hacker) / model_rationale: fixture
SOUL.md   : "# Soul", blank line, "## Role identity", "Fixture soul."
SKILL.md  : "Fixture skill."
AGENTS.md : "## Scope", "Fixture scope."   (ceo-orchestrator and tech-lead also: blank line, "## Roster", blank line, "{{ROSTER_TABLE}}")
```

`scripts/compose-goldens.sh` holds `TARGETS=(claude-code openclaw paperclip openclaw-native)`. It `cd`s to the repo root, then exports, overriding whatever the caller had set: `GRID_PRIVATE_ROLES_DIR=tests/fixtures/compose/roles`, `GRID_USER_CONFIG=agent-factory/user.public.yaml`, `GRID_MODELS_FILE=agent-factory/models.yaml`. Golden trees live at `${GOLDEN_DIR:-tests/fixtures/compose/golden}/<target>/fx/...`.

- `--check` (default): for each target run `compose.py tests/fixtures/compose/fixture.yaml --target T --out "$GOLDEN_DIR/T" --check`, keep going after a failure, exit 1 if any target failed. compose's own output names the `missing` / `unexpected` / `stale` files. On failure the script ends with `fix: bash scripts/compose-goldens.sh --update, then review the diff`.
- `--update`: for each target `rm -rf "${GOLDEN_DIR:?}/T"` then `compose.py ... --target T --out "$GOLDEN_DIR/T"`. Idempotent.
- Venv absent: `--check` prints `venv absent, skipped` and exits 0 (same as `gate.sh`); `--update` exits 1 (an update that silently does nothing is worse than a failure).
- A later change that adds a compose target appends it to `TARGETS` and runs `--update`; it does not build a second golden harness.

CI is not touched here. `foundations` group 2 builds the venv and runs `gate.sh` in CI, which is what makes "changing an emitter fails the suite" true on every PR and not only on machines with a venv.

### 2. Decision briefs

`agent-factory/_core/DECISION_BRIEF.md` (about 1.2 KB, linted at most 1500 bytes) is appended by `compose.py` to every role with `orchestrator: true`: in `render_agent` (feeds every target) after `inject_roster` and before the stack overlay, and in `render_lean_body` after the role's AGENTS sections and before the stack overlay. Roles do not reference it: no token, no `AGENTS.md` edit, so the 5120 cap is untouched. Format (gstack's `D<N>` idea, cut down, plain text so every harness can show it, no tool call):

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

### 3. Two-reviewer gate

A new section replaces tech-lead `SKILL.md` "Step 6 — QA handoff" (the existing handoff block stays inside it as the shared packet). `SKILL.md` has no size cap. Procedure:

1. Build one packet: PRD path, PR or diff range, verification command, acceptance criteria.
2. In one message, spawn `qa-engineer` and `security-reviewer` (the roles, never the same-named wired skill), each in a fresh context, same packet. Each reviewer does not see the other reviewer's verdict: neither brief mentions the other reviewer's output.
3. Read both verdicts verbatim. qa-engineer: PASS or BLOCK. security-reviewer: PASS means no open Critical or High finding; anything else is BLOCK.
4. Both must pass. Both PASS: report "gate passed" with both evidence blocks (command and output). The human still approves production.
5. Any BLOCK: forward the findings verbatim to the owning specialist, one fix batch, then re-run both reviewers with fresh agents. Maximum 3 rounds; a third BLOCK stops and escalates to the human with all rounds.
6. If either role is unavailable, say so; the gate is not passed.

Docs-only and draft work is exempt (one line). Step 6 MUST contain these exact, case-sensitive strings, which the bats test greps with `grep -F` inside the Step 6 section only: `qa-engineer`, `security-reviewer`, `Both must pass.`, `does not see`, `Maximum 3 rounds`. Origin: ECC `santa-method` (dual independent review, both must pass, fix loop capped at 3). Taken: the invariants. Left behind: generic rubric JSON, batch sampling, a generator agent.

### 4. Eval selection by touched roles

`run_evals.py --changed <git-range>`:

1. `git -C <repo> diff --name-only -z --no-renames <range>`; failure prints `E_RANGE: ...` to stderr and exits 2.
2. Each changed path maps to roles, first rule wins: built-in `agent-factory/roles/<role>/**` and `evals/cases/<role>/**` select `<role>`; then rules from `<repo>/evals/touchfiles.yaml`, in file order.
3. Selected roles are intersected with roles that have at least one case (and with `--role` / `--case` if given). Selected roles without cases are listed, not an error.
4. Normal flow continues with that case list: the plan, the worst-case spend, the `GRID_EVALS=1` plus `--yes` gate.

```yaml
# evals/touchfiles.yaml: files that change a role's eval prompt without living in its own directory.
# The eval prompt is the LEAN render (compose.render_lean_body via deploy.py): role files, stack overlays,
# the roster from examples/*.yaml, and for orchestrators the decision brief. Other _core/ files and
# models.yaml do not enter it (evals pass the model tier, not models.yaml's id), so they are not listed;
# add a rule if one starts to.
# First matching rule wins per file. paths use fnmatch (* also crosses /). roles: all | orchestrators | [role, ...]
rules:
  - paths: ["agent-factory/_core/DECISION_BRIEF.md"]
    roles: orchestrators
  - paths:
      - "agent-factory/compose.py"
      - "agent-factory/deploy.py"
      - "agent-factory/stacks/*"
      - "agent-factory/examples/*"
    roles: all
```

`--changed` adds `--max-total USD` (default 5.00): if the plan's worst case (`total_runs * --budget`, the figure on the `plan:` line) exceeds it, exit 2 before any spend and name `--role` and `--max-total` as the ways out. The check runs before the `--dry-run` return, so `--dry-run` shows the refusal. `--changed` narrows the case list before `--list`, the plan and the run. `--role` alone keeps the old behaviour. `--repo` (default: the repo root) points `--changed` and the touchfile lookup at another checkout, for tests; `--cases-dir` keeps its current default. `--validate` also checks `<repo>/evals/touchfiles.yaml`.

### 5. Context modes

```
contexts/dev.md  contexts/research.md  contexts/review.md   # each <= 1200 bytes
contexts/aliases.sh                                           # sourced from ~/.zshrc or ~/.bashrc
```

`aliases.sh` resolves its directory (`GRID_DIR` wins if set; else bash `BASH_SOURCE` / zsh `${(%):-%x}`; fallback `$HOME/.the-grid`) and defines, only for files that exist:

```sh
alias claude-dev='claude --append-system-prompt-file "<dir>/dev.md"'
alias claude-research='claude --append-system-prompt-file "<dir>/research.md"'
alias claude-review='claude --append-system-prompt-file "<dir>/review.md"'
```

Two shellcheck directives are needed because the gate runs `shellcheck -S warning`: `# shellcheck disable=SC2296` on the zsh `${(%):-%x}` line (otherwise a parse error) and `# shellcheck disable=SC2139` on the `alias` lines (expanding the directory at definition time is intended). Checked: with both, `shellcheck -S warning contexts/aliases.sh` is clean and the file works under `/bin/bash` 3.2 and zsh. Its header comment shows the exact line to add to a shell rc (`source "$HOME/.the-grid/contexts/aliases.sh"`). Content is the-grid's own wording of the ECC idea (mode, focus, behaviours, tools to favour, output shape), harness-neutral; `repos/ecc/contexts/` is the reference, not a copy.

### 6. Neutral identity for full-profile per-project deploys (Q7)

`deploy.py --profile full` renders the IDENTITY nameplate into a project's `.claude/` (lean does not render it: `render_lean_body` never calls `render_identity`). A project repo is often tracked or shared, so by default the nameplate must not carry `user.yaml` values or the hostname.

- `deploy.py` gains `--identity PATH`. Before `render_all`, for every profile, it sets `compose.USER_CONFIG_PATH = Path(args.identity) if args.identity else compose.HERE / "user.public.yaml"` and calls `compose.load_user_config.cache_clear()`. An ambient `GRID_USER_CONFIG` is ignored by `deploy.py` (an exported personal path must not leak into a project repo by accident); only `--identity` opts in.
- `--identity` naming a missing file: `die(f"identity file not found: {path}")` (non-zero exit, nothing written).
- With `--profile lean` the flag is accepted and has no effect on output (lean has no nameplate).
- The lock does not record the identity. `--check` and bare re-runs render with `user.public.yaml` unless `--identity` is passed again; a deploy made with `--identity` therefore reports drift under a bare `--check`. Documented in the `deploy.py` docstring.

## Decisions

- Decided: `GRID_USER_CONFIG` and `agent-factory/user.public.yaml` are introduced here, in group 2, and nowhere else; `multi-harness` and `plugin-marketplace` depend on `workflow-upgrades#2` and reuse both. It stays group 2 (group 1, context modes, is independent and touches no shared file) so that cross-change reference is stable; it depends on nothing else in this change.
- Decided: `user.public.yaml` values are `operator: ""`, `machine: "your-machine"`, `channels: ""`. `machine` must be non-empty or the hostname fallback leaks into tracked output.
- Decided: a set `GRID_USER_CONFIG` pointing at a missing file exits 1 with a message naming the path; it never falls back to `user.yaml` or the hostname.
- Decided: relative `GRID_USER_CONFIG` paths resolve against the current directory (plain `Path`); scripts run from the repo root.
- Decided: goldens use `user.public.yaml`, not a separate fixture identity, so the tracked public identity is itself pinned by the goldens.
- Decided: golden fixtures shadow real role names via `GRID_PRIVATE_ROLES_DIR` so all four targets run without editing `compose.py`'s role lookup.
- Decided: goldens cover all four existing targets, full profile only. Lean output is covered by `tests/test_deploy.bats`.
- Decided: golden check and update live in one script with `--check` (default) and `--update`, targets in one `TARGETS` array; the bats test calls `--check`. No pytest.
- Decided: goldens also depend on the real `_core/`, templates, `models.yaml` and `openclaw/roster.json`; editing any of those requires `compose-goldens.sh --update` in the same PR. That is the point of #23.
- Decided: this change does not edit `.github/workflows/tests.yml`. The CI venv step, the `next` trigger and the stop rule for latent CI-only failures belong to `foundations` group 2; group 2 here depends on it (`foundations#2`).
- Decided: the golden check calls `compose.py --check --out`, not `diff -r`: one drift implementation, and it reports `missing` / `unexpected` / `stale` by relative path.
- Decided: `compose-goldens.sh` pins `GRID_PRIVATE_ROLES_DIR`, `GRID_USER_CONFIG` and `GRID_MODELS_FILE` itself and `cd`s to the repo root, so ambient values (and a private roles tree under `$HOME`) cannot change the result; a bats test proves it.
- Decided: the leak test greps for `/Users/`, `/home/`, `$REPO_ROOT` and `$HOME`, and asserts `your-machine` is present in the golden IDENTITY text. It does not grep for the hostname (substring false positives); the `your-machine` assertion proves the hostname fallback did not run.
- Decided: the determinism test runs `--update` twice with different `PYTHONHASHSEED` values (1 and 2); two runs under one random seed could pass by luck. The script itself does not pin the seed.
- Decided: the decision brief is appended by `compose.py` to orchestrators automatically, not injected by a `{{TOKEN}}`, because no orchestrator `AGENTS.md` has headroom.
- Decided: the brief is inline in both profiles (about 1.2 KB), not moved to a `grid-reference/` file; it is needed on every decision.
- Decided: the brief fragment is capped at 1500 bytes by a new lint code `E_DECISION_BRIEF` in `--lint-roles`, covering missing file, oversize, or missing the `D<N>` marker. `lint_decision_brief(path=CORE_DIR / "DECISION_BRIEF.md")` takes the path as a parameter so tests can pass a temp file.
- Decided: the brief has no completeness score and no ELI10 block; Summary and Stakes replace them.
- Decided: reply format is `D<N>: <letter>`.
- Decided: the two-reviewer gate is a section in `tech-lead/SKILL.md`, not a new `skills/` entry: it travels with the role in lean deploys and adds no asset type.
- Decided: gate scope is `tech-lead` only; other orchestrators route release work to it.
- Decided: maximum 3 review rounds, then human escalation.
- Decided: security-reviewer PASS is "no open Critical or High finding"; Medium and Low are reported but do not block. The gate does not re-rate.
- Decided: both reviewers always run; docs-only and draft work is exempt from the gate entirely.
- Decided: `--changed` takes any range `git diff` accepts; no default range.
- Decided: touch-rule matching is first-match-wins per file with `fnmatch.fnmatchcase`, so a narrow rule can precede a broad one.
- Decided: the shipped touch map has no `_core/*` or `models.yaml` entry: neither reaches the lean prompt evals render. It does list `agent-factory/examples/*` (roster and stacks) and `agent-factory/stacks/*`. A silently skipped eval after a prompt-affecting change is the dangerous error; an over-broad selection only hits the cap.
- Decided: first-match-wins is tested with a temp `touchfiles.yaml` (narrow rule before a broad one) because the shipped map has no overlap.
- Decided: the cap compares the plan's worst case, and runs before the `--dry-run` return.
- Decided: `tests/test_eval_selection.bats` sets a tripwire `GRID_CLAUDE` (exits 99 and leaves a marker) and unsets `GRID_EVALS` in `setup`, so no test can reach a real model or flip on an ambient `GRID_EVALS=1`; only the one stub-run test points `GRID_CLAUDE` at a stub. Its temp git repo sets identity and `commit.gpgsign=false` per command (a CI runner has no git identity; a developer's global signing config must not apply).
- Decided: `evals/touchfiles.yaml` is tracked data the gate validates (`--validate`); errors print as `E_CASE: touchfiles.yaml: ...` so the gate's existing call covers them.
- Decided: `--max-total` default is 5.00 USD and applies only with `--changed`. A broad change selects every role and refuses until a human raises the cap; that is the intended brake.
- Decided: nothing selected is a clean exit 0 that prints `no eval-relevant changes` and does not require `GRID_EVALS=1`.
- Decided: new eval cases use `finding: "#0"` and `expect_today: unknown`, and are validated, never run, by the implementer.
- Decided: contexts use `--append-system-prompt-file`, never `--system-prompt-file`; replacing the system prompt drops Claude Code's own guidance.
- Decided: `claude-dev`, `claude-research`, `claude-review` are shell aliases, not functions; arguments pass through.
- Decided: no install or hint script; the snippet's header comment and `USAGE.md` show the one line to add. A human adds it.
- Decided: each context file is at most 1200 bytes, asserted in a bats test, because it costs tokens every turn of a session that uses it.
- Decided: alias tests invoke the alias through `eval "claude-dev foo"` inside `bash -c` / `zsh -c`; a bare second command on the same line or in the same `-c` string is parsed before the alias exists and fails with `command not found` (checked in bash 3.2 and zsh).
- Decided: `contexts/` sits at the repo root and is not wired by `wire.sh`; aliases are Claude Code only.

- Decided (integration, Q7): `deploy.py --profile full` renders the nameplate from `agent-factory/user.public.yaml` unless `--identity PATH` is passed; ambient `GRID_USER_CONFIG` is ignored by `deploy.py`; a missing `--identity` file exits non-zero; the lock does not record identity. Owned here as group 7 (depends on group 2, which creates `user.public.yaml`).
  Operator confirmed 2026-10-09 (Q7: default accepted) — full-profile per-project deploys default to the neutral `user.public.yaml` identity unless `--identity` is passed (default YES).
- Decided (integration, QA13): the two-reviewer bats test greps exact, case-sensitive strings inside the Step 6 section with `grep -F`: `qa-engineer`, `security-reviewer`, `Both must pass.`, `does not see`, `Maximum 3 rounds`; task 4.1 must write them verbatim.
- Decided (integration, G3): this change adds no new `gate.sh` check. Its additions run inside existing checks: `E_DECISION_BRIEF` inside `compose --lint-roles` (already skipped loudly without the venv), touchfile validation inside `run_evals.py --validate` (reached via `tests/test_eval_cases.bats`), goldens via bats files that skip without the venv, and the shellcheck glob extension inside the existing `shellcheck` check. No `tests/test_gate.bats` case is needed.
- Decided (integration, G5): Claude stubs use the existing `GRID_CLAUDE` variable; tests write one-line inline stubs in the test file (as `tests/test_eval_cases.bats` does) and create no shared stub helper. No `GRID_HOST` sentinel is used here. G1, G2, G4, G6, G7, G8 do not apply: this change adds no home-derived target, scheduler, manifest entry type or wire step.
- Decided (integration): the compose-conformance spec's leak scenario matches the design: no hostname grep; `your-machine` must appear in each target tree instead.

## Risks

- Appending to orchestrator output changes composed output on every machine; the gate's `compose.py --check` fails until a machine recomposes. Recomposing is a human step (task group 6); loop worktrees have no `projects/`, so the gate skips it there.
- Fixture roles that share real names could confuse a reader; the `fixture.yaml` comment says they are fixtures.
- The goldens are pinned to the PyYAML version in `agent-factory/requirements.txt` (`yaml.safe_dump` formatting); bumping it can require `--update`.
- Until `foundations#2` merges, the golden tests are skipped in CI; this change is ordered after it (D9).
