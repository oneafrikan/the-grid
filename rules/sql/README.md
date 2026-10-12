# sql

Warehouse-first SQL conventions (BigQuery/GoogleSQL), plus safety rules for parameterised
queries and DML. Not tuned for MySQL/Postgres OLTP. Loads on every `*.sql` file, so
bullets that name BigQuery apply to that dialect only; a glob cannot tell dialects apart.

## Sources

| Rule file | Source |
|---|---|
| style.md | https://docs.getdbt.com/best-practices/how-we-style/2-how-we-style-our-sql |
| bigquery.md | https://docs.cloud.google.com/bigquery/docs/best-practices-performance-compute https://docs.cloud.google.com/bigquery/docs/best-practices-costs https://docs.cloud.google.com/bigquery/docs/querying-partitioned-tables https://docs.cloud.google.com/bigquery/docs/managing-partitioned-tables |
| safety.md | https://docs.cloud.google.com/bigquery/docs/parameterized-queries https://docs.cloud.google.com/bigquery/docs/reference/standard-sql/dml-syntax https://docs.cloud.google.com/bigquery/docs/data-manipulation-language |

URLs on the `cloud.google.com` host answer with a 301 to `docs.cloud.google.com`; the
redirect target is recorded here.
