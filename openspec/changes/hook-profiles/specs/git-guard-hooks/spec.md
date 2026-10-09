## Purpose

Two zero-token PreToolUse guards on Bash that stop an agent from bypassing git's safety nets or committing a secret.

## ADDED Requirements

### Requirement: Block hook bypass and force-push
The `pre-bash-no-bypass` hook SHALL exit 2 with an explanation on stderr when a Bash command runs `git` with `--no-verify`, `git commit` with `-n`, a `core.hooksPath` override (by `-c`, by a `git config` write, or by a `GIT_CONFIG_COUNT`/`GIT_CONFIG_PARAMETERS`/`GIT_CONFIG_KEY_*` assignment), a `git config` alias whose value contains `--no-verify` or `-n`, a `HUSKY=0` assignment, or a force-style `git push`, including when the git call is wrapped one level deep in `bash|sh|zsh -c`, `eval`, `exec`, `env`, `command`, `xargs`, `nice`, `time` or `sudo` or spelled `\git` or `/path/to/git`, and exit 2 when `jq` is unavailable.

#### Scenario: No-verify commit blocked
- **WHEN** the command is `git commit -m "x" --no-verify`
- **THEN** the hook exits 2 and the message names `GRID_DISABLED_HOOKS=pre-bash-no-bypass` as the human bypass

#### Scenario: Short no-verify blocked
- **WHEN** the command is `git commit -nm "x"`
- **THEN** the hook exits 2

#### Scenario: Force push blocked
- **WHEN** the command is `git push --force origin next`, `git push -f`, `git push -fu origin next` or `git push origin +next`
- **THEN** the hook exits 2

#### Scenario: Lease push allowed
- **WHEN** the command is `git push --force-with-lease origin next`
- **THEN** the hook exits 0

#### Scenario: Push dry-run flag is not force
- **WHEN** the command is `git push -n origin next`
- **THEN** the hook exits 0

#### Scenario: Quoted mention does not block
- **WHEN** the command is `git commit -m "docs: explain why --no-verify is banned"`
- **THEN** the hook exits 0

#### Scenario: Chained command is inspected
- **WHEN** the command is `git add . && git commit --no-verify -m x`
- **THEN** the hook exits 2

#### Scenario: One-level wrapper is inspected
- **WHEN** the command is `bash -c 'git commit --no-verify -m x'`, `eval "git commit --no-verify -m x"` or `sudo -u root git push --force`
- **THEN** the hook exits 2

#### Scenario: Normalised git spelling is inspected
- **WHEN** the command is `\git commit --no-verify -m x` or `/usr/bin/git push -f`
- **THEN** the hook exits 2

#### Scenario: Hook-disabling config is blocked
- **WHEN** the command is `git config core.hooksPath /dev/null`, `git config alias.ci "commit --no-verify"`, `HUSKY=0 git commit -m x` or `GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0=/dev/null git commit -m x`
- **THEN** the hook exits 2

#### Scenario: Harmless wrapped and config commands pass
- **WHEN** the command is `bash -c 'git status'`, `git config --get core.hooksPath` or `git config alias.st status`
- **THEN** the hook exits 0

#### Scenario: Every row of the bypass-form table
- **WHEN** each row of the design's "Bypass-form table" is sent as a payload, each in its own test
- **THEN** every `B` row exits 2 and every `P` row exits 0

#### Scenario: Unrelated command passes
- **WHEN** the command is `ls -la` or the tool is not Bash
- **THEN** the hook exits 0

#### Scenario: Real payload shape
- **WHEN** the hook receives the captured `pretooluse-bash.json` fixture with only `.tool_input.command` replaced
- **THEN** it blocks `git commit --no-verify -m x` and passes `git status`, so a renamed payload key fails this test

#### Scenario: Every row of the block table is blocked
- **WHEN** each command in the design's "Command block table" is sent as a payload
- **THEN** every one exits 2

#### Scenario: Every row of the pass table is allowed
- **WHEN** each command in the design's "Command pass table" is sent as a payload
- **THEN** every one exits 0

#### Scenario: Malformed input does not block
- **WHEN** stdin is not JSON, or `.tool_input.command` is missing
- **THEN** the hook exits 0

#### Scenario: jq missing fails closed
- **WHEN** `jq` is not on PATH and the hook receives any Bash payload
- **THEN** it exits 2 and the message names `jq`

### Requirement: Block commits that add a secret
The `pre-bash-secret-scan` hook SHALL exit 2 when a `git commit` Bash command would commit an added line matching a secret pattern (from the index, or from the working tree when the commit names pathspecs or uses `-i`, `-o`, `-a` or their long forms) or a sensitive file, and when a `git add` names a sensitive file, without printing the matched secret value and without mentioning the allow pragma, using the pattern table shared with the auto-handoff worker, and exit 2 when `jq` is unavailable.

#### Scenario: Staged AWS key blocked
- **WHEN** a staged added line contains an AWS access key id and the command is `git commit -m x`
- **THEN** the hook exits 2 and stderr names the file, line number and pattern but not the key text

#### Scenario: Each pattern is detected
- **WHEN** a staged added line contains a token for each pattern name in the design's pattern table, one pattern at a time
- **THEN** the hook exits 2 and names that pattern

#### Scenario: Line number is correct after earlier hunks
- **WHEN** a secret is added on line 40 of a staged file that also has an earlier edit in a separate hunk
- **THEN** stderr reports `:40:`

#### Scenario: Commit with -a scans unstaged tracked changes
- **WHEN** a tracked file has an unstaged added secret and the command is `git commit -am x`
- **THEN** the hook exits 2

#### Scenario: Pathspec commit scans the working tree
- **WHEN** `f.txt` is tracked, has an unstaged added secret, nothing is staged, and the command is `git commit -m x f.txt` or `git commit -o -m x f.txt`
- **THEN** the hook exits 2

#### Scenario: Unquoted assignment detected
- **WHEN** a staged added line is `API_KEY=` followed by a 20-character random value
- **THEN** the hook exits 2 naming `assigned-secret`

#### Scenario: Sensitive files blocked
- **WHEN** the command is `git add .env`, `git add server.pem` or `git add id_ed25519`, or a commit's staged files include `.env`
- **THEN** the hook exits 2; `git add .env.example` and `git add id_mapping.py` exit 0

#### Scenario: Block message hides the pragma
- **WHEN** the hook blocks a commit for any secret pattern
- **THEN** stderr does not contain `allow-secret`

#### Scenario: Superset of the audit's secret prefixes
- **WHEN** the test reads the `secret-shape` regex in the real `policy.yaml`
- **THEN** each of `AKIA`, `ghp_`, `github_pat_`, `sk-`, `xox`, `AIza`, `PRIVATE KEY`, `eyJ` appears in it, and a token built with each is flagged by `secret_match_line`

#### Scenario: Clean commit passes
- **WHEN** the staged diff contains no pattern match
- **THEN** the hook exits 0

#### Scenario: Look-alikes and placeholders pass
- **WHEN** staged added lines are each one of the design's secret "must pass" rows
- **THEN** the hook exits 0 for every one

#### Scenario: Pragma allows a known false positive
- **WHEN** the matching added line also contains `grid:allow-secret`
- **THEN** the hook does not block on that line

#### Scenario: Removed secret lines are ignored
- **WHEN** the staged diff only deletes a line that contains a secret pattern
- **THEN** the hook exits 0

#### Scenario: Non-commit commands are skipped fast
- **WHEN** the command is `git status`
- **THEN** the hook exits 0 without running any git diff (a `git` stub on PATH records no `diff` call)

#### Scenario: Outside a repository
- **WHEN** the payload `cwd` is not inside a git repository and the command is `git commit -m x`
- **THEN** the hook exits 0

#### Scenario: jq missing fails closed
- **WHEN** `jq` is not on PATH and the hook receives any Bash payload
- **THEN** it exits 2 and the message names `jq`
