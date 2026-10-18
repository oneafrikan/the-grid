## Purpose

Optionally ask an agent, once per turn, for the evidence behind a completion claim, without a model call and without ever trapping a session.

## ADDED Requirements

### Requirement: Catalogue entry
`hooks/catalogue.json` SHALL carry an entry `epistemic-stop`: scope `project`, event `Stop`, no matcher, `min_profile: strict`, `fail: open`, timeout 5, `model_cost: false`, a non-empty `cost` that names the extra model turn a block causes, and a description. `hooks/scripts/epistemic-stop.sh` SHALL exist and pass shellcheck at warning level.

#### Scenario: Catalogue and script agree
- **WHEN** the catalogue/script agreement test runs
- **THEN** it passes with `epistemic-stop` present

#### Scenario: Profile gating
- **WHEN** `deploy_hooks.py` emits for profiles `standard` and `strict`
- **THEN** the `strict` output contains a `Stop` handler for `epistemic-stop` and the `standard` output does not

#### Scenario: Default off
- **WHEN** a project has no `hooks:` key or `profile: off`
- **THEN** no `Stop` handler is emitted

### Requirement: Ask once for a warrant
When the last assistant message matches the completion-claim pattern and contains none of the whole words `RAN`, `READ`, `UNTESTED`, the hook SHALL exit 2 with a one-line stderr reason asking for RAN, READ or UNTESTED per claim. When `stop_hook_active` is true it SHALL exit 0 without inspecting the message.

#### Scenario: Claim without warrant
- **WHEN** the last message is "Fixed the bug and all tests pass."
- **THEN** the hook exits 2 and stderr contains `RAN, READ or UNTESTED`

#### Scenario: Claim with warrant
- **WHEN** the last message is "Fixed. RAN: bash scripts/gate.sh, exit 0."
- **THEN** the hook exits 0 with no output

#### Scenario: No claim
- **WHEN** the last message is a question to the user
- **THEN** the hook exits 0 with no output

#### Scenario: Second stop in the same turn
- **WHEN** the payload has `stop_hook_active: true` and the message still has no warrant
- **THEN** the hook exits 0

#### Scenario: Lowercase marker does not count
- **WHEN** the message says "done, I ran it" with no uppercase marker
- **THEN** the hook exits 2

### Requirement: Fails open, bounded, no side effects
The hook SHALL exit 0 when `jq` is missing, the payload or transcript is unreadable or unparsable, or the transcript exceeds the read cap; read at most 64 KiB of the transcript tail; make no network or model call; and write nothing to disk. It SHALL honour `GRID_HOOKS=off` and `GRID_DISABLED_HOOKS=epistemic-stop` through `run.sh`.

#### Scenario: No jq
- **WHEN** the hook runs with `jq` hidden from PATH
- **THEN** it exits 0

#### Scenario: Garbage payload
- **WHEN** stdin is not JSON
- **THEN** it exits 0 and prints nothing

#### Scenario: Kill switch
- **WHEN** `GRID_DISABLED_HOOKS=epistemic-stop` is set
- **THEN** `hooks/run.sh epistemic-stop` exits 0 before the script runs

### Requirement: Documented cost and limits
`hooks/README.md` SHALL list the hook in the hooks table and the profile table (strict row no longer "nothing yet"), state that it is advisory, can be bypassed, and that a block costs one extra model turn.

#### Scenario: Docs agree with catalogue
- **WHEN** the README profile table is read
- **THEN** `strict` lists `epistemic-stop` and every other row is unchanged
