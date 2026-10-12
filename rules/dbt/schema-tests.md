---
paths:
  - "**/models/**/*.yml"
  - "**/models/**/*.yaml"
  - "**/seeds/**/*.yml"
  - "**/seeds/**/*.yaml"
---
# dbt properties and tests

- Use the `data_tests:` key (renamed from `tests:`; older dbt versions need `tests:`); both cannot appear on one resource.
- When testing a foreign key, use `relationships` with `to: ref('<model>')` and `field`.
- On dbt 1.10.5 and later, nest generic test inputs (`values`, `to`, `field`) under `arguments:` (older versions use top-level properties; v2 requires `arguments:`); put `severity`, `where` and `store_failures` under `config:`.
- Set `warn_if` and `error_if` to give a test a failure threshold.
- Set `freshness` with `warn_after` and `error_after`, each with `count` and `period`; one without the other errors at `dbt freshness`.
- Set `loaded_at_field` on BigQuery sources with wildcard tables (`events_*`); metadata freshness checks are unreliable there.
- Omit the `+` prefix in `config:` blocks of property files; it belongs only in `dbt_project.yml`.
