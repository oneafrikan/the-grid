#!/usr/bin/env bash
# hooks/lib/transcript-digest.sh <transcript> <out-file> <max-bytes>
#
# Turns a Claude Code JSONL transcript into a compact markdown digest for the
# auto-handoff child to read (executed by hooks/lib/auto-handoff-worker.sh, never
# sourced).
#
# Kept, in order:
#   - human user messages            "## User" + text
#   - assistant text blocks          "## Assistant" + text
#   - tool_use blocks, one line each "tool: <name> <first 200 chars of the input JSON>"
# Dropped: tool_result bodies (megabytes of output), meta lines, sidechain
# (subagent) lines, attachments, anything else.
#
# Over the cap the middle is elided with a one-line marker; the first and last human
# turns are always kept (each cut to at most max/16 characters if huge), then the
# remaining budget is split between the start and the end of the session.
# Sizes are counted in bytes (utf8), so the digest stays within the cap plus one
# marker per elided gap.
#
# Transcript key contract (design.md): type, isMeta, isSidechain, message.content
# (string, or blocks text / tool_use / tool_result).
#
# Exit 0 on success; 2 on bad arguments or an unreadable transcript.

transcript="${1:-}" out="${2:-}" max="${3:-}"
if [ -z "$transcript" ] || [ -z "$out" ] || ! [[ "$max" =~ ^[0-9]+$ ]] || [ ! -r "$transcript" ]; then
  echo "usage: transcript-digest.sh <transcript> <out-file> <max-bytes>" >&2
  exit 2
fi

# The prefilter shared (by copy) with the worker: lines that are not valid JSON
# (a truncated last line must not break parsing) and sidechain lines are dropped.
jq -R -c 'fromjson? | select(type == "object" and .isSidechain != true)' "$transcript" \
  | jq -r -n --argjson cap "$max" '
  # byte length of a string once encoded as UTF-8
  def blen: explode | map(if . < 128 then 1 elif . < 2048 then 2 elif . < 65536 then 3 else 4 end) | add // 0;
  # text of a content value: a string, or the joined text blocks of an array
  # Every message is cut to $cap + 1 characters BEFORE it is measured: blen explodes a string
  # into one number per character (about 47 bytes each), so a single 20 MB message needed
  # roughly a gigabyte. One character over the cap still tells the cap logic the entry is
  # too big (and the first and last human turns are cut to cap/16 later anyway).
  def texts: if type == "string" then .[0:$cap + 1]
             elif type == "array" then [.[] | select(type == "object" and .type == "text") | (.text // "") | .[0:$cap + 1]] | join("\n") | .[0:$cap + 1]
             else "" end;
  # a human turn: non-meta user line, non-empty string, or text blocks with no tool_result
  def human: .type == "user" and (.isMeta != true)
             and (.message.content
                  | if type == "string" then length > 0
                    elif type == "array" then (any(.[]; type == "object" and .type == "text")
                                               and (any(.[]; type == "object" and .type == "tool_result") | not))
                    else false end);
  [ inputs
    | if human then {h: true, s: ("## User\n" + (.message.content | texts))}
      elif .type == "assistant" then
        (.message.content // []) | if type == "array" then
          .[] | select(type == "object")
              | if .type == "text" then {h: false, s: ("## Assistant\n" + ((.text // "") | .[0:$cap + 1]))}
                elif .type == "tool_use" then {h: false, s: ("tool: " + (.name // "?") + " " + ((.input // {}) | tojson | .[0:200]))}
                else empty end
          else empty end
      else empty end
  ] as $e0
  | ($e0 | map(.b = (.s | blen) + 2)) as $e
  | ($e | map(.b) | add // 0) as $total
  | if $total <= $cap then ($e | map(.s) | join("\n\n"))
    else
      "\n[... middle of the session elided to fit the size cap ...]\n" as $marker
      | ($marker | blen) as $mb
      # first and last human turn, truncated so even 4-byte characters stay within cap/4
      | ($e | to_entries | map(select(.value.h) | .key)) as $hs
      | ($hs | if length > 0 then [first, last] | unique else [] end) as $must
      | ($cap / 16 | floor) as $trunc
      | ($e | to_entries | map(
          if (.key as $k | $must | index($k)) != null and .value.b > ($cap / 4)
          then .value.s = (.value.s[0:$trunc]) | .value.b = (.value.s | blen) + 2
          else . end) | map(.value)) as $e2
      | ($must | map($e2[.].b) | add // 0) as $reserved
      | ([$cap - $reserved - ($mb * 4), 0] | max) as $rest
      | ($rest / 2 | floor) as $hb
      | ($rest - $hb) as $tb
      # head: ascending, take what fits; tail: descending, take what fits
      | (reduce range(0; $e2 | length) as $i ({used: 0, keep: []};
           if ($must | index($i)) != null then .
           elif .used + $e2[$i].b <= $hb then .used += $e2[$i].b | .keep += [$i]
           else . end) | .keep) as $head
      | (reduce range(($e2 | length) - 1; -1; -1) as $i ({used: 0, keep: []};
           if ($must | index($i)) != null or ($head | index($i)) != null then .
           elif .used + $e2[$i].b <= $tb then .used += $e2[$i].b | .keep += [$i]
           else . end) | .keep) as $tail
      | ($head + $tail + $must | unique) as $keep
      # emit kept entries in order, one marker per gap
      | (reduce $keep[] as $i ({prev: -1, out: []};
           (if $i > .prev + 1 then [$marker] else [] end) as $gap
           | .out += $gap + [$e2[$i].s] | .prev = $i)) as $r
      | ($r.out
         + (if ($keep | length) > 0 and $keep[-1] < (($e2 | length) - 1) then [$marker] else [] end)
         | join("\n\n"))
    end
' > "$out"
