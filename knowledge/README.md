# knowledge/

Claims this project has recorded, grouped by stage. Entries below canon are read on demand only.

## Layout

- `knowledge/<stage>/`: one file per entry, in the folder for its stage (`wip`, `provisional`, `established`, and so on).
- `knowledge/canon/`: canonical entries only. Added by a human PR. `scripts/map.py` lists their claims in `MAP.md`.

## Entry keys

`scripts/map.py` reads two frontmatter keys and nothing else:

- `claim`: the one-line claim. Used for the canon lines in `MAP.md`.
- `stage`: used only by `python3 scripts/map.py status` for the counts.

## Rules

- Entries stay in this project's own repo. No secrets or personal data.
- Sweep: none configured. No sweep runs, so nothing moves into `knowledge/` automatically yet.
- Stages and the warrant rule are restated in `signals/README.md`.
