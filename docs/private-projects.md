# Private projects

Not everything belongs in a public repo. `agent-factory` can compose a project
whose **roles and compose config live entirely outside this repo**, via
`GRID_PRIVATE_ROLES_DIR` (see `compose.py`'s `role_dir()`), gated by a
`project:<name>` entry in `machines/<host>.local.txt` — which is gitignored, so
even the gate stays out of git history.

Composed output lands in the same `agent-factory/projects/` as everything else
and wires identically. Nothing about the mechanism is private; only the content
is. That separation is the point — fork this repo and your own private desk
never touches its history.

> ⚠ `compose.py` **overwrites** `projects/<name>/` wholesale. Recomposing the
> public projects while a private project's roles are unreachable destroys that
> project's composed output, and the next `wire.sh` removes its symlinks. Check
> `machines/<host>.local.txt` against `ls agent-factory/projects/` before
> recomposing.
