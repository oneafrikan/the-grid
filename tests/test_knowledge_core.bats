#!/usr/bin/env bats
# scripts/knowledge.py core helpers (change `knowledge-signals`): claim hash, entry id,
# slug, warrant rule and stage ceiling. Pure functions: no files are written.

load helpers/setup

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
