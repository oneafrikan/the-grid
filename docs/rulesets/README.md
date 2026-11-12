# Ruleset backups

Backups of the `main-protected` GitHub ruleset on `oneafrikan/the-grid` (ruleset id 25353976).

- `main-protected.json`: the ruleset as it is live after CI was stripped to the `gate` job.
- `main-protected.pre-strip.json`: the ruleset before that change. It still carries read-only fields (id, node_id, _links, created_at, updated_at, source, source_type, current_user_can_bypass); remove them before a PUT or the body is rejected.
- Restore: `GH_TOKEN=$(gh auth token --user oneafrikan) gh api -X PUT repos/oneafrikan/the-grid/rulesets/25353976 --input docs/rulesets/<file>`
