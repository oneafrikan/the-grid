---
paths:
  - "**/dbt_project.yml"
---
# dbt project config

- Prefix configs with `+` (`+materialized`) in `dbt_project.yml` only; omit it in `config()` and property files.
- Set configs shared by a whole directory in `dbt_project.yml`, and model-specific ones in the model.
- Set staging to `+materialized: view`; use views by default and tables for models that BI tools or many descendants query.
- Switch a model to `incremental` only when its table build time exceeds an acceptable threshold.
- Set intermediate models to `ephemeral`, or views in a custom `+schema`, so they stay out of the production schema.
- Use underscores for `data_tests` and `unit_tests` keys; use dashes for `saved-queries` and `semantic-models`.
- Set `grants` in resource configs so permissions are versioned with the model.
