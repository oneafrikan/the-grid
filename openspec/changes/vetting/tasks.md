# Tasks

Conventions for every group: Python is 3 stdlib only; shell passes `shellcheck -S warning`; comment generously; tests are bats under `tests/`, never touch the real `~/.claude`, and build fixtures inside the test with `mktemp -d` and `printf` (no fake credentials or injection phrases committed). Reuse `tests/helpers/setup.bash` (`common_setup`, `make_skill`). `design.md` holds the full `policy.yaml`, rule semantics, report formats and CLI; copy them, do not redesign. Default verify command: `bash scripts/gate.sh`.

## 1. Scanner core: policy, restricted-YAML reader, audit.py

Files: `policy.yaml` (copy verbatim from design.md, including `owned_roots`/`skip_dirs`), `scripts/lib/miniyaml.py`, `scripts/audit.py`, `tests/test_miniyaml.bats`, `tests/test_audit.bats`.

- [ ] 1.1 Write `scripts/lib/miniyaml.py`: `loads(text)` and `ParseError(line, msg)` implementing exactly the subset in design.md "Restricted YAML". Reject unsupported syntax with the line number.
- [ ] 1.2 Write `tests/test_miniyaml.bats`: (a) the real `policy.yaml` parses and, when `python3 -c "import yaml"` succeeds, equals `yaml.safe_load` (else the test prints a skip); (b) each unsupported construct (anchor, `|` block scalar, tab indent, duplicate key) exits non-zero with its line number; (c) a single-quoted regex with backslashes round-trips unchanged.
- [ ] 1.3 Write `scripts/audit.py` per design.md: arguments, file-class globbing (regex translation, not fnmatch), rule evaluation order, built-in checks (`hidden-unicode`, `symlink-escape`, `binary-exec`, `oversize-file`; frontmatter `hooks:` lines are class `hook`), tier by `owned_roots`, allowlist parsing from the fenced `audit-allow` block of `--allow`/`<grid-dir>/CURATION.md` with validation (known rule id, `reason` >= 10 chars), text and JSON output with escaped excerpts, sorted deterministically, exit codes 0/1/2. Insert `sys.path` for `scripts/lib` from `__file__` (do not use `python3 -I`).
- [ ] 1.4 Write `tests/test_audit.bats` with generated fixtures. MUST FLAG (high, assert rule id and `path:line`): one fixture per rule id in `policy.yaml` plus `hidden-unicode` (U+202E via `printf '\xe2\x80\xae'`), `symlink-escape`, and `hook-network` (script under `hooks/`, and a `SKILL.md` with a frontmatter `hooks:` command that curls). MUST PASS (exit 0, zero high): a realistic clean skill; `npx -y pkg@1.2.3`; `uvx tool==1.0.0`; `AKIAIOSFODNN7EXAMPLE`; BOM-prefixed file; Arabic text with U+200D; `curl ... | jq .`; `/Users/you/x` placeholder path; `https://x.com/home/foo`.
- [ ] 1.5 Tests for context: negation downgrade in `.md` (low, `downgraded: negation`) but NOT in `.sh`; comment downgrade in `.sh`; test-dir cap; `secret-shape` not capped under `test/`; owned vs upstream `home-path` (build a temp root with `skills/x` and `repos/y/z`).
- [ ] 1.6 Tests for allowlist: matching entry suppresses and `--show-allowed` lists it; missing reason -> exit 2 naming the entry; unknown rule -> exit 2; extra non-matching line in the same file still reported; unused entry gives `allow-unused` low and exit 0.
- [ ] 1.7 Tests for output: `--format json` has `version`, `policy_sha256`, counts, findings; two runs byte-identical; `--quiet` hides LOW lines; excerpt containing U+200B prints the literal text `\u200b` and no raw U+200B byte sequence; missing target -> exit 2; broken regex in a copied policy -> exit 2 naming the rule id.
- [ ] 1.8 Verify: `tests/lib/bats-core/bin/bats tests/test_miniyaml.bats tests/test_audit.bats` then `bash scripts/gate.sh`.

Acceptance: both new bats files pass; `python3 scripts/audit.py skills agents` on this repo exits 0 (owned tier has no high today; 2 `latest-tag` lows are expected).

## 2. Source and curation checks

Depends on: 1.

Files: `scripts/audit.py`, `tests/test_audit_sources.bats`.

- [ ] 2.0 Add `--baseline FILE` per design.md "audit.py CLI": collect the repo names it wires (first path segment of each entry that is not blank, `#`, `-…` or `project:…`).

- [ ] 2.1 Add `--check-url URL`: normalise `git@github.com:o/r.git`, `https://github.com/o/r(.git)`, trailing slash and case to `o/r`; exit 0 only if host is in `sources.allowed_hosts` and `o/r` is in `allowed_repos` (case-insensitive); otherwise exit 1 and print the reason.
- [ ] 2.2 When `<root>/.gitmodules` exists, for every target that resolves under `<root>/repos/<name>/` (upstream tier), look up that submodule's URL (parse `.gitmodules` by section; track the line number of `url`) and emit `source-not-allowed` if not allowed and `source-uncurated` if CURATION.md has no `### repos/<name>` heading; each is `high` when the repo is in the `--baseline` set, else `low`; `--quiet` never hides either. Both reported at `.gitmodules:<line>`; one finding per repo even when many targets share it. No `.gitmodules` or target outside `repos/` -> no source checks.
- [ ] 2.3 Tests (temp root with a hand-written `.gitmodules`, `repos/<name>/<skill>/SKILL.md`, a policy and a CURATION.md): unlisted URL with the repo in a `--baseline` file -> high `source-not-allowed`, exit 1; same unlisted repo absent from the baseline (overlay-only, or no `--baseline`) -> low `source-not-allowed`, exit 0, still printed under `--quiet`; SSH vs HTTPS and case variants pass; library repo (no target under it) not checked; missing heading with the repo in a `--baseline` file -> high, exit 1; same repo absent from the baseline (or no `--baseline`) -> low, exit 0; adding the heading clears it; `--check-url` exit codes; two skills in one repo yield one finding.
- [ ] 2.4 Verify: `tests/lib/bats-core/bin/bats tests/test_audit_sources.bats` then `bash scripts/gate.sh`.

## 3. audit.sh: choose what to scan

Depends on: 1, 2, foundations#2 (`GRID_BASELINE` in wire.sh).

Files: `scripts/audit.sh`, `tests/test_audit_integration.bats` (selector tests only in this group).

- [ ] 3.1 Write `scripts/audit.sh` with modes `--owned`, `--wired`, `--gate`; remaining args pass through to `audit.py`. `--owned` lists whichever of `skills/*/`, `agents/*.md`, `rules/`, `hooks/`, `agent-factory/roles/*/`, `agent-factory/_core/` exist under `GRID_DIR`. `--wired` runs `GRID_SKIP_CATALOG=1 GRID_SKIP_AUDIT=1 SKILLS_DIR=<tmp> AGENTS_DIR=<tmp> bash wire.sh` (the same wire.sh next to audit.sh, `GRID_DIR` honoured), collects `readlink` of every symlink in both tmp dirs, cleans the tmp dir with a trap. `--gate` = owned, plus the wired set of the baseline chosen per design.md (`$GRID_BASELINE`, else `baseline-submodules.txt`, else `baseline-submodules.example.txt` with `GRID_HOST=baseline-only`), wired via the same dry run with `GRID_BASELINE` set; when `git submodule status` shows a leading `-` skip the wired part and print `audit: wired set not scanned (uninitialised submodules)`. Every mode passes `--baseline <file>` (the file the dry run used; `--owned` passes it too when it exists). Non-option arguments are appended as extra targets; with no mode, only those targets are scanned. Combine into ONE `audit.py` invocation so the summary and exit code cover everything. Missing `python3` -> exit 2 with a message.
- [ ] 3.2 Tests with a mock grid (copy real `policy.yaml`, a `CURATION.md` with empty allowlist): `--owned` flags a bad `skills/x`; `--wired` flags a bad skill reachable through a `repos/<r>` + baseline entry and ignores an unwired (library) repo with the same bad content; `--wired` leaves the real `SKILLS_DIR` untouched; `--gate` without a personal baseline scans the skills wired by `baseline-submodules.example.txt`; `--gate` with a submodule shown as uninitialised (stub `git` on PATH or a real uninitialised submodule in the mock) prints the notice and scans owned only; `bash scripts/audit.sh <dir>` scans just that dir; a clean grid exits 0.
- [ ] 3.3 Verify: `tests/lib/bats-core/bin/bats tests/test_audit_integration.bats` then `bash scripts/gate.sh`.

## 4. HUMAN: CURATION.md and first-run triage of the real wired set

Depends on: 1, 2, 3. Needs a machine with all submodules initialised and a real `baseline-submodules.txt`. The agent drafts everything; the operator reviews trust rationale and every allowlist reason before merge.

Files: `CURATION.md`, `policy.yaml` (`sources.allowed_repos` and rule tuning only), `tests/test_curation.bats`.

- [ ] 4.1 Run `bash scripts/audit.sh --wired`, `--owned`, and `GRID_BASELINE=baseline-submodules.example.txt GRID_HOST=baseline-only bash scripts/audit.sh --gate` (what CI will run). For every `high`: if the same false-positive class hits 3+ places, fix the rule in `policy.yaml` (`ignore_regex` or `downgrade`) and add a fixture line to `tests/test_audit.bats`; otherwise add an `audit-allow` entry with a specific reason. A high that is a TRUE positive (real malicious or unsafe behaviour) is not allowlisted: stop, mark the group `blocked`, and report the file:line in the PR description.
- [ ] 4.2 Write `CURATION.md` in the format in design.md: a `### repos/<name>` section for every repo in `baseline-submodules.example.txt` and every repo wired on this machine (factual lines only: upstream URL, pin policy, why trusted, accepted behaviours, last audited date and counts), `### owned`, an `## Exclusions` table (include: `openspec/release-openspec` maintainer-only; gstack OpenClaw/GBrain tools and `benchmark-models` left to machine overlays; `repos/ecc` library tier with the unpinned-`npx -y` count; anything the triage in 4.1 removed from the wired set), and the `audit-allow` block from 4.1. No private paths, hostnames or personal data; do not link the private research repo.
- [ ] 4.3 Set `sources.allowed_repos` in `policy.yaml` to cover exactly those repos (owner/repo form).
- [ ] 4.4 Run the scanner once over ECC's `hooks/`, `scripts/hooks/`, `plugins/` and MCP configs (`python3 scripts/audit.py --root repos/ecc ...` or the equivalent direct paths) and record the expected findings in the ECC row of `## Exclusions` or its `### repos/ecc` note.
- [ ] 4.5 Write `tests/test_curation.bats` (runs in CI without baseline): `CURATION.md` exists; `audit.py` can parse its allowlist (no exit 2 on an empty scan); every repo in `baseline-submodules.example.txt` that is a `repos/` entry has a `### repos/<name>` heading and its URL (from `.gitmodules`) passes `audit.py --check-url`.
- [ ] 4.6 Verify: `bash scripts/audit.sh --wired --quiet; echo $?` and the example-baseline `--gate` command from 4.1 both print 0 on the machine; `tests/lib/bats-core/bin/bats tests/test_curation.bats`; `bash scripts/gate.sh`.

## 5. Wire into wire.sh and gate.sh, docs

Depends on: 3, 4 (the gate must not go red on the real wired set before the allowlist exists).

Files: `scripts/wire.sh`, `scripts/gate.sh`, `tests/test_audit_integration.bats` (add cases), `tests/test_gate.bats` (add one case), `CLAUDE.md`.

- [ ] 5.1 Add the "0. Vet before touching any link" block from design.md to `scripts/wire.sh`, before step 1 (teardown). Keep the file shellcheck-clean; add the `GRID_SKIP_AUDIT` and `GRID_AUDIT` variables to the header comment's env list.
- [ ] 5.2 Add `run_audit` and `check audit run_audit` to `scripts/gate.sh` after `compose`; update the header "Checks" comment.
- [ ] 5.3 Tests in `tests/test_audit_integration.bats` using a mock grid with the real `policy.yaml`: (a) bad wired skill -> `wire.sh` exits 3 and pre-existing links in `SKILLS_DIR` are unchanged; (b) same with `GRID_AUDIT=warn` -> exit 0 and the warning; (c) low-only -> exit 0; (d) no `policy.yaml` -> wires with the skipped notice; (e) `PATH` without `python3` -> wires with the loud notice; (f) `wire.sh --check` starts no audit (no audit output, links unchanged) and a second real wire leaves identical links; (h) a repo wired only via `machines/<GRID_HOST>.txt` with no CURATION heading -> wire exits 0 and prints the `source-uncurated` warning, while the same repo in the baseline -> exit 3; (i) a repo wired only via the overlay whose URL is not in `allowed_repos` -> wire exits 0 and prints the `source-not-allowed` warning; (g) existing `tests/test_wiring.bats` still passes unmodified.
- [ ] 5.4 Add to `tests/test_gate.bats` a case proving the new check is skipped loudly (listed under `skipped:`) in the stub repo without `python3`/`audit.sh`; and a case where a stub `scripts/audit.sh` exiting 1 makes the gate FAIL with `audit` in the failed list.
- [ ] 5.5 Update `CLAUDE.md`: Key files entries for `policy.yaml`, `CURATION.md`, `scripts/audit.sh`/`audit.py`; the `wire.sh contract` bullets for `GRID_AUDIT=warn`, `GRID_SKIP_AUDIT`, exit 3; one line naming the D3 interface (`audit.py --format json --root <root> DIR...`, `audit.sh --owned|--wired|--gate [TARGET...]`). Do not edit README (front-door owns it).
- [ ] 5.6 Verify: `bash scripts/gate.sh`; on a wired machine `bash scripts/wire.sh` exits 0 and a second run is a no-op.
