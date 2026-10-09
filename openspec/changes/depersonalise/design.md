## Context

- `git ls-files | grep -v '^repos/'` is 578 files. A read-only sweep (emails, home paths, tokens, private IPs, hostnames, org/account handles, product names of private infrastructure, third-party bundles, large binaries) found residue in about 40 of them.
- Already clean: no live secrets, no private IPs, no real home paths (only `/Users/you/...` placeholders inside the third-party playbook, which moves). `LOGS/`, personal manifests and private roles are already out (earlier audit).
- Intentional and kept: the `~/.the-grid-private` path convention (documented mechanism, no personal values), `oneafrikan/the-grid` URLs, `LICENSE`, and the author voice in prose.
- The OpenClaw emitter is real code (`compose.py` `write_openclaw`, `roster.json`, a bats test reads it). Only its wording and defaults are shaped around one private install, so those files are genericised, not moved.
- Issue #42 wants generic default OpenClaw personas plus a parameterised deploy script; #54 wants persona fields and a voice layer. Both are features. What carries over here is #42's "fork, don't mirror: nothing personal ships" principle and #54's constraint "values stay local".

## Approach

1. Archive first (private repo), delete second (public repo), so nothing is ever only in git history.
2. Build the scan before editing prose, so each edit group can prove itself with `scripts/check-personal.sh <files>`.
3. Wire the scan into the gate last, once the tree is clean, so the gate never goes red mid-series.

### Inventory and bucket per file

| Bucket | Path | Why | Action |
|---|---|---|---|
| move | `__assets/ClawGuides.zip`, `__assets/ClawGuides/**` (22 files) | third-party playbook and skills, licence unclear, 1.1 MB archives | copy to `archive/clawguides/`, `git rm` |
| delete | `docs/playbook-ai-dev-team.md` | byte-identical copy of `__assets/ClawGuides/ai-dev-team-playbook.md` | `git rm` (archive already holds the original) |
| move | `agent-factory/docs/openclaw-paperclip-targets-plan.md` | deployment plan for one private host: paths, ports, channel ids, secret handling notes | `archive/design/` |
| move | `docs/openclaw-portfolio-desk-blueprint.md` | personal desk design naming private hosts and other work | `archive/design/` |
| move | `automation-factory/docs/gh-triage-to-issue-loop.md` | runbook for one private server and work repos | `archive/design/` |
| move | `prompts/2026-06-13-openclaw-lamp-team-prompt.md` | dated one-off session prompt built on the third-party playbook | `archive/prompts/` |
| move | `TODO.md` sections "Pending rollout" and "Status: Done" | per-machine rollout state and history with host names | `LOGS/todo-done-history.md` in private repo; public file keeps focus + issue map |
| genericise | `agent-factory/user.yaml.example` | real name/email as example, host name as example | placeholders |
| genericise | `agent-factory/openclaw/roster.json`, `openclaw/README.md`, `openclaw/templates/orchestrator/{TOOLS,BOOT,HEARTBEAT,USER,AGENTS,IDENTITY,EXPERTISE,MEMORY}.md` | host/hardware line, provenance wording, first-name owner in rendered text | neutral wording; "the operator" in rendered text |
| genericise | `agent-factory/scripts/deploy_openclaw.sh`, `agent-factory/scripts/deploy_paperclip.py` | header/comment provenance naming private hosts and repos | comments only, no behaviour change |
| genericise | `agent-factory/docs/gh-triage-spec.md`, `agent-factory/roles/gh-triage/deployment-scope.template.md` | table of real deployments with account handles | replace with "keep your table in your own infra repo" |
| genericise | `automation-factory/patterns/issue-loop/README.md` | names two private downstream repos | "a downstream repo" |
| genericise | `skills/handoff/SKILL.md`, `handoff-template.md`, `session-template.md` | author SOP wording, host examples, a table of personal folders | see `handoff-locations` |
| genericise | `baseline-submodules.example.txt`, `scripts/lib/find-skill-mds.sh`, `agent-factory/README.md`, `LEARNINGS.md`, `docs/reference-resources.md` (section 13), `agent-factory/docs/role-skill-map.md` (no change expected) | host names in comments/source lines | neutral wording |
| genericise | `README.md` tree lines, `index.html` status bullet | tree lists moved files; the `index.html` "still Gareth-shaped" claim becomes false (README's matching bullet already says forks inherit nothing personal) | one-sentence edits |
| keep | `LICENSE`, author voice in `CLAUDE.md`, `README.md`, `index.html`, `USAGE.md`, `docs/*` prose, `oneafrikan/the-grid` URLs, `~/.the-grid-private` convention | attribution and mechanism, no personal data | none |
| keep (exception) | `the-grid.png` | live hero image, not personal | allowlisted for size; `front-door` replaces it |

Private repo layout after the move (`~/.the-grid-private/`, existing: `LOGS/ roles/ projects/ research/ evals/ backups/`):

```
archive/
  MANIFEST.sha256              # sha256 of every archived file, relative paths
  clawguides/                  # ClawGuides.zip + ClawGuides/ tree
  design/
    openclaw-paperclip-targets-plan.md
    openclaw-portfolio-desk-blueprint.md
    gh-triage-to-issue-loop.md
  prompts/2026-06-13-openclaw-lamp-team-prompt.md
LOGS/todo-done-history.md      # cut sections of TODO.md, verbatim
denylist.txt                   # scan input, see below
handoff-locations.md           # optional, see handoff-locations spec
```

### Scan design: `scripts/check-personal.sh`

- Input set: `git ls-files -z` minus gitlinks (submodules) minus paths matching `scripts/personal-allow-paths.txt`. Text files only (`grep -I`). Reads the working tree, like the rest of the gate.
- Rule files share one tab-separated format, four columns, `#` comments, blank lines ignored:

```
# kind<TAB>scope<TAB>label<TAB>regex
deny	*	email	[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}
allow	*	email-ok	(git@|@example\.(com|org|net)|noreply|https?://[^[:space:]]*@)
deny	*	home-mac	/Users/[A-Za-z0-9._-]+/
allow	*	home-placeholder	/Users/(you|name|username|alice|bob|<)
deny	*	home-linux	/home/[A-Za-z0-9._-]+/
allow	*	home-placeholder-lx	/home/(you|user|name|username|alice|bob|<)
deny	*	token	(ghp_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|\bsk-[A-Za-z0-9_-]{20,}|xox[abp]-[0-9A-Za-z-]{10,}|AKIA[0-9A-Z]{16}|BEGIN [A-Z ]*PRIVATE KEY)
allow	*	token-example	EXAMPLE
deny	*	private-ip	\b(10\.[0-9]+\.[0-9]+\.[0-9]+|192\.168\.[0-9]+\.[0-9]+|172\.(1[6-9]|2[0-9]|3[01])\.[0-9]+\.[0-9]+)\b
deny	agent-factory/openclaw/templates/*	author-name-in-rendered-text	Gareth
deny	agent-factory/_core/*	author-name-in-rendered-text	Gareth
deny	agent-factory/roles/*	author-name-in-rendered-text	Gareth
deny	project-factory/templates/*	author-name-in-rendered-text	Gareth
deny	skills/*	author-name-in-rendered-text	Gareth
```

  - `kind`: `deny` (case-sensitive ERE), `deny-i` (case-insensitive ERE), `allow` (ERE; a `deny` hit on a line is suppressed when the same line matches any `allow` whose scope matches the path).
  - `scope`: `*` or a path glob matched with bash `case` against the repo-relative path.
- Two sources, merged: public `scripts/personal-patterns.txt` (always) and private `${GRID_PRIVATE_DENYLIST-$HOME/.the-grid-private/denylist.txt}` (same format; hostnames, org and account handles, employer names, family names, private project names). Setting `GRID_PRIVATE_DENYLIST=` (empty) disables the private half explicitly.
- Private file absent: print `personal: private denylist not found - generic patterns only`, exit status unaffected, gate records `SKIPPED(personal-denylist)`. This is how CI and a fresh fork run.
- Extra blocks done in code, not in the pattern file: tracked file types `zip pdf tar tgz gz sqlite db pem key`, a tracked `.env` (not `.env.example`), and any file above `GRID_MAX_BYTES` (default 1048576). All honour the path allowlist.
- Output: `path:line: [label] <matched line, max 120 chars>` for public rules; `path:line: [private:<n>]` for denylist rules (rule number only, never the text, so CI logs and shared transcripts do not leak the list). Final line `personal: N finding(s)`. Exit 0 clean, 1 findings, 2 usage.
- Optional positional args restrict the scan to those tracked paths (used by edit groups before the gate wiring lands).
- Allowlist file `scripts/personal-allow-paths.txt`: one bash glob per line, mandatory trailing `# reason`. Initial content: `tests/lib/*` (vendored bats), `scripts/personal-patterns.txt`, `scripts/personal-denylist.example.txt`, `scripts/personal-allow-paths.txt`, `tests/test_check_personal.bats`, `the-grid.png` (size, remove when `front-door` lands).
- Bash 3.2-safe (macOS), `LC_ALL=C`, shellcheck-clean, comments throughout.

### Tests

- `tests/test_check_personal.bats` builds a throwaway git repo in `$BATS_TEST_TMPDIR` (override `GRID_DIR`), writes fixtures, and asserts exit codes and output. Never touches `$HOME`; `GRID_PRIVATE_DENYLIST` is always set explicitly.
- `tests/test_depersonalise.bats` asserts the removed paths are gone, no tracked file references a removed path, `scripts/check-personal.sh` exits 0 on the real repo with `GRID_PRIVATE_DENYLIST=` (generic half), and `user.yaml.example` contains `example.com`. This runs in the existing CI bats step, so no workflow edit.

## Decisions

- Decided: the-grid.png is not moved or recompressed here; it is not personal and is the live hero image, so moving it breaks Pages. `front-door` owns replacing it; allowlist entry removed then.
- Decided: third-party `__assets/ClawGuides*` is archived privately rather than deleted; licence is unclear for redistribution but fine for personal reference, and nothing in code reads it.
- Decided: `docs/playbook-ai-dev-team.md` is deleted outright, not archived twice; the archive already holds the identical original.
- Decided: the three docs moved to `archive/design/` leave no public stub or redirect; a stub would still name the thing being hidden. Inbound mentions are rewritten in the same PR.
- Decided: `agent-factory/openclaw/` code, templates and `roster.json` stay public and are genericised; `compose.py` and a bats test depend on them.
- Decided: wording in `compose.py` comments that points at the moved plan doc is repointed to `agent-factory/openclaw/README.md`.
- Decided: `deploy_openclaw.sh` and `deploy_paperclip.py` get comment edits only; parameterising them is #42 Session 4.
- Decided: `TODO.md` keeps "Current focus" and the issue map; the pending-rollout paragraph and the whole "Status: Done" section move verbatim to the private `LOGS/todo-done-history.md`, with a one-line pointer left behind that does not name hosts.
- Decided: the issue map row for the OpenClaw emitter drops the host name from its title text in `TODO.md` only; the GitHub issue title is untouched (Non-goal).
- Decided: voice rule is "Gareth" allowed in prose docs (`CLAUDE.md`, `README.md`, `index.html`, `USAGE.md`, `docs/`, `TODO.md`); forbidden in text that is rendered into other people's agents or skills (`agent-factory/_core|roles|openclaw/templates`, `project-factory/templates`, `skills/`). Those say "the operator". Enforced by scoped `deny` rules.
- Decided: `oneafrikan/the-grid` URLs stay; the handle is the repo owner and is already in every clone URL and badge.
- Decided: generic patterns live in public, concrete denylist lives only in the private repo; the public file never contains a real hostname, account or employer.
- Decided: denylist findings print rule number only, never matched text, so CI and pasted logs cannot leak the list.
- Decided: absent private denylist is a visible skip, not a failure, so forks and CI work; the generic half always runs.
- Decided: CI enforcement is the repo-wide generic scan inside `tests/test_depersonalise.bats`; no new workflow file or secret.
- Decided: `allow` rules are line-level, not match-level; a real address sharing a line with an allowed one is caught by the private denylist, not by cleverer regex.
- Decided: scan uses `git ls-files`, not `find`, so untracked local files (`LOGS/`, `baseline-submodules.txt`) are never scanned or reported.
- Decided: file-type and size blocks are in code with an env override (`GRID_MAX_BYTES`), not in the pattern file, because they act on files, not lines.
- Decided: handoff location overrides come from `~/.the-grid-private/handoff-locations.md` (same private-path convention as roles), not from a new env var or `user.yaml` field.
- Decided: no new `user.yaml` fields; #54 persona fields are out of scope.
- Decided: #42 and #54 stay open; the final HUMAN group comments on both with what this change did and did not cover.
- Decided: one PR per group, but the private-repo archive (group 1) is HUMAN because it commits to a second repo and the unattended loop is scoped to this repo.
- Decided: group 3 refuses to `git rm` any path unless `~/.the-grid-private/archive/MANIFEST.sha256` lists it and the archived copy hashes equal; re-running after success is a no-op.
- Decided: `scripts/gate.sh` gains a `personal` check as the last wiring step (group 6); edit groups verify with `bash scripts/check-personal.sh <touched files>` before then.

- Decided: `\bsk-` (word boundary) in the token rule; without it `finance-desk-finance-risk-officer` in `index.html` is a false positive (verified against the current tree).
- Decided: URL userinfo (`https://user:tok@github.com/...`), `/Users/alice|bob/` and AWS-style `...EXAMPLE` keys are allowed placeholders, because other drafted changes (`instincts`, `vetting`) already use them as test fixtures; with these allows the generic half is clean on the current tree apart from the inventoried files.
- Decided: the no-dangling-reference test in group 3 excludes `openspec/`, because change and archive docs must name the removed paths.
- Decided: the `personal` gate check runs after `compose` and before `bats`; `tests/test_gate.bats` stubs `scripts/check-personal.sh` in its fake grid so its existing tests keep their meaning.
- Decided: overlap with `vetting` is accepted: this scan covers the whole tracked tree for personal data; `vetting`'s `audit.py` covers skill content policy (owned and upstream). Neither calls the other.
- Decided: composed IDENTITY nameplates are not touched here. `compose.py` `load_user_config()` reads gitignored `agent-factory/user.yaml` and `render_identity()` writes only under gitignored `agent-factory/projects/` (`--out` default); `run_evals.py` uses no nameplate; no tracked file in this repo contains a rendered nameplate (checked: no tracked email or home path outside the inventory). The one leak path, `deploy.py --profile full` writing the flattened identity into another repo's `.claude/agents/`, is D1's (`workflow-upgrades`); the lean default already drops the nameplate.

## Risks

- Another change rewriting `README.md`/`index.html` first would conflict with the one-sentence edits; mitigated by landing this before `front-door`.
- History still contains everything moved; see Non-goals.
- Open question for the owner: whether to later rewrite history for the moved paths (a single `git filter-repo` pass, as was done for `LOGS/`) and rotate anything that was ever real.
