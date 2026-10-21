#!/usr/bin/env bats
# scripts/knowledge.py core helpers (change `knowledge-signals`): claim hash, entry id,
# slug, warrant rule and stage ceiling. Pure functions: no files are written.

load helpers/setup

bats_require_minimum_version 1.5.0   # `run --separate-stderr`

setup() {
  common_setup
}

teardown() {
  common_teardown
}

# py <expr> — evaluate a Python expression against the library and print the result.
# -I keeps the user's site and environment out; the library dir is added by hand.
py() {
  python3 -I -c '
import sys
sys.path.insert(0, sys.argv[1] + "/scripts")
import knowledge
print(eval(sys.argv[2]))
' "$REPO_ROOT" "$1"
}

@test "claim_hash ignores case and spacing" {
  a=$(py 'knowledge.claim_hash("Use  the   Gate")')
  b=$(py 'knowledge.claim_hash("  use the gate\t")')
  [ "$a" = "$b" ]
}

@test "claim_hash differs for different claims" {
  a=$(py 'knowledge.claim_hash("use the gate")')
  b=$(py 'knowledge.claim_hash("skip the gate")')
  [ "$a" != "$b" ]
}

@test "claim_hash is 16 lowercase hex" {
  run py 'knowledge.claim_hash("use the gate")'
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^[0-9a-f]{16}$ ]]
}

@test "entry_id is K- plus 8 hex of the claim hash" {
  id=$(py 'knowledge.entry_id("use the gate")')
  h=$(py 'knowledge.claim_hash("use the gate")')
  [[ "$id" =~ ^K-[0-9a-f]{8}$ ]]
  [ "$id" = "K-${h:0:8}" ]
}

@test "slug folds punctuation runs to one dash" {
  run py 'knowledge.slug("  Hello, World!! -- v2.0 ")'
  [ "$output" = "hello-world-v2-0" ]
}

@test "slug cuts at 40 with no trailing dash" {
  # 39 letters then punctuation: the cut at 40 lands on a dash that must be trimmed.
  run py 'knowledge.slug("a" * 39 + "!!bbb")'
  [ "$output" = "$(printf 'a%.0s' $(seq 1 39))" ]
  run py 'len(knowledge.slug("x" * 100))'
  [ "$output" = "40" ]
}

@test "is_warranted is false for each placeholder, any case" {
  for w in none NONE n/a N/A na untested unknown tbd TBD '?' '' '   '; do
    run py "knowledge.is_warranted($(printf '%s' "$w" | python3 -I -c 'import sys; print(repr(sys.stdin.read()))'))"
    [ "$output" = "False" ]
  done
}

@test "is_warranted is true for a real sentence" {
  run py 'knowledge.is_warranted("  ran bats on the branch, all green ")'
  [ "$output" = "True" ]
}

@test "ceiling: no warranted filer is wip" {
  run py 'knowledge.ceiling([])'
  [ "$output" = "wip" ]
  run py 'knowledge.ceiling([{"filed_by": "a", "warrant": "none"}])'
  [ "$output" = "wip" ]
}

@test "ceiling: one warranted filer is provisional" {
  run py 'knowledge.ceiling([{"filed_by": "a", "warrant": "saw it"}, {"filed_by": "b", "warrant": "tbd"}])'
  [ "$output" = "provisional" ]
}

@test "ceiling: two warranted filers is established" {
  run py 'knowledge.ceiling([{"filed_by": "a", "warrant": "saw it"}, {"filed_by": "b", "warrant": "ran it"}])'
  [ "$output" = "established" ]
}

@test "ceiling: one filer twice counts once" {
  run py 'knowledge.ceiling([{"filed_by": "a", "warrant": "saw it"}, {"filed_by": "a", "warrant": "ran it"}])'
  [ "$output" = "provisional" ]
}

# psig <python expr> — the expression yields signal text (sig() builds a valid one, with
# keyword overrides; an override of None drops the key). Prints "ok" or "<code> <message>".
psig() {
  python3 -I -c '
import sys
sys.path.insert(0, sys.argv[1] + "/scripts")
import knowledge

def sig(body="", **over):
    f = {"filed_by": "agent-1", "claim": "use the gate", "stage": "provisional",
         "warrant": "ran bats", "status": "pending"}
    f.update(over)
    lines = ["%s: %s" % (k, v) for k, v in f.items() if v is not None]
    return "---\n" + "\n".join(lines) + "\n---\n" + body

try:
    knowledge.parse_signal(eval(sys.argv[2]))
    print("ok")
except knowledge.KnowledgeError as e:
    print(e.code, e)
' "$REPO_ROOT" "$1"
}

@test "parse_signal accepts a valid minimal signal and returns fields plus body" {
  run psig 'sig()'
  [ "$output" = "ok" ]
  run py 'knowledge.parse_signal("---\nfiled_by: a\nclaim: c\nstage: wip\nwarrant: none\nstatus: pending\n---\nhello\n")["body"]'
  [ "$output" = "hello" ]
}

@test "parse_signal accepts the optional keys and a warrant of none" {
  run psig 'sig(warrant="none", supersedes="K-0123abcd", contradicts="K-0123abcd", confirms="K-0123abcd", guardrail="GUARDRAILS#G12")'
  [ "$output" = "ok" ]
}

@test "SIGNAL_NAME_RE matches a hand-written name and rejects a bad one" {
  run py 'bool(knowledge.SIGNAL_NAME_RE.match("20261018T101500Z-human-alex-abc123.md"))'
  [ "$output" = "True" ]
  run py 'bool(knowledge.SIGNAL_NAME_RE.match("20261018T101500Z-human-ABC123.md"))'
  [ "$output" = "False" ]
  run py 'bool(knowledge.SIGNAL_NAME_RE.match("20261018T101500Z-a-abc12.md"))'
  [ "$output" = "False" ]
}

@test "filer_slug lower-cases, folds, trims and caps at 32" {
  run py 'knowledge.filer_slug(" Human.Alex_1 ")'
  [ "$output" = "human-alex-1" ]
  run py 'len(knowledge.filer_slug("x" * 60))'
  [ "$output" = "32" ]
}

@test "parse_signal rejects a bidirectional override in the claim" {
  run psig 'sig(claim="use the ‮gate")'
  [[ "$output" == "E_SIGNAL claim:"* ]]
}

@test "parse_signal rejects a zero-width space in the claim" {
  run psig 'sig(claim="use the​ gate")'
  [[ "$output" == "E_SIGNAL claim:"* ]]
}

@test "parse_signal rejects a 201-character claim but accepts 200" {
  run psig 'sig(claim="c" * 201)'
  [[ "$output" == "E_SIGNAL claim:"* ]]
  run psig 'sig(claim="c" * 200)'
  [ "$output" = "ok" ]
}

@test "parse_signal rejects a 301-character warrant" {
  run psig 'sig(warrant="w" * 301)'
  [[ "$output" == "E_SIGNAL warrant:"* ]]
}

@test "parse_signal: stage retired and superseded are E_SIGNAL" {
  run psig 'sig(stage="retired")'
  [[ "$output" == "E_SIGNAL stage:"* ]]
  run psig 'sig(stage="superseded")'
  [[ "$output" == "E_SIGNAL stage:"* ]]
}

@test "parse_signal: an unknown stage is E_STAGE" {
  run psig 'sig(stage="draft")'
  [[ "$output" == "E_STAGE stage:"* ]]
}

@test "parse_signal rejects an unknown key" {
  run psig 'sig(colour="blue")'
  [[ "$output" == "E_SIGNAL "* ]]
}

@test "parse_signal rejects a duplicate key" {
  run psig '"---\nfiled_by: a\nclaim: c\nclaim: d\nstage: wip\nwarrant: w\nstatus: pending\n---\n"'
  [[ "$output" == "E_SIGNAL "* ]]
}

@test "parse_signal rejects a missing required key" {
  run psig 'sig(warrant=None)'
  [ "$output" = "E_SIGNAL warrant: required" ]
}

@test "parse_signal rejects a missing closing fence and a line without a colon" {
  run psig '"---\nfiled_by: a\nclaim: c\n"'
  [[ "$output" == "E_SIGNAL "* ]]
  run psig '"---\nfiled_by a\n---\n"'
  [[ "$output" == "E_SIGNAL "* ]]
}

@test "parse_signal limits the body to 4096 bytes in UTF-8" {
  run psig 'sig(body="b" * 4096)'
  [ "$output" = "ok" ]
  run psig 'sig(body="b" * 4097)'
  [[ "$output" == "E_SIGNAL body:"* ]]
  # 2049 two-byte characters is 4098 bytes though only 2049 characters.
  run psig 'sig(body="é" * 2049)'
  [[ "$output" == "E_SIGNAL body:"* ]]
}

@test "parse_signal rejects status other than pending" {
  run psig 'sig(status="done")'
  [ "$output" = "E_SIGNAL status: must be pending" ]
}

@test "parse_signal error text never echoes claim or warrant text" {
  run psig 'sig(claim="xyzzy-distinctive-claim ‮")'
  [[ "$output" == "E_SIGNAL "* ]]
  [[ "$output" != *xyzzy* ]]
  run psig 'sig(warrant="plugh-distinctive-warrant" + "w" * 300)'
  [[ "$output" == "E_SIGNAL "* ]]
  [[ "$output" != *plugh* ]]
}

# pent <python expr> — the expression yields entry text. ent(**over) builds a valid entry
# through the library's own claim_hash (an override of None drops the key); evl() is the
# evidence list. Prints "ok" or "<code> <message>".
pent() {
  python3 -I -c '
import sys
sys.path.insert(0, sys.argv[1] + "/scripts")
import knowledge

SIGNAL = "20261018T101500Z-agent-1-abc123.md"

def evl(warrant="ran bats"):
    return [{"signal": SIGNAL, "filed_by": "agent-1", "stage": "provisional", "warrant": warrant}]

def fields(**over):
    claim = over.get("claim", "use the gate")
    h = knowledge.claim_hash(claim)
    f = {"id": "K-" + h[:8], "claim": claim, "claim_hash": h, "stage": "provisional",
         "created": "2026-10-18", "updated": "2026-10-19"}
    f.update(over)
    return {k: v for k, v in f.items() if v is not None}

def ent(**over):
    # Built by hand rather than render_entry so invalid inputs can be made too.
    f = fields(**over)
    lines = ["%s: %s" % (k, v) for k, v in f.items()]
    return ("---\n" + "\n".join(lines) + "\n---\n\n## Claim\n\n" + f.get("claim", "") +
            "\n\n## Evidence\n\n- " + " | ".join(evl()[0].values()) + "\n")

try:
    r = eval(sys.argv[2])
    print("ok" if r is None else r)
except knowledge.KnowledgeError as e:
    print(e.code, e)
' "$REPO_ROOT" "$1"
}

@test "ENTRY_NAME_RE matches K-hash8-slug.md and rejects bad names" {
  run py 'bool(knowledge.ENTRY_NAME_RE.match("K-0123abcd-use-the-gate.md"))'
  [ "$output" = "True" ]
  run py 'bool(knowledge.ENTRY_NAME_RE.match("K-0123abcd-entry.md"))'
  [ "$output" = "True" ]
  run py 'bool(knowledge.ENTRY_NAME_RE.match("K-0123ABCD-x.md"))'
  [ "$output" = "False" ]
  run py 'bool(knowledge.ENTRY_NAME_RE.match("K-0123abcd-" + "x" * 41 + ".md"))'
  [ "$output" = "False" ]
  run py 'bool(knowledge.ENTRY_NAME_RE.match("K-0123abcd-.md"))'
  [ "$output" = "False" ]
}

@test "render_entry then parse_entry round-trips fields and evidence" {
  run pent 'knowledge.parse_entry(knowledge.render_entry(fields(supersedes="K-0123abcd", guardrail="GUARDRAILS#G7", unwarranted="yes"), evl())) == dict(fields(supersedes="K-0123abcd", guardrail="GUARDRAILS#G7", unwarranted="yes"), claim_text="use the gate", evidence=evl())'
  [ "$output" = "True" ]
}

@test "render_entry writes the keys in the fixed order" {
  run pent 'knowledge.render_entry(dict(reversed(list(fields(contradicts="K-0123abcd").items()))), evl()).split("---")[1].split("\n")[1:-1] == [k + ": " + str(v) for k, v in fields(contradicts="K-0123abcd").items()]'
  [ "$output" = "True" ]
}

@test "parse_entry keeps a warrant that contains ' | '" {
  run pent 'knowledge.parse_entry(knowledge.render_entry(fields(), evl("a | b | c | d")))["evidence"][0]["warrant"]'
  [ "$output" = "a | b | c | d" ]
}

@test "parse_entry rejects an unknown key" {
  run pent 'knowledge.parse_entry(ent(colour="blue"))'
  [[ "$output" == "E_ENTRY "* ]]
}

@test "parse_entry rejects a missing ## Evidence heading" {
  run pent 'knowledge.parse_entry(ent().replace("## Evidence", "## Notes"))'
  [ "$output" = "E_ENTRY body: missing '## Evidence' heading" ]
}

@test "parse_entry rejects an evidence line with three fields" {
  run pent 'knowledge.parse_entry(ent().replace(" | provisional | ran bats", " | ran bats"))'
  [[ "$output" == "E_ENTRY evidence:"* ]]
}

@test "parse_entry rejects an id that does not match claim_hash" {
  run pent 'knowledge.parse_entry(ent(id="K-00000000"))'
  [ "$output" = "E_ENTRY id: must be K- plus the first 8 of claim_hash" ]
}

@test "parse_entry rejects a claim_hash that does not match the claim" {
  # A hand-edited claim with the old hash and id still in place.
  run pent 'knowledge.parse_entry(ent().replace("use the gate", "skip the gate"))'
  [ "$output" = "E_ENTRY claim_hash: does not match claim" ]
}

@test "parse_entry: stage draft is E_STAGE, retired is accepted" {
  run pent 'knowledge.parse_entry(ent(stage="draft"))'
  [[ "$output" == "E_STAGE stage:"* ]]
  run pent 'knowledge.parse_entry(ent(stage="retired"))["stage"]'
  [ "$output" = "retired" ]
}

@test "parse_entry rejects unwarranted: no" {
  run pent 'knowledge.parse_entry(ent(unwarranted="no"))'
  [[ "$output" == "E_ENTRY unwarranted:"* ]]
}

@test "parse_entry rejects a bad date and a missing required key" {
  run pent 'knowledge.parse_entry(ent(created="2026-02-30"))'
  [[ "$output" == "E_ENTRY created:"* ]]
  run pent 'knowledge.parse_entry(ent(updated=None))'
  [ "$output" = "E_ENTRY updated: required" ]
}

# paddr <expr> — evaluate an expression against a throwaway knowledge tree under
# $BATS_TEST_TMPDIR. put(dir, claim) writes a rendered entry into knowledge/<dir>/ and
# returns its id; move(a, b) moves every file from dir a to dir b; R(addr) resolves.
# Prints the result, or "<code> <message>" on KnowledgeError.
paddr() {
  python3 -I -c '
import os, sys
sys.path.insert(0, sys.argv[1] + "/scripts")
import knowledge

ROOT = sys.argv[3]

def put(d, claim="use the gate", name=None):
    h = knowledge.claim_hash(claim)
    f = {"id": "K-" + h[:8], "claim": claim, "claim_hash": h, "stage": "provisional",
         "created": "2026-10-18", "updated": "2026-10-19"}
    ev = [{"signal": "20261018T101500Z-agent-1-abc123.md", "filed_by": "agent-1",
           "stage": "provisional", "warrant": "ran bats"}]
    os.makedirs(os.path.join(ROOT, "knowledge", d), exist_ok=True)
    name = name or "%s-%s.md" % (f["id"], knowledge.slug(claim))
    with open(os.path.join(ROOT, "knowledge", d, name), "w") as fh:
        fh.write(knowledge.render_entry(f, ev))
    return f["id"]

def move(a, b):
    os.makedirs(os.path.join(ROOT, "knowledge", b), exist_ok=True)
    for n in os.listdir(os.path.join(ROOT, "knowledge", a)):
        os.rename(os.path.join(ROOT, "knowledge", a, n), os.path.join(ROOT, "knowledge", b, n))

def R(addr):
    return knowledge.resolve_address(ROOT, addr)

try:
    r = eval(sys.argv[2])
    print("ok" if r is None else r)
except knowledge.KnowledgeError as e:
    print(e.code, e)
' "$REPO_ROOT" "$1" "$BATS_TEST_TMPDIR/kroot"
}

@test "heading_slugs lower-cases, drops punctuation, hyphenates and skips code fences" {
  run py 'knowledge.heading_slugs("# Title\n## Whats New, Here?\ntext\n```\n# not a heading\n```\n### Done ##")'
  [ "$output" = "['title', 'whats-new-here', 'done']" ]
}

@test "resolve_address: K-hash8 resolves to the entry path" {
  run paddr 'R(put("provisional"))'
  [[ "$output" == "('knowledge/provisional/K-"*"-use-the-gate.md', None)" ]]
}

@test "resolve_address: K-hash8#evidence resolves and survives a move to established" {
  run paddr 'R(put("provisional") + "#evidence")[1]'
  [ "$output" = "evidence" ]
  run paddr '(move("provisional", "established"), R(knowledge.entry_id("use the gate") + "#evidence"))[1]'
  [[ "$output" == "('knowledge/established/K-"*"-use-the-gate.md', 'evidence')" ]]
}

@test "resolve_address: a slug that is not a heading fails with no heading <slug>" {
  run paddr 'R(put("provisional") + "#notes")'
  [ "$output" = "E_ADDRESS no heading notes" ]
}

@test "resolve_address: two files with one K-hash8 fail and the message lists both" {
  run paddr '(put("provisional"), put("established", name=knowledge.entry_id("use the gate") + "-copy.md"), R(knowledge.entry_id("use the gate")))[2]'
  [[ "$output" == "E_ADDRESS ambiguous K-"*"knowledge/established/K-"*"-copy.md, knowledge/provisional/K-"*"-use-the-gate.md" ]]
}

@test "resolve_address: an unknown id fails" {
  run paddr '(put("provisional"), R("K-00000000"))[1]'
  [ "$output" = "E_ADDRESS no entry matches K-00000000" ]
}

@test "resolve_address: path form works while the file is there and fails after a move" {
  run paddr 'R("knowledge/provisional/%s-use-the-gate.md#claim" % put("provisional"))[1]'
  [ "$output" = "claim" ]
  run paddr '(move("provisional", "established"), R("knowledge/provisional/%s-use-the-gate.md" % knowledge.entry_id("use the gate")))[1]'
  [[ "$output" == "E_ADDRESS no such file: knowledge/provisional/K-"* ]]
}

@test "resolve_address: .. and absolute paths in the path form fail" {
  run paddr 'R("knowledge/../K-0123abcd-x.md")'
  [[ "$output" == "E_ADDRESS path form must be"* ]]
  run paddr 'R("/etc/passwd")'
  [[ "$output" == "E_ADDRESS address must be"* ]]
  run paddr 'R("knowledge/provisional/../../x/K-0123abcd-x.md")'
  [[ "$output" == "E_ADDRESS path form must be"* ]]
}

# pled <expr> — like paddr, for the ledger. Helpers: D/Res/Re build records, app(*recs)
# appends them, led() reads the ledger back, state() is claim_state for hash h1, raw(text)
# overwrites the file for malformed-line cases. Prints the result, or "<code> <message>"
# on KnowledgeError.
pled() {
  python3 -I -c '
import os, sys
sys.path.insert(0, sys.argv[1] + "/scripts")
import knowledge

ROOT = sys.argv[3]

def D(sig, h, disp, issue=None):
    return {"event": "disposition", "signal": sig, "claim_hash": h, "disposition": disp,
            "entry": None, "issue": issue, "pr": None, "run": "r1"}

def Res(h, result):
    return {"event": "resolution", "claim_hash": h, "pr": 7, "result": result, "run": "r2"}

def Re(h):
    return {"event": "reopen", "claim_hash": h, "by": "operator", "run": "r3"}

def app(*recs):
    knowledge.append_ledger(ROOT, list(recs))

def led():
    return knowledge.read_ledger(ROOT)

def state(h="h1"):
    return knowledge.claim_state(led(), h)

def raw(text):
    p = knowledge.ledger_path(ROOT)
    os.makedirs(os.path.dirname(p), exist_ok=True)
    with open(p, "w") as fh:
        fh.write(text)

def text():
    with open(knowledge.ledger_path(ROOT)) as fh:
        return fh.read()

try:
    r = eval(sys.argv[2])
    print("ok" if r is None else r)
except knowledge.KnowledgeError as e:
    print(e.code, e)
' "$REPO_ROOT" "$1" "$BATS_TEST_TMPDIR/lroot"
}

@test "read_ledger: an absent ledger is an empty list" {
  run pled 'led()'
  [ "$output" = "[]" ]
}

@test "append_ledger: creates signals/done and earlier lines stay a byte prefix" {
  run pled '(app(D("a.md", "h1", "written"), D("b.md", "h2", "wip")), text())[1]'
  first="$output"
  [ "$(printf '%s\n' "$first" | wc -l)" -eq 2 ]
  # Append a third record in a second process, then compare the first two lines byte for byte.
  run pled '(app(Res("h1", "accepted")), text())[1]'
  [ "${output:0:${#first}}" = "$first" ]
  [ "$(printf '%s\n' "$output" | wc -l)" -eq 3 ]
}

@test "append_ledger: lines are compact with sorted keys" {
  run pled '(app(Re("h1")), text())[1]'
  [ "$output" = '{"by":"operator","claim_hash":"h1","event":"reopen","run":"r3"}' ]
}

@test "append_ledger only opens the ledger in append mode" {
  grep -q 'open(path, "a"' "$REPO_ROOT/scripts/knowledge.py"
  ! grep -nE 'open\(path, "(w|r\+|wb)"' "$REPO_ROOT/scripts/knowledge.py" || false
}

@test "read_ledger: a malformed JSON line fails with E_LEDGER and the line number" {
  run pled '(raw("{\"event\":\"reopen\",\"claim_hash\":\"h\",\"by\":\"x\",\"run\":\"r\"}\n\nnot json\n"), led())[1]'
  [ "$output" = "E_LEDGER line 3: not valid JSON" ]
}

@test "read_ledger: unknown event and missing keys fail with E_LEDGER" {
  run pled '(raw("{\"event\":\"bogus\"}\n"), led())[1]'
  [ "$output" = "E_LEDGER line 1: unknown event" ]
  run pled '(raw("{\"event\":\"resolution\",\"claim_hash\":\"h\",\"pr\":1,\"run\":\"r\"}\n"), led())[1]'
  [ "$output" = "E_LEDGER line 1: resolution needs key result" ]
}

@test "read_ledger: unknown disposition and result fail with E_LEDGER" {
  run pled '(raw("{\"event\":\"disposition\",\"signal\":\"s\",\"claim_hash\":\"h\",\"disposition\":\"nope\",\"entry\":null,\"issue\":null,\"pr\":null,\"run\":\"r\"}\n"), led())[1]'
  [ "$output" = "E_LEDGER line 1: unknown disposition" ]
  run pled '(raw("{\"event\":\"resolution\",\"claim_hash\":\"h\",\"pr\":1,\"result\":\"maybe\",\"run\":\"r\"}\n"), led())[1]'
  [ "$output" = "E_LEDGER line 1: unknown result" ]
}

@test "processed_signals: the signal names that have a disposition line" {
  run pled '(app(D("a.md", "h1", "written"), D("b.md", "h2", "duplicate"), Res("h1", "accepted")), sorted(knowledge.processed_signals(led())))[1]'
  [ "$output" = "['a.md', 'b.md']" ]
}

@test "claim_state: escalated with no resolution is open at that issue" {
  run pled '(app(D("a.md", "h1", "escalated", 42)), state())[1]'
  [ "$output" = "{'escalated_open': 42, 'rejected': False}" ]
}

@test "claim_state: escalated then accepted is no longer open and not rejected" {
  run pled '(app(D("a.md", "h1", "escalated", 42), Res("h1", "accepted")), state())[1]'
  [ "$output" = "{'escalated_open': None, 'rejected': False}" ]
}

@test "claim_state: escalated then rejected is closed and rejected" {
  run pled '(app(D("a.md", "h1", "escalated", 42), Res("h1", "rejected")), state())[1]'
  [ "$output" = "{'escalated_open': None, 'rejected': True}" ]
}

@test "claim_state: rejected then reopen is not rejected" {
  run pled '(app(Res("h1", "rejected"), Re("h1")), state())[1]'
  [ "$output" = "{'escalated_open': None, 'rejected': False}" ]
}

@test "claim_state: rejected, reopen, rejected again is rejected" {
  run pled '(app(Res("h1", "rejected"), Re("h1"), Res("h1", "rejected")), state())[1]'
  [ "$output" = "{'escalated_open': None, 'rejected': True}" ]
}

@test "claim_state: other hashes do not affect the answer" {
  run pled '(app(D("a.md", "h2", "escalated", 9), Res("h2", "rejected")), state())[1]'
  [ "$output" = "{'escalated_open': None, 'rejected': False}" ]
}

@test "cli hash: case and spacing do not change the output, which is 16 hex plus newline" {
  a=$(python3 -I "$REPO_ROOT/scripts/knowledge.py" hash "Use  the   Gate")
  b=$(python3 -I "$REPO_ROOT/scripts/knowledge.py" hash "  use the gate ")
  [ "$a" = "$b" ]
  run python3 -I "$REPO_ROOT/scripts/knowledge.py" hash "use the gate"
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^[0-9a-f]{16}$ ]]
  # Command substitution strips the newline, so count the raw bytes: 16 hex plus one newline.
  [ "$(python3 -I "$REPO_ROOT/scripts/knowledge.py" hash "use the gate" | wc -c)" -eq 17 ]
}

@test "cli hash: accepts --root DIR" {
  run python3 -I "$REPO_ROOT/scripts/knowledge.py" hash --root "$BATS_TEST_TMPDIR" "use the gate"
  [ "$status" -eq 0 ]
  [ "$output" = "$(py 'knowledge.claim_hash("use the gate")')" ]
}

@test "cli: no argument, an unknown subcommand and an unknown option exit 2 with one stderr line" {
  for args in "" "bogus" "hash" "hash --bogus x" "hash --root"; do
    # shellcheck disable=SC2086
    run python3 -I "$REPO_ROOT/scripts/knowledge.py" $args
    [ "$status" -eq 2 ]
  done
  python3 -I "$REPO_ROOT/scripts/knowledge.py" bogus 2>"$BATS_TEST_TMPDIR/err" >"$BATS_TEST_TMPDIR/out" || true
  [ ! -s "$BATS_TEST_TMPDIR/out" ]
  [ "$(wc -l <"$BATS_TEST_TMPDIR/err")" -eq 1 ]
  [[ "$(cat "$BATS_TEST_TMPDIR/err")" == "knowledge.py:"* ]]
}

# kfile <extra args...> — run `knowledge.py file` into a temp root at a fixed second. The
# required options default to a valid set; a later duplicate cannot override them, so tests
# that change one pass it via the KF_* variables instead.
kfile() {
  KNOWLEDGE_NOW=20261018T101500Z run python3 -I "$REPO_ROOT/scripts/knowledge.py" file \
    --root "$BATS_TEST_TMPDIR/proj" --filer "${KF_FILER:-agent-a}" --claim "${KF_CLAIM:-use the gate}" \
    --stage "${KF_STAGE:-provisional}" --warrant "${KF_WARRANT:-seen in CI}" "$@"
}

@test "cli file: prints the path of a valid pending signal that parse_signal accepts" {
  kfile
  [ "$status" -eq 0 ]
  [ -f "$output" ]
  path=$output
  [ "$path" = "$BATS_TEST_TMPDIR/proj/signals/$(basename "$path")" ]
  run py "bool(knowledge.SIGNAL_NAME_RE.match('$(basename "$path")'))"
  [ "$output" = "True" ]
  grep -qx 'status: pending' "$path"
  [ "$(sed -n 2,6p "$path" | cut -d: -f1 | tr '\n' ' ')" = "filed_by claim stage warrant status " ]
  run py "knowledge.parse_signal(open('$path', encoding='utf-8').read())['claim']"
  [ "$output" = "use the gate" ]
}

@test "cli file: the name carries KNOWLEDGE_NOW, the filer slug and the first 6 hex of the content hash" {
  kfile --guardrail GUARDRAILS#G1
  [ "$status" -eq 0 ]
  name=$(basename "$output")
  [[ "$name" == 20261018T101500Z-agent-a-*.md ]]
  [ "${name: -9:6}" = "$(sha256sum "$output" | cut -c1-6)" ]
  grep -qx 'guardrail: GUARDRAILS#G1' "$output"
}

@test "cli file: a 201-character claim exits 2 and writes nothing" {
  KF_CLAIM=$(printf 'x%.0s' $(seq 201)) kfile
  [ "$status" -eq 2 ]
  # `run` folds stderr into $output: the only line is the error, with no signals/ made.
  [[ "$output" == "knowledge.py: E_SIGNAL claim: must be 1-200 characters" ]]
  [ ! -e "$BATS_TEST_TMPDIR/proj/signals" ]
}

@test "cli file: an unknown stage exits 2 and writes nothing" {
  KF_STAGE=draft kfile
  [ "$status" -eq 2 ]
  [ ! -e "$BATS_TEST_TMPDIR/proj/signals" ]
}

@test "cli file: a claim that smuggles in a second key is refused" {
  KF_CLAIM=$'use the gate\nguardrail: GUARDRAILS#G1' kfile
  [ "$status" -eq 2 ]
  [ ! -e "$BATS_TEST_TMPDIR/proj/signals" ]
}

@test "cli file: two filers in the same second get different names" {
  KF_FILER=agent-a kfile
  a=$output
  KF_FILER=agent-b kfile
  [ "$status" -eq 0 ]
  [ "$a" != "$output" ]
  [ "$(ls "$BATS_TEST_TMPDIR/proj/signals" | wc -l)" -eq 2 ]
}

@test "cli file: the same call twice leaves one file, untouched, and exits 0" {
  kfile
  first=$output
  before=$(sha256sum "$first")
  kfile
  [ "$status" -eq 0 ]
  [ "$output" = "$first" ]
  [ "$(ls "$BATS_TEST_TMPDIR/proj/signals" | wc -l)" -eq 1 ]
  [ "$(sha256sum "$first")" = "$before" ]
}

@test "cli file: --body-file content follows the frontmatter; 4097 bytes exits 2" {
  printf 'because the gate said so\n' >"$BATS_TEST_TMPDIR/body.md"
  kfile --body-file "$BATS_TEST_TMPDIR/body.md"
  [ "$status" -eq 0 ]
  [ "$(tail -n 3 "$output")" = $'---\n\nbecause the gate said so' ]
  head -c 4097 /dev/zero | tr '\0' 'a' >"$BATS_TEST_TMPDIR/big.md"
  count=$(ls "$BATS_TEST_TMPDIR/proj/signals" | wc -l)
  KF_FILER=agent-b kfile --body-file "$BATS_TEST_TMPDIR/big.md"
  [ "$status" -eq 2 ]
  [ "$(ls "$BATS_TEST_TMPDIR/proj/signals" | wc -l)" -eq "$count" ]
  KF_FILER=agent-b kfile --body-file "$BATS_TEST_TMPDIR/missing.md"
  [ "$status" -eq 2 ]
  [ "$(ls "$BATS_TEST_TMPDIR/proj/signals" | wc -l)" -eq "$count" ]
}

@test "cli file: creates no git commit" {
  mkdir -p "$BATS_TEST_TMPDIR/proj"
  git -C "$BATS_TEST_TMPDIR/proj" init -q
  # Identity comes from the environment so no address is written in this file.
  GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL="t@${HOSTNAME:-h}.test" GIT_COMMITTER_NAME=t \
    GIT_COMMITTER_EMAIL="t@${HOSTNAME:-h}.test" \
    git -C "$BATS_TEST_TMPDIR/proj" commit -q --allow-empty -m base
  before=$(git -C "$BATS_TEST_TMPDIR/proj" log --format=%H)
  kfile
  [ "$status" -eq 0 ]
  [ "$(git -C "$BATS_TEST_TMPDIR/proj" log --format=%H)" = "$before" ]
}

# kcheck_raw <args...> — run `knowledge.py check` against the temp project root; stderr is
# part of $output.
kcheck_raw() {
  run python3 -I "$REPO_ROOT/scripts/knowledge.py" check --root "$BATS_TEST_TMPDIR/proj" "$@"
}

# kcheck <args...> — kcheck_raw minus the `notice:` line check prints when the temp project is
# not a git repository, so the tests that predate the history check keep their exact output.
kcheck() {
  kcheck_raw "$@"
  output=$(printf '%s\n' "$output" | grep -v '^notice:' || true)
}

# gproj — make the temp project a git repo with one empty base commit. Identity comes from the
# environment (no address in this file) and no user or system git config is read.
gproj() {
  export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL="t@${HOSTNAME:-h}.test" GIT_COMMITTER_NAME=t \
    GIT_COMMITTER_EMAIL="t@${HOSTNAME:-h}.test" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
  mkdir -p "$BATS_TEST_TMPDIR/proj"
  git -C "$BATS_TEST_TMPDIR/proj" init -q
  git -C "$BATS_TEST_TMPDIR/proj" commit -q --allow-empty -m base
}

# gcommit <message> — stage everything in the temp project and commit it.
gcommit() {
  git -C "$BATS_TEST_TMPDIR/proj" add -A
  git -C "$BATS_TEST_TMPDIR/proj" commit -q -m "$1"
}

# wsig <name> <filed_by> <stage> [dir] — write a signal by hand into proj/<dir, default signals>.
wsig() {
  mkdir -p "$BATS_TEST_TMPDIR/proj/${4:-signals}"
  printf -- '---\nfiled_by: %s\nclaim: use the gate\nstage: %s\nwarrant: seen in CI\nstatus: pending\n---\n' \
    "$2" "$3" >"$BATS_TEST_TMPDIR/proj/${4:-signals}/$1"
}

@test "cli check: a tree with no signals/ exits 0 and prints nothing" {
  mkdir -p "$BATS_TEST_TMPDIR/proj"
  kcheck
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "cli check: a signal made by file passes, and so does a hand-written name" {
  kfile
  [ "$status" -eq 0 ]
  wsig 20261018T101500Z-human-alex-abc123.md human-alex provisional
  kcheck
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "cli check: README, a hand-off file and non-signals in done/ are ignored" {
  wsig 20261018T101500Z-agent-a-abc123.md agent-a wip
  printf 'hand-off\n' >"$BATS_TEST_TMPDIR/proj/signals/→tech-lead.md"
  printf '# signals\n' >"$BATS_TEST_TMPDIR/proj/signals/README.md"
  mkdir -p "$BATS_TEST_TMPDIR/proj/signals/done"
  printf 'not a signal\n' >"$BATS_TEST_TMPDIR/proj/signals/done/notes.md"
  printf '{}\n' >"$BATS_TEST_TMPDIR/proj/signals/done/ledger.jsonl"
  kcheck
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  # Named explicitly they are still skipped.
  kcheck signals/README.md "signals/→tech-lead.md"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "cli check: a misnamed file with a claim key is E_SIGNAL; one without is ignored" {
  wsig my-note.md agent-a wip
  printf 'just notes\n' >"$BATS_TEST_TMPDIR/proj/signals/other.md"
  kcheck
  [ "$status" -eq 1 ]
  [ "$output" = "E_SIGNAL signals/my-note.md: misnamed signal file" ]
}

@test "cli check: stage draft prints an E_STAGE line and exits 1, without claim text" {
  wsig 20261018T101500Z-agent-a-abc123.md agent-a draft
  kcheck
  [ "$status" -eq 1 ]
  [[ "$output" == "E_STAGE signals/20261018T101500Z-agent-a-abc123.md: stage: must be one of"* ]]
  [[ "$output" != *"use the gate"* ]]
}

@test "cli check: a file name filer that is not the slug of filed_by is E_SIGNAL" {
  wsig 20261018T101500Z-agent-b-abc123.md agent-a wip
  kcheck
  [ "$status" -eq 1 ]
  [ "$output" = "E_SIGNAL signals/20261018T101500Z-agent-b-abc123.md: file name filer does not match filed_by" ]
}

@test "cli check: findings are sorted by path and done/ signals are checked" {
  wsig 20261018T101500Z-agent-a-abc123.md agent-a draft
  wsig 20261018T090000Z-agent-a-abc123.md agent-a draft signals/done
  kcheck
  [ "$status" -eq 1 ]
  [ "$(echo "$output" | cut -d: -f1)" = $'E_STAGE signals/20261018T101500Z-agent-a-abc123.md\nE_STAGE signals/done/20261018T090000Z-agent-a-abc123.md' ]
}

@test "cli check: PATH arguments check only those files" {
  wsig 20261018T101500Z-agent-a-abc123.md agent-a draft
  wsig 20261018T101600Z-agent-a-abc123.md agent-a wip
  kcheck signals/20261018T101600Z-agent-a-abc123.md
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  kcheck "$BATS_TEST_TMPDIR/proj/signals/20261018T101500Z-agent-a-abc123.md"
  [ "$status" -eq 1 ]
  [[ "$output" == "E_STAGE signals/20261018T101500Z-agent-a-abc123.md:"* ]]
}

@test "cli check: a signal changed in a later commit is E_EDITED and exits 1" {
  gproj
  wsig 20261018T101500Z-agent-a-abc123.md agent-a wip
  gcommit add
  printf 'changed\n' >>"$BATS_TEST_TMPDIR/proj/signals/20261018T101500Z-agent-a-abc123.md"
  gcommit edit
  kcheck_raw
  [ "$status" -eq 1 ]
  [[ "$output" == "E_EDITED signals/20261018T101500Z-agent-a-abc123.md: "* ]]
}

@test "cli check: an uncommitted working tree change to a signal is E_EDITED" {
  gproj
  wsig 20261018T101500Z-agent-a-abc123.md agent-a wip
  gcommit add
  printf 'changed\n' >>"$BATS_TEST_TMPDIR/proj/signals/20261018T101500Z-agent-a-abc123.md"
  kcheck_raw
  [ "$status" -eq 1 ]
  [[ "$output" == "E_EDITED signals/20261018T101500Z-agent-a-abc123.md: "* ]]
}

@test "cli check: a staged change to a signal is E_EDITED" {
  gproj
  wsig 20261018T101500Z-agent-a-abc123.md agent-a wip
  gcommit add
  printf 'changed\n' >>"$BATS_TEST_TMPDIR/proj/signals/20261018T101500Z-agent-a-abc123.md"
  git -C "$BATS_TEST_TMPDIR/proj" add -A
  kcheck_raw
  [ "$status" -eq 1 ]
  [[ "$output" == "E_EDITED signals/20261018T101500Z-agent-a-abc123.md: "* ]]
}

@test "cli check: an unchanged committed signal is clean" {
  gproj
  wsig 20261018T101500Z-agent-a-abc123.md agent-a wip
  gcommit add
  kcheck_raw
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "cli check: moving a signal to done/ unchanged is not an edit" {
  gproj
  wsig 20261018T101500Z-agent-a-abc123.md agent-a wip
  gcommit add
  mkdir -p "$BATS_TEST_TMPDIR/proj/signals/done"
  git -C "$BATS_TEST_TMPDIR/proj" mv signals/20261018T101500Z-agent-a-abc123.md signals/done/
  gcommit sweep
  kcheck_raw
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "cli check: a signal never committed is clean" {
  gproj
  wsig 20261018T101500Z-agent-a-abc123.md agent-a wip
  kcheck_raw
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "cli check: outside a git repository it prints one notice, still checks, and exits 0" {
  # The ceiling stops git finding a repository above the temp dir.
  export GIT_CEILING_DIRECTORIES="$BATS_TEST_TMPDIR"
  wsig 20261018T101500Z-agent-a-abc123.md agent-a wip
  wsig 20261018T101600Z-agent-a-abc123.md agent-a wip
  kcheck_raw
  [ "$status" -eq 0 ]
  [[ "$output" == "notice:"* ]]
  [ "$(echo "$output" | wc -l)" -eq 1 ]
  # The other rules still apply.
  wsig 20261018T101700Z-agent-a-abc123.md agent-a draft
  kcheck_raw
  [ "$status" -eq 1 ]
  [[ "$output" == *"E_STAGE signals/20261018T101700Z-agent-a-abc123.md:"* ]]
}

@test "cli check: an unreadable or missing file exits 2, names the file and prints no finding" {
  wsig 20261018T101500Z-agent-a-abc123.md agent-a draft
  wsig 20261018T101600Z-agent-a-abc123.md agent-a wip
  chmod 000 "$BATS_TEST_TMPDIR/proj/signals/20261018T101600Z-agent-a-abc123.md"
  # root reads through mode 000, so the unreadable case cannot be built there.
  if [ ! -r "$BATS_TEST_TMPDIR/proj/signals/20261018T101600Z-agent-a-abc123.md" ]; then
    kcheck
    [ "$status" -eq 2 ]
    [ "$output" = "knowledge.py: E_READ cannot read signals/20261018T101600Z-agent-a-abc123.md" ]
  fi
  kcheck signals/20261018T101700Z-agent-a-abc123.md
  [ "$status" -eq 2 ]
  [[ "$output" == *"E_READ cannot read signals/20261018T101700Z-agent-a-abc123.md" ]]
}

# ptree <python expr> — entries in the temp project. put(dir, claim, name=None, **over) writes a
# rendered entry into knowledge/<dir>/ (over overrides fields, e.g. stage=, supersedes=) and
# returns its id; edit(dir, old, new) rewrites the text of every file in a dir (to make entries
# render_entry would refuse); T() is the check_tree findings, one formatted line each.
ptree() {
  python3 -I -c '
import os, sys
sys.path.insert(0, sys.argv[1] + "/scripts")
import knowledge

ROOT = sys.argv[3]

def put(d, claim="use the gate", name=None, **over):
    h = knowledge.claim_hash(claim)
    f = {"id": "K-" + h[:8], "claim": claim, "claim_hash": h, "stage": "provisional",
         "created": "2026-10-18", "updated": "2026-10-19"}
    f.update(over)
    ev = [{"signal": "20261018T101500Z-agent-1-abc123.md", "filed_by": "agent-1",
           "stage": "provisional", "warrant": "ran bats"}]
    os.makedirs(os.path.join(ROOT, "knowledge", d), exist_ok=True)
    name = name or "%s-%s.md" % (f["id"], knowledge.slug(claim))
    with open(os.path.join(ROOT, "knowledge", d, name), "w") as fh:
        fh.write(knowledge.render_entry(f, ev))
    return f["id"]

def edit(d, old, new):
    for n in os.listdir(os.path.join(ROOT, "knowledge", d)):
        p = os.path.join(ROOT, "knowledge", d, n)
        with open(p) as fh:
            text = fh.read()
        with open(p, "w") as fh:
            fh.write(text.replace(old, new))

def T():
    return "\n".join(knowledge.format_finding(f) for f in knowledge.check_tree(ROOT))

try:
    r = eval(sys.argv[2])
    print("ok" if r is None else r)
except knowledge.KnowledgeError as e:
    print(e.code, e)
' "$REPO_ROOT" "$1" "$BATS_TEST_TMPDIR/proj"
}

@test "check_tree: a tree with no signals/ or knowledge/ has no findings" {
  mkdir -p "$BATS_TEST_TMPDIR/proj"
  run ptree 'T()'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "check_tree: a valid entry in provisional/ is clean" {
  run ptree '(put("provisional"), T())[-1]'
  [ -z "$output" ]
}

@test "check_tree: stage canonical in established/ is E_STAGE naming the file" {
  run ptree '(put("established", stage="canonical"), T())[-1]'
  [[ "$output" == "E_STAGE knowledge/established/K-"*"-use-the-gate.md: "* ]]
  [ "$(echo "$output" | wc -l)" -eq 1 ]
}

@test "check_tree: stage canonical is clean in canon/, stage established there is E_STAGE" {
  run ptree '(put("canon", stage="canonical"), T())[-1]'
  [ -z "$output" ]
  run ptree '(put("canon", "another claim", stage="established"), T())[-1]'
  [[ "$output" == "E_STAGE knowledge/canon/K-"*"-another-claim.md: "* ]]
}

@test "check_tree: stage draft is E_STAGE" {
  run ptree '(put("provisional"), edit("provisional", "stage: provisional", "stage: draft"), T())[-1]'
  [[ "$output" == "E_STAGE knowledge/provisional/K-"*"-use-the-gate.md: "* ]]
}

@test "check_tree: superseded_by without the reverse supersedes is E_ENTRY on the old entry" {
  run ptree '(put("superseded", "old claim", stage="superseded", superseded_by=knowledge.entry_id("new claim")), put("provisional", "new claim"), T())[-1]'
  [[ "$output" == "E_ENTRY knowledge/superseded/K-"*"-old-claim.md: superseded_by: K-"* ]]
  [ "$(echo "$output" | wc -l)" -eq 1 ]
}

@test "check_tree: a proper supersede pair is clean" {
  run ptree '(put("superseded", "old claim", stage="superseded", superseded_by=knowledge.entry_id("new claim")), put("provisional", "new claim", supersedes=knowledge.entry_id("old claim")), T())[-1]'
  [ -z "$output" ]
}

@test "check_tree: supersedes pointing at an entry outside superseded/ is E_ENTRY" {
  run ptree '(put("established", "old claim", stage="established", superseded_by=knowledge.entry_id("new claim")), put("provisional", "new claim", supersedes=knowledge.entry_id("old claim")), T())[-1]'
  [[ "$output" == "E_ENTRY knowledge/provisional/K-"*"-new-claim.md: supersedes: K-"*"not in knowledge/superseded/" ]]
}

@test "check_tree: supersedes pointing at a missing entry is E_ADDR" {
  run ptree '(put("provisional", supersedes="K-00000000"), T())[-1]'
  [[ "$output" == "E_ADDR knowledge/provisional/K-"*"-use-the-gate.md: supersedes: "* ]]
}

@test "check_tree: a file name whose hash does not match id is E_ENTRY" {
  run ptree '(put("provisional", name="K-00000000-use-the-gate.md"), T())[-1]'
  [[ "$output" == "E_ENTRY knowledge/provisional/K-00000000-use-the-gate.md: file name does not match"* ]]
}

@test "cli check: a bad entry and a bad signal are both printed, sorted by path" {
  wsig 20261018T101500Z-agent-a-abc123.md agent-a draft
  run ptree 'put("established", stage="canonical")'
  kcheck
  [ "$status" -eq 1 ]
  [ "$(echo "$output" | cut -d: -f1 | cut -d/ -f1)" = $'E_STAGE knowledge\nE_STAGE signals' ]
}

# kaddr <args...> — `check --address ...` against the temp project, stdout and stderr apart.
kaddr() {
  run --separate-stderr python3 -I "$REPO_ROOT/scripts/knowledge.py" check --root "$BATS_TEST_TMPDIR/proj" "$@"
}

@test "cli check --address: K-hash8 prints the path on stdout, exit 0" {
  run ptree 'put("provisional")'
  kaddr --address "$(python3 -I -c 'import sys; sys.path.insert(0, sys.argv[1] + "/scripts"); import knowledge; print(knowledge.entry_id("use the gate"))' "$REPO_ROOT")"
  [ "$status" -eq 0 ]
  [[ "$output" == "knowledge/provisional/K-"*"-use-the-gate.md" ]]
  [ -z "$stderr" ]
}

@test "cli check --address: K-hash8#evidence still resolves after the entry moves to established" {
  run ptree 'put("provisional")'
  id=$(python3 -I -c 'import sys; sys.path.insert(0, sys.argv[1] + "/scripts"); import knowledge; print(knowledge.entry_id("use the gate"))' "$REPO_ROOT")
  kaddr --address "$id#evidence"
  [ "$status" -eq 0 ]
  [[ "$output" == "knowledge/provisional/K-"*"-use-the-gate.md#evidence" ]]
  mkdir -p "$BATS_TEST_TMPDIR/proj/knowledge/established"
  mv "$BATS_TEST_TMPDIR"/proj/knowledge/provisional/K-*.md "$BATS_TEST_TMPDIR/proj/knowledge/established/"
  kaddr --address "$id#evidence"
  [ "$status" -eq 0 ]
  [[ "$output" == "knowledge/established/K-"*"-use-the-gate.md#evidence" ]]
}

@test "cli check --address: a slug that is not a heading exits 1, reason on stderr" {
  run ptree 'put("provisional")'
  kaddr --address "$(python3 -I -c 'import sys; sys.path.insert(0, sys.argv[1] + "/scripts"); import knowledge; print(knowledge.entry_id("use the gate"))' "$REPO_ROOT")#notes"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  [[ "$stderr" == *"no heading notes"* ]]
}

@test "cli check --address: two files with one id exit 1 and stderr names both" {
  run ptree '(put("provisional"), put("established", name=knowledge.entry_id("use the gate") + "-copy.md"))'
  kaddr --address "$(python3 -I -c 'import sys; sys.path.insert(0, sys.argv[1] + "/scripts"); import knowledge; print(knowledge.entry_id("use the gate"))' "$REPO_ROOT")"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  [[ "$stderr" == *"knowledge/established/K-"*"-copy.md"* ]]
  [[ "$stderr" == *"knowledge/provisional/K-"*"-use-the-gate.md"* ]]
}

@test "cli check --address: an unknown id exits 1" {
  mkdir -p "$BATS_TEST_TMPDIR/proj"
  kaddr --address K-00000000
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  [[ "$stderr" == *"no entry matches K-00000000"* ]]
}

@test "cli check --address: combined with a PATH argument exits 2" {
  mkdir -p "$BATS_TEST_TMPDIR/proj"
  kaddr --address K-00000000 somefile
  [ "$status" -eq 2 ]
  [ -z "$output" ]
}

@test "cli check: writes nothing, tracked or untracked" {
  gproj
  wsig 20261018T101500Z-agent-a-abc123.md agent-a wip
  run ptree 'put("provisional")'
  gcommit add
  run ptree 'put("established", "second claim", stage="canonical")'
  before=$(git -C "$BATS_TEST_TMPDIR/proj" status --porcelain)
  kcheck_raw
  [ "$status" -eq 1 ]
  [ "$(git -C "$BATS_TEST_TMPDIR/proj" status --porcelain)" = "$before" ]
}

