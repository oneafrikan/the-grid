# dbt

dbt project conventions: layers, model naming, incremental pitfalls, properties and tests,
project config. Generic SQL rules live in the `sql` pack, which also loads on every model
file.

## Scope

- The globs cannot test for `dbt_project.yml`, so they match by directory name only.
- `models.md` loads on any `.sql` under a `models/` directory, so it also loads on SQLMesh
  models. It does not load on snapshots, macros, analyses, tests or Python models.
- `schema-tests.md` loads on any `.yml`/`.yaml` under a `models/` or `seeds/` directory, so
  ML or API configs (`ml/models/...`, `config/models/openapi.yml`) and Rails `db/seeds/*.yml`
  can match. It does not load on properties YAML under `snapshots/`, `macros/`, `analyses/`,
  `tests/` or a custom `model-paths`.
- Widening the globs to those directories would add more false loads, so the limits are
  documented instead.

## Versions

Bullets name the dbt version they need where the cited page gives one (for example
`arguments:` under generic tests needs 1.10.5). The `data_tests:` rename has no version
on the cited page, so that bullet says only that older dbt versions need `tests:`.

## Sources

| Rule file | Source |
|---|---|
| models.md | https://docs.getdbt.com/reference/dbt_project.yml https://docs.getdbt.com/best-practices/best-practice-workflows https://docs.getdbt.com/best-practices/how-we-structure/2-staging https://docs.getdbt.com/best-practices/how-we-structure/4-marts https://docs.getdbt.com/best-practices/how-we-style/1-how-we-style-our-dbt-models https://docs.getdbt.com/docs/build/incremental-models |
| schema-tests.md | https://docs.getdbt.com/reference/dbt_project.yml https://docs.getdbt.com/docs/build/data-tests https://docs.getdbt.com/reference/resource-configs/freshness |
| project.md | https://docs.getdbt.com/reference/dbt_project.yml https://docs.getdbt.com/best-practices/how-we-style/2-how-we-style-our-sql https://docs.getdbt.com/best-practices/best-practice-workflows https://docs.getdbt.com/best-practices/how-we-structure/2-staging https://docs.getdbt.com/best-practices/how-we-structure/3-intermediate |
