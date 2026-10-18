## Context

Checked in this worktree (branch `spec/epistemics-and-loop`, cut from `next`):

- Existing signal pattern: `agent-factory/_core/AGENTS_base.md` "Signal Protocol" says append `[YYYY-MM-DD] [open] ...` to `signals/→<agent>.md`, mark `[resolved]`. `agent-factory/README.md:411` calls it "as the live system does". No script, role or doc in this repo reads `signals/`; nothing here sweeps signals into issues. **UNVERIFIED:** the operator's server (an OpenClaw install) may run such a sweep; its cron prompt and workspace are not visible. The shared brief says it exists; this change treats it as the pattern to copy, not as code to extend.
- `gh-triage` (`agent-factory/roles/gh-triage/`): unattended core role, `tools: [Read, Grep, Glob, Bash, Write]`, runs on cron with `-p <deployment-scope file>`; triages issues by label; `AGENTS.md` is 3847 bytes, hard rules include SAFE TARGET FIRST (first run on a repo writes nothing), one `scripts/run-record.sh` line per run, "never fix, merge or close", SINGLE OUTWARD CHANNEL = labels and comments. `gh-triage` is not in `agent-factory/authored-roles.txt`, so the 4 KB lint does not bind it; keep `AGENTS.md` under 4096 bytes anyway and put procedure in `SKILL.md`.
- The cron that runs it on the operator's server is an OpenClaw cron job every 30 minutes, per `main:automation-factory/docs/gh-triage-to-issue-loop.md` (deleted on `next`, restored by `issue-loop-v2`). Not verified live. Its cron schedule is a property of the machine, not the role (SKILL.md Step 0).
- Labels in use (`gh-triage-spec.md`, SKILL.md Step 3): category `bug|enhancement`; state `needs-triage|needs-info|ready-for-agent|ready-for-human|wontfix`; `severity:critical|high|medium|low`; critical/high always `ready-for-human`. No `knowledge` label exists. The issue pass skips any issue carrying a state label, so knowledge issues (born `ready-for-human`) are never re-classified.
- Secret scan: `hooks/scripts/pre-bash-secret-scan.sh` (PreToolUse, matcher Bash, catalogue `min_profile: standard`, fail closed). It scans every added line of the staged diff with no path filter, so `signals/*.md` is covered when committed through a Claude Code Bash call. It is a mistake-catcher. It does not run in a project whose `.grid/project.yaml` leaves `hooks.profile` at its default `off` (template comment, verified). It has a line-level allow pragma, deliberately undocumented. `hooks/lib/secret-patterns.sh` offers `SECRET_STRICT=1` (no exemptions, no pragma), used today by the auto-handoff worker.
- `scripts/run-record.sh --role --action --outcome ok|error|stopped|skipped [--target] [--note]` appends to `~/.the-grid-private/runs.jsonl`.
- `scripts/instincts/lib.py:sanitize` strips control chars, hidden unicode and backticks; this change needs the same hygiene for claims but keeps backticks.
- No `CODEOWNERS` is tracked (`git ls-files`). Branch protection on any repo: UNVERIFIED (A3 adds the verification task).
- Stdlib-first, bash or python3, idempotent, `LC_ALL=C` for committed output (`openspec/config.yaml`). macOS system python is 3.8; keep syntax compatible.

## Approach

```
agent / human                          sweep (gh-triage, cron, one writer)
  knowledge.py file  -> signals/<ts>-<filer>-<h6>.md   (commit, push)
                                          |
                    git pull --ff-only in the sweep checkout
                    knowledge.py plan  (read-only JSON: mechanical dispositions
                                        + which judgement checks are needed)
                    model judges only: guardrail conflict, canon contradiction
                    knowledge.py apply -> knowledge/<stage>/K-*.md
                                          signals/done/<file>  (git mv, unedited)
                                          signals/done/ledger.jsonl (append)
                    escalations: gh issue (knowledge, ready-for-human) + PR branch
                    one commit, one push, one run-record line
```

### Signal (immutable)

Filename `YYYYMMDDTHHMMSSZ-<filer>-<hash6>.md`. `<filer>` = slug of `filed_by` (`[a-z0-9-]{1,32}`). `<hash6>` = six lowercase hex characters; the helper uses the first 6 of the SHA-256 of the file's bytes, so identical content filed twice in the same second by one filer is the same file (no merge conflict). A hand-written file may use any six hex characters (a filer with no shell, e.g. Cowork, cannot hash). Immutability is checked from git, not from the hash: a pending signal touched by any commit after the one that added it (`git log --diff-filter=M -- <file>` non-empty) is `invalid`. Frontmatter is flat `key: value`, one line per key, no nesting (parseable with stdlib). Fields:

| key | required | rule |
|---|---|---|
| `filed_by` | yes | `[A-Za-z0-9._-]{1,48}`: role name or `human-<name>`; self-asserted |
| `claim` | yes | one line, 1-200 chars, no control or hidden-unicode characters |
| `stage` | yes | claimed: `wip`, `provisional`, `established` or `canonical` |
| `warrant` | yes | one line, 1-300 chars; `none` allowed (counts as no warrant) |
| `supersedes` / `contradicts` / `confirms` | no | one entry address (`K-<hash8>`) |
| `guardrail` | no | `GUARDRAILS#G<n>` |
| `status` | yes | literally `pending` |

Body: optional free markdown, at most 4096 bytes. It is never copied into `knowledge/` (smaller injection surface for text agents read at session start).

"Warranted" = `warrant` is non-empty and, case-insensitively, not one of `none`, `n/a`, `na`, `untested`, `unknown`, `tbd`, `?`. The sweep checks presence, not quality. Quality is covered by the different-filer rule (established) and a human (canon).

### Claim hash

`claim_hash = sha256(NFKC(claim).casefold() with runs of whitespace collapsed to one space, trimmed)`, first 16 hex. Entry id = `K-` + first 8 hex. Wording changes make a new hash: rejection memory is by exact normalised claim, not by meaning (see Risks).

### Stage ceiling (deterministic)

An entry's evidence is a list of (signal, filer, claimed stage, warrant). `W` = number of distinct `filed_by` values with a warranted entry. Ceiling: `W=0` wip; `W=1` provisional; `W>=2` established. Entry stage = min(highest claimed stage among its evidence, ceiling), and never lowers automatically. `canonical` and `superseded` are never set on the sweep branch by the sweep. A confirmer must have a warrant that is not (case-insensitively) identical to a warrant already in the evidence, so copy-paste cannot confirm.

### Plan order for each pending signal (oldest first, up to the cap)

1. File name does not match the signal pattern (README, `→*.md`, anything else): ignored, not counted. A misnamed file is therefore never swept; `knowledge.py check` flags a `signals/*.md` file with a `claim:` key whose name does not match.
2. Parse or enum failure, hidden characters, `status` not `pending`, modified after being added, body over 4096 bytes, `stage: superseded|retired`: `invalid`.
3. Strict secret scan (`SECRET_STRICT=1` over file text) hits: `secret` (issue, no PR, no entry).
4. Claim hash has an `escalated` ledger line with no `resolution` yet: `duplicate` (points at that issue). Claim hash has a `rejected` ledger line with no later `reopen`: `repeat-rejected`.
5. Escalate (human) if any of: claimed `canonical`; `supersedes` set; `contradicts` set; the matched entry lives in `canon/`, `superseded/` or `retired/`; collision of an 8-hex id with a different full hash; model verdict `conflict` or `unsure` on a cited guardrail; model verdict `contradicts` or `unsure` against a canon one-liner.
6. Matching entry (same hash, or `confirms`) in wip/provisional/established: the signal adds evidence only if it is warranted, its `filed_by` has no warranted evidence line yet and its warrant is not identical (case-insensitive) to an existing one; otherwise `duplicate` (nothing added). If it adds evidence, recompute the stage: `confirmed`.
7. No matching entry: write new entry at its ceiling: `wip` if no warrant (marked unwarranted), else `written`.

Model judgement happens only in step 5, for signals that survive steps 1-4: (a) if the signal cites a guardrail, does the claim conflict with that guardrail's text (answers `no|conflict|unsure`); (b) if canon is non-empty, does the claim contradict any canon one-liner (the same ones `MAP.md` carries, at most 20) (answers `none|<entry id>|unsure`). `unsure` always escalates. Undeclared contradictions with non-canon entries are not checked (Non-goal).

### Ledger

`signals/done/ledger.jsonl`, append-only, one JSON object per line, written only by `knowledge.py apply`:

```
{"event":"disposition","signal":"<filename>","claim_hash":"<16hex>","disposition":"wip|written|confirmed|escalated|invalid|duplicate|repeat-rejected|secret","entry":"K-xxxxxxxx|null","issue":null|N,"pr":null|N,"run":"<ISO ts>"}
{"event":"resolution","claim_hash":"<16hex>","pr":N,"result":"accepted|rejected","run":"<ISO ts>"}
{"event":"reopen","claim_hash":"<16hex>","by":"<human>","run":"<ISO ts>"}
```

A signal is processed iff its filename is in a `disposition` line or it already sits in `signals/done/`. A human closes the loop by merging the PR (accepted) or closing it unmerged / closing the issue `wontfix` (rejected). Each run first reconciles `escalated` lines that have no `resolution` yet by reading `gh pr view` state (counted against the cap) and appends the `resolution`. `repeat-rejected` consults only `rejected` resolutions not followed by a `reopen`. A human adds a `reopen` line by hand (a normal commit) to allow a claim to be raised again.

### Escalation mechanics

For each escalation (max 3 per run): (1) search for an existing issue by the marker `<!-- knowledge-signal: <claim_hash> -->` including closed ones (idempotency); (2) create the issue (labels `knowledge`, `ready-for-human`, `severity:low`, or `severity:medium` for contradiction, guardrail conflict and `secret`; no category label; body = claim, warrant, filer, stage claimed, why escalated, signal path, marker); (3) for all but `secret`, create a branch `knowledge/<K-id>` from the sweep branch in a temp `git worktree`, run `knowledge.py apply --proposal-for <signal> --root <worktree>` (writes only the proposed `knowledge/` change), push, `gh pr create` with `Refs #<issue>`; (4) ledger line with issue and PR numbers goes in the main sweep commit. The sweep never runs `gh pr merge`, never enables auto-merge, never closes an issue or PR. Proposed change by case: canon proposal creates/moves the entry into `knowledge/canon/`; supersession writes the new entry and moves the old one to `superseded/` with the cross links; contradiction adds the new entry with `contradicts`; guardrail conflict adds the entry only (the sweep never edits `PURPOSE.md`, `GUARDRAILS.md`, `BEHAVIOUR.md`, `MAP.md`).

### Single writer, idempotency, failure

Only the sweep writes `knowledge/`, `signals/done/` and the ledger. It holds an advisory `fcntl.flock` on `<checkout>/.git/knowledge-sweep.lock` for the run (released by the OS if the process dies, so no stale lock). It refuses a dirty checkout. One commit and one push per run; if the push is rejected it runs `git pull --rebase` once (conflicts cannot arise from signals, which only add files) and retries once; on a second failure it resets to `origin/<branch>`, writes nothing, and records outcome `error`. A rerun with nothing pending makes no commit, no `gh` write and no model call.

### Hygiene of what reaches always-in-context text

Entries copy only `claim` and `warrant` (single-line, sanitised: control and hidden-unicode characters make the signal `invalid`, not silently cleaned). `MAP.md` (A3) prints canon claims in context, which is why canon entries need a human.

## Decisions

- Decided: helper script `scripts/knowledge.py`, python3 stdlib, 3.8-compatible, subcommands `hash`, `file`, `check`, `plan`, `apply`. Not named `promote`; nothing in it decides to raise a stage beyond the deterministic ceiling, and canon is never written by it on the sweep branch.
- Decided: A3 imports the parser/validator from `scripts/knowledge.py` (single definition of the signal and entry grammar). A3's own content-hash check is dropped (operator D2): `<hash6>` is any six hex characters and immutability comes from git history.
- Decided: ledger, not edits to signals (signals stay immutable; the brief's `status: pending` is therefore frozen, and "processed" = location in `signals/done/` plus a ledger line).
- Decided: unwarranted signals are written as `wip` entries, flagged `unwarranted: yes`, because the brief says the default stage with no warrant is `wip`; they never count toward `W`.
- Decided: `confirms` field added.
- Decided (operator D7): an agent may claim any stage as a proposal; the sweep caps the outcome by evidence; `canonical`, supersession and retirement are always human.
- Decided (operator D9): knowledge signals and `signals/→<agent>.md` hand-offs coexist in `signals/`.
- Decided (operator D1): `MAP.md` carries no volatile counts (A1 adds `map.py status`). The sweep never regenerates `MAP.md`. Only the one-time change adding the `## Knowledge sweep` heading to `gh-triage/AGENTS.md` regenerates it, in the same commit, so the gate's `map.py --check` stays green.
- Decided (operator D10): `scripts/knowledge.py` is accepted as a helper; it has no `promote` command.
- Decided: addresses. Entries move between stage directories, so a path address breaks on promotion (by design it "fails loudly", but every promotion would then break every citation). Canonical citation is `K-<hash8>[#<heading-slug>]`, resolved by filename glob `knowledge/*/K-<hash8>-*.md`. The path form `knowledge/<dir>/K-...md#slug` remains valid while the file is there. Headings are fixed (`## Claim`, `## Evidence`), so slugs are `claim` and `evidence`.
- Decided: `signals/done/` is flat. Revisit at 500 files.
- Decided: the `gh-triage` `AGENTS.md` gets a `## Knowledge sweep` heading, because A1's `map.py` prints the sweep as configured only when that exact heading exists. `AGENTS.md` is 3847 bytes today; the section plus the reworded outward-channel rule must keep it under 4096 or the detail moves to `SKILL.md`.
- Decided: caps 10 signals and 3 escalations per run per repo, overridable per repo in the scope file (`Cap`); over-cap signals stay pending and are picked up next run (oldest first).
- Decided: first run on a repo with no earlier `knowledge-sweep` run-record line for it runs `plan` only, writes nothing, records `skipped` with the plan counts (inherits SAFE TARGET FIRST).
- Decided: scope file gains a `## Knowledge sweep` table: `Repo | Checkout path | Sweep branch | Cap`. A repo not in the table is not swept; `enabled: false` default.
- Decided: hash8 collision with a different full hash escalates (human); not engineered further.
- Decided: seed `.gitkeep` in each stage directory so the layout exists from the first clone.
- Decided (operator D3): `scripts/knowledge.py` is canonical in the-grid and mirrored byte-identically to `project-factory/templates/_common/scripts/knowledge.py`, so a project repo can file and check signals without the-grid installed. A bats `cmp` test covers `knowledge.py` (A1's covers `map.py`). Every subcommand takes `--root` (default: git root of cwd). A1's "Filing a Knowledge Signal" block in `AGENTS_base.md` is owned and worded by A1 (operator D7), including this change's fields; this change does not edit `AGENTS_base.md`. A3 imports the parser from `scripts/knowledge.py` and does not mirror it.

## Alternatives rejected

- Edit the signal's `status` on sweep: breaks immutability and makes laptop/server edits conflict.
- Disposition in a per-signal sidecar file: doubles the file count; one append-only ledger is greppable and has one writer.
- Flat `knowledge/` with stage only in frontmatter: simpler addresses, but the brief and the reader both want layout by stage (a directory listing shows what is canonical).
- A confirmer agent or weekly promoter job: ruled out by the operator.
- Sweep opens a PR for every automatic write: more human load for low-stakes wip/provisional entries; the stage ceiling plus the different-filer rule is the control there.
- Model does all mechanics from prose: hash drift, double processing and lost rejection memory under an unattended cron; rejected.
- Retire via signal: needs a seventh field and a new escalation type for something rare; a human PR does it.
- Embedding or fuzzy match for rejection memory: a new dependency for an edge case.

## Risks

- Self-asserted `filed_by`: one agent can file under two names and fake confirmation. The rule defeats accidental self-confirmation only. Mitigation: the evidence list records signal filenames, the git author of the adding commit is visible in history, and `established` is still not canon. Correlated error (two agents, same model, same mistake) is not caught; only a human gate (canon) addresses it.
- Reworded claims evade rejection memory. Accepted; the issue body for an escalation lists any rejected claim whose normalised text shares 80% of its words (cheap token overlap in `plan`, informational only).
- A secret committed in a signal is in git history even after the sweep rejects it. The sweep cannot rewrite history; the `secret` issue asks a human to rotate and scrub. Prevention is the commit-time scan, which is opt-in (`hooks.profile`) and only covers Claude Code Bash commits.
- Direct sweep commits to a protected branch fail. Handled as an `error` outcome, not retried forever; assumption 7 and open question 3.
- Prompt injection via signal text: the model judgement sees claims and canon lines as quoted data; free-text bodies are never shown to it or copied; `unsure` escalates; a human still gates anything that reaches canon.
- Sweep lag: signals filed on a feature branch are invisible until merged to the sweep branch.
- Two clones of the sweep (misconfiguration) race: the flock protects one checkout only; the git push ordering plus the "already in done/" check makes the second a no-op, not corruption.
- Token cost: bounded by the cap and by zero judgement calls when nothing is pending or when no signal reaches step 5.
