# Grid extras (only if the operator chose them)

`--grid` added: BEHAVIOUR.md, LEARNINGS.md, SPECS.md, AGENTS-SETUP.md, `.grid/project.yaml`,
`signals/`, `knowledge/` (with `scripts/knowledge.py`), `handoffs/`, the `project-review`
skill under `.claude/skills/`, `.githooks/pre-commit` and the opt-in `loop/` seed.
The grid checkout is the directory that holds `project-factory/` and `agent-factory/`.
The deploy tools need `agent-factory/.venv`; if it is missing, tell the operator the
setup command from the grid's CLAUDE.md and wait. Do not build it silently.

1. Roles. State the command, then run it and read the list:

   ```bash
   <grid>/agent-factory/.venv/bin/python <grid>/agent-factory/deploy.py --list
   ```

   Recommend a lean set that fits the stack the operator gave (for example a Python
   service: backend-dev, sdet, qa-engineer, technical-writer; use only names `--list` printed), name each role and why, and ask
   for a yes. Roles the operator did not agree to are not deployed.
2. Deploy. State the command, then run it (lean is the default profile):

   ```bash
   <grid>/agent-factory/.venv/bin/python <grid>/agent-factory/deploy.py <target-dir> --roles a,b,c
   ```

   Generated files carry a marker: never hand-edit them.
3. `AGENTS.md` (scaffold it with `--with agents` if absent): list each deployed role,
   what it owns in THIS project, and the conventions it must follow. Take ownership
   and conventions from the operator's answers and the existing code, not from the
   role's own description.
4. `.grid/project.yaml`: set `context:` to the run and test commands and the hard
   invariants the operator gave (uncomment and fill the block; add nothing else).
   Set `hooks: {profile: standard}` and `target: local`. Then, stating it first:

   ```bash
   <grid>/agent-factory/.venv/bin/python <grid>/agent-factory/deploy_hooks.py <target-dir>
   ```

   Re-run step 2's command after editing `context:` so the agents pick it up.
5. `.claude/skills/project-review/SKILL.md`: fill its invariant markers only from the
   operator's must-nots. Leave the rest.
6. Add the grid files to the `CLAUDE.md` read-when table: `BEHAVIOUR.md` (before
   acting), `SPECS.md` (before non-trivial code), `signals/README.md` (before
   recording a claim), `AGENTS-SETUP.md` (when changing the deployed roles).
7. `loop/` stays off. Mention `loop/ENABLE.md` in the report; do not configure it.
