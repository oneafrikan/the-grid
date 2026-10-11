Check each, cheapest first. Report only what you actually find — an empty
finding list is a good result, and saying "no drift found" is a complete answer.

- **Stale in-flight change** — `openspec/changes/<id>/tasks.md` has all boxes
  ticked but the change was never archived. Use `git log -1 --format=%ar` on the
  change directory for age. Anything ticked-and-unarchived for weeks is either
  finished-and-forgotten or abandoned; both need a human call.
- **Abandoned change** — a change folder with no commits for a long stretch and
  unticked tasks. Report the age and the last commit subject; don't guess which
  it is.
- **Requirement with no scenario** — a `### Requirement:` heading with no
  `#### Scenario:` under it. Untestable by construction — flag every instance.
- **Spec with no code** — the capability name (and the nouns in its
  requirements) appear nowhere in the source tree. Weak signal on its own:
  naming rarely matches one-to-one, so report it as a question, not a verdict.
- **Code with no spec** — a top-level source module or route group with no
  capability covering it. Expect a lot of these in a brownfield repo; that is
  the normal, intended state (`SPECS.md` says specs grow per-change). Only flag
  it for areas that changed recently — `git log --since` on the paths — because
  a *changing* area with no spec is the case actually worth raising.
- **Spec contradicted by code** — the most valuable finding and the most
  expensive. Only attempt it for capabilities the user names, or for specs whose
  files changed less recently than the code they describe. Read the requirement,
  read the implementation, and report the contradiction with both locations.
  If you can't verify it, say so rather than asserting drift.
