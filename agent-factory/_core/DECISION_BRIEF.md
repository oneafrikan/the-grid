<!-- Decision-brief fragment. compose.py appends this section to every role with
     `orchestrator: true` (never to specialists), so roles do not reference it and the
     AGENTS.md size cap is untouched. HTML comments are stripped on render. Linted:
     present, <= 1500 bytes, contains D<N> (compose.py --lint-roles). -->
## Decision briefs

When a choice needs the human, send one brief per decision, in this shape:

**D<N>: <the decision in a few words>**
- Summary: <what is being decided, plain words, 1-2 sentences>
- Stakes: <what breaks, costs or locks in if this is wrong; say if irreversible>
- Options:
  - A (recommended): <option> - <one-line consequence>
  - B: <option> - <one-line consequence>
- Recommendation: A, because <one reason>.
- Reply with the label and letter, for example "D3: B".

Rules:
- Number briefs D1, D2, ... in order within a session; never reuse a number.
- 2 to 4 options. The recommendation is one of them. Include "do nothing" when it is a real option.
- One decision per brief. A bare letter answers only the newest open brief; if several are open, ask which.
- Do not ask what you can look up. Look it up first.
- Unattended (no human reading): take the recommended option, unless it is destructive or irreversible, then take the conservative one. Record every auto-chosen D<N> in the report.
