# Grid extras (only if the operator chose them)

"Default yes" means offer them, nothing more. Every state-changing command below
(`deploy.py`, `deploy_hooks.py`, anything that writes under `.claude/`) is stated
first and run only after an explicit yes from the operator. An unanswered question
never runs them. Run nothing that sends data off the machine.

`--grid` added: BEHAVIOUR.md, LEARNINGS.md, SPECS.md, AGENTS-SETUP.md, `.grid/project.yaml`,
`signals/`, `knowledge/` (with `scripts/knowledge.py`), `handoffs/`, the `project-review`
skill under `.claude/skills/`, `.githooks/pre-commit` and the opt-in `loop/` seed.
If `learnings` was also chosen, the grid `LEARNINGS.md` replaces the unedited generic one (no
`SKIPPED` line); do not fill it. The grid checkout is the directory that holds `project-factory/` and `agent-factory/`.
The deploy tools need `agent-factory/.venv`; if it is missing, tell the operator the
setup command from the grid's CLAUDE.md and wait. Do not build it silently.

1. Roles. State the command, then run it (read-only) and read the list:

   ```bash
   <grid>/agent-factory/.venv/bin/python <grid>/agent-factory/deploy.py --list
   ```

   Recommend a lean set that fits the stack the operator gave (for example a Python
   service: backend-dev, sdet, qa-engineer, technical-writer; use only names `--list`
   printed), name each role and why, and ask for a yes. Roles the operator did not
   agree to are not deployed.
2. Deploy, after that yes. State the command, then run it (lean is the default profile):

   ```bash
   <grid>/agent-factory/.venv/bin/python <grid>/agent-factory/deploy.py <target-dir> --roles a,b,c
   ```

   Generated files carry a marker: never hand-edit them.
3. `AGENTS.md` (scaffold it with `--with agents` if absent): list each deployed role,
   what it owns in THIS project, and the conventions it must follow. Take ownership
   and conventions from the operator's answers and the existing code, not from the
   role's own description.
4. `.grid/project.yaml`: deploy.py injects `context:` verbatim into every deployed
   agent prompt, so it holds facts only. Uncomment `context:` and keep only the lines
   for which the operator gave a fact (run command, test command, hard invariants).
   Delete every other example line. Never leave a `<command>` or `<e.g. ...>`
   placeholder in it.
   Propose `hooks: {profile: standard}` with `target: local` (machine-local, the default).
   After a yes, state and run:

   ```bash
   <grid>/agent-factory/.venv/bin/python <grid>/agent-factory/deploy_hooks.py <target-dir>
   ```

   Re-run step 2's command after editing `context:` (also after a yes) so the agents pick it up.
5. `.claude/skills/project-review/SKILL.md`: fill its invariant markers only from the
   operator's must-nots. Leave the rest.
6. `CLAUDE.md` read-when rows: add one row for every grid file or directory that
   exists: `BEHAVIOUR.md` (before acting), `SPECS.md` (before non-trivial code),
   `AGENTS-SETUP.md` (when changing the deployed roles), `signals/README.md` (before
   recording a claim), `LEARNINGS.md` (to read lessons mined from past work),
   `knowledge/README.md` (before filing or reading knowledge entries),
   `handoffs/` (at session start and end), `.grid/project.yaml` (when changing facts
   given to deployed agents), `loop/ENABLE.md` (before enabling the issue loop).
   If `CLAUDE.md` was SKIPPED (exists, differs), do not edit it: give the operator
   the rows as a paste-ready patch instead.
7. `loop/` stays off. Mention `loop/ENABLE.md` in the report; do not configure it.
