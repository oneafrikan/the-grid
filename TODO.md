# the-grid TODO

## Immediate
- [ ] Write README.md — explain the concept, directory structure, and how to bootstrap on a new machine
- [ ] Write CLAUDE.md — context for future sessions picking this repo up
- [ ] Push to GitHub (gkwilderness account)

## Bootstrap
- [ ] Add bootstrap script (`bootstrap.sh`) — clone the-grid, init submodules, run wire.sh in one command
- [ ] Document the one-liner for new machine setup in README

## Skills
- [ ] Identify which existing skills in `~/.claude/skills/` should move into the-grid
- [ ] Add sibling skill repos as submodules under `repos/` (e.g. gstack, gbrain)
- [ ] Wire those repos and confirm tests stay green

## Ops
- [ ] Add `check-grid.sh` — runs the bats test suite and reports broken symlinks (quick health check without full bats output)
- [ ] Consider a git hook: run tests before commit so bad skill format never lands in main
