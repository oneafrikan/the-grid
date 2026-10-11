## Adopting it in a repo

**`openspec init` is optional.** `openspec new change` creates
`openspec/{specs,changes,archive}` + `config.yaml` on its own, so the skills
work in a repo that has never been initialised. What `init` adds is
project-local `.claude/` copies of six skills plus `/opsx:*` commands —
redundant here, since the-grid already wires all 12 globally.

**Greenfield:** just `/openspec-propose`. Optionally `/openspec-onboard` first.

**Brownfield:** the code is already the truth — don't back-fill specs for all
of it. Write specs only for the capability you're about to change, as part of
the first change that touches it. `openspec/specs/` then grows to cover the
codebase incrementally, driven by real work. A big-bang spec-writing exercise
produces documentation nobody trusts and nothing verifies.
