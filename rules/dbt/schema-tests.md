---
paths:
  - "**/models/**/*.yml"
  - "**/models/**/*.yaml"
  - "**/seeds/**/*.yml"
  - "**/seeds/**/*.yaml"
---
# dbt properties and tests

- Use the `data_tests:` key; `tests:` is a legacy alias and both cannot appear on one resource.
- When testing a foreign key, use `relationships` with `to: ref('<model>')` and `field`.
- Nest generic test inputs (`values`, `to`, `field`) under `arguments:`; put `severity`, `where` and `store_failures` under `config:`.
- Set `warn_if` and `error_if` to give a test a failure threshold.
- Set `freshness` with `warn_after` and `error_after`, each with `count` and `period`; one without the other errors at `dbt freshness`.
- Set `loaded_at_field` on BigQuery sources with wildcard tables (`events_*`); metadata freshness checks are unreliable there.
