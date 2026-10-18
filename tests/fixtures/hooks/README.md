# Hook fixtures and Claude Code CLI facts

Captured for the `hook-profiles` change (group 0, issue #99). Groups 1 and 3 read
these files and the findings below.

- **Claude Code version:** 2.1.296
- **Captured:** 2026-10-11, Linux, `--model haiku` (resolved to `claude-haiku-5-5`)
- **Cost:** 13 headless haiku calls, about 0.07 USD in total (each capped at 0.25 or less)

## Files

| File | What it is |
|------|------------|
| `pretooluse-bash.json` | Real `PreToolUse` (matcher `Bash`) hook stdin payload |
| `sessionend.json` | Real `SessionEnd` hook stdin payload |
| `shapes/<kind>.json` | ONE real transcript line per kind (see below) |

Sanitising: every key is kept exactly as captured. Values are neutral constants
(`session_id`, `uuid`, `promptId` and similar `00000000-0000-4000-8000-000000000000`;
`transcript_path` `/tmp/transcript.jsonl`; `cwd` `/tmp/project`; timestamps
`2000-01-01T00:00:00.000Z`; tool ids `toolu_000...`; Bash `command` `git status`).
In `shapes/`, every free-text value is `__TEXT__`. Structural enums (`type`, `role`,
`name`, `promptSource`, `turnOrigin`, `isMeta`, `isSidechain`, `input.skill` and so
on) are kept verbatim. The `-handoff.md` / `-context.md` suffix on a Write
`file_path` is kept (`/tmp/project/LOGS/2000-01-01-host-slug-handoff.md`); the
`<command-name>/handoff</command-name>` tag in `slash-handoff` is kept.
`wireToolInputs` keys are tool-use ids, so they are the neutral tool id too.

## How each file was captured

All runs used a scratch directory and a scratch git repo outside this repo, with hooks
passed by `--settings <scratch file>` (no real settings file touched). Every shape
line comes from the transcript written by those scratch sessions, not from any real
session.

- `pretooluse-bash.json`, `sessionend.json` (0.1): `claude -p "run the shell command: git status" --model haiku --allowedTools "Bash(git status:*)" --settings <scratch> --max-budget-usd 0.10`. Both hooks were `cat > <file>`. **`SessionEnd` fires under `-p`** (no interactive repeat needed). Its payload has no `tool_*` fields and no `permission_mode`; it carries `reason` (`other` here).
- `human-string`, `tool-result`, `assistant-text`, `assistant-bash-tool`, `attachment` (the `date` attachment): the 0.1 run transcript.
- `slash-handoff`, `meta-user`, `assistant-write-handoff`: the 0.4 `/handoff scratch test` run transcript.
- `assistant-skill-tool`: a separate scratch run, `claude -p "Call the Skill tool with skill 'handoff' ..." --tools Skill`. The 0.4 slash run does NOT produce a `Skill` tool_use (see 0.4 below).
- `sidechain-user`: scratch run that used the `Agent` tool (`subagent_type Explore`); the line is the first line of `<session>/subagents/agent-*.jsonl`.
- `human-blocks`: scratch run fed `--input-format stream-json` with `content: [{type: text, ...}]`.

## Hand-built shapes

None. All 11 kinds were captured from real scratch transcripts.

Caveats on what the captures can and cannot show:

- Every human line here comes from headless (`-p`) runs, so `promptSource` / `turnOrigin` are `"sdk"` on `human-string`. An interactive human line may carry other values or none; not captured. A human-turn counter should not key on those two fields.
- `human-blocks` was produced via stream-json input, not by typing in the TUI. The block shape (`content: [{type: "text", ...}]`) is real, but interactive pastes/images may add other block types.
- `human-blocks` has `"isMeta"` absent; `meta-user` has `"isMeta": true` and a `content` block array too. The two are told apart by `isMeta`, not by content type.

## 0.4 Headless feasibility (`/handoff` under `-p`)

Command: `claude -p "/handoff scratch test" --model haiku --max-budget-usd 0.25 --permission-mode acceptEdits --tools "Read,Write,Bash" --allowedTools "Read" "Write(<repo>/LOGS/**)" "Write(<fallback>/**)" "Bash(hostname:*)" "Bash(realpath:*)" "Bash(readlink:*)" "Bash(ls:*)" "Bash(date:*)" --disallowedTools "Edit" "Bash(git:*)"` (plus `--output-format json` to read `permission_denials`).

1. **Skill runs headless with the design's tool set: YES.** Exit 0, 9 turns, 0.014 USD. Both `<date>-<host>-scratch-test-handoff.md` and `-context.md` were written to `LOGS/`.
2. **Tool permission denied: YES, two.**
   - One compound Bash call (`hostname -s; date +%F; cd <repo> && pwd && git status --short && ... ; ls ...`) was denied. The `Bash(<cmd>:*)` patterns match a single command; a `;`/`&&` chain containing `git` is not covered. The skill then could not read the hostname, the commit/push steps did not run, and it left the files uncommitted.
   - One call to an MCP tool (`mcp__claude_ai_Claude_Docs__batch`, empty input) was denied. See extra tool below.
3. **Extra tool outside `Read,Write,Bash` needed: NONE.** The only other tool the model reached for was an MCP connector tool, by mistake, and the run succeeded without it. Note `--tools` restricts built-ins only; MCP tools stay visible to the child unless the machine has none configured, and are denied under `-p` by the default permission rules.
4. **`--allowedTools` / `--disallowedTools` patterns accepted: YES.** The variadic multi-pattern form above was accepted, exit 0.
5. **`--max-turns 3` accepted: YES.** `claude -p "reply ok" --model haiku --max-turns 3 --max-budget-usd 0.05` exited 0 and ran a model call (0.006 USD). It is not listed in `claude --help` (2.1.296). That it is accepted was observed; that the limit is honoured when reached was not tested.
6. **Slash handoff leaves no `Skill` tool_use.** With `-p "/handoff ..."` the CLI expands the command itself: the first user line is a string `<command-message>handoff</command-message>\n<command-name>/handoff</command-name>\n<command-args>...</command-args>` (`slash-handoff`), followed by an `isMeta` user line holding the skill body (`meta-user`). The `Skill` tool_use appears only when the model invokes the skill itself (`assistant-skill-tool`). The "handoff already ran" check must therefore match the command tags OR the Skill tool_use, as the design says.

## 0.6 Path-scoped Write enforcement

Prompt: `write the word x to <repo>/outside.txt, then to <repo>/LOGS/inside.txt` with the 0.4 flags.

**Enforced under the design's flags (`--permission-mode acceptEdits`, `Write(...)` rules): NO, in either rule form.**

| Run | Rule form | Mode | `outside.txt` | `LOGS/inside.txt` | Denials |
|-----|-----------|------|---------------|-------------------|---------|
| 0.6 as specified | `Write(<abs>/LOGS/**)` | acceptEdits | written | written | none |
| 0.6 retry | `Write(//<abs>/LOGS/**)` | acceptEdits | written | written | none |

Both files were written because `acceptEdits` auto-accepts writes under the working directory; the allow rules were never consulted.

Extra diagnostic runs (beyond the issue; about 0.002 USD each) to find what does work. Same flags with `--permission-mode acceptEdits` removed (default mode):

| Rule form | `--disallowedTools` | `outside.txt` | `LOGS/inside.txt` | Result |
|-----------|---------------------|---------------|-------------------|--------|
| `Write(<abs>/LOGS/**)` | `Edit`, `Bash(git:*)` | denied | denied | Rule does not match even the in-scope path |
| `Write(//<abs>/LOGS/**)` | `Edit`, `Bash(git:*)` | denied | denied | Rule does not match even the in-scope path |
| `Write(//<abs>/LOGS/**)` | `Bash(git:*)` | denied | denied | Same without `Edit` disallowed |
| `Edit(//<abs>/LOGS/**)` | `Bash(git:*)` | denied | **written** | Enforced |
| `Edit(//<abs>/LOGS/**)` | `Edit`, `Bash(git:*)` | denied | **written** | Enforced (the design's disallow list) |

Reading: path-scoped write permission works through an **`Edit(//<absolute path>/**)`** allow rule (it covers the `Write` tool) in default permission mode, not through `Write(...)` rules and not under `acceptEdits`. The `//` prefix is the absolute-path form; the single-slash form was not tested with `Edit`. Not tested: `Edit(//...)` rules combined with `acceptEdits` (expected to be bypassed for paths under the cwd, as above).

So the stop rule in tasks.md (path-scoped Write not enforced headless in either form) is triggered by the literal 0.6 run; the diagnostic table shows a working alternative. Group 3 needs to decide whether to adopt it.

## Re-capture

Re-capture these files after a Claude Code upgrade when the payload-conformance test
fails. Method: repeat the commands above in a scratch repo, then re-sanitise with the
same constants.
