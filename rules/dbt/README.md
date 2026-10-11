# dbt

dbt project conventions: layers, model naming, incremental pitfalls, properties and tests,
project config. Generic SQL rules live in the `sql` pack, which also loads on every model
file.

## Sources

| Rule file | Source |
|---|---|
| models.md | https://docs.getdbt.com/best-practices/best-practice-workflows https://docs.getdbt.com/best-practices/how-we-structure/2-staging https://docs.getdbt.com/best-practices/how-we-structure/4-marts https://docs.getdbt.com/best-practices/how-we-style/1-how-we-style-our-dbt-models https://docs.getdbt.com/docs/build/incremental-models |
| schema-tests.md | https://docs.getdbt.com/docs/build/data-tests https://docs.getdbt.com/reference/resource-configs/freshness |
| project.md | https://docs.getdbt.com/reference/dbt_project.yml https://docs.getdbt.com/best-practices/how-we-style/2-how-we-style-our-sql https://docs.getdbt.com/best-practices/best-practice-workflows https://docs.getdbt.com/best-practices/how-we-structure/2-staging https://docs.getdbt.com/best-practices/how-we-structure/3-intermediate |
