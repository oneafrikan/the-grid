## What and why

<!-- One or two lines. Link the issue or work package. -->

## Checks

- [ ] `bash scripts/gate.sh` passes.
- [ ] If you ran `bash scripts/compose-goldens.sh --update`: you read the diff of every changed
      file under `tests/fixtures/compose/golden/` and each change is intended. `--update`
      blesses whatever the emitters produce, so the diff review is the only check.
- [ ] Generated files (goldens, `plugins/`, `dist/personas/`) were regenerated with their scripts, never edited by hand.
