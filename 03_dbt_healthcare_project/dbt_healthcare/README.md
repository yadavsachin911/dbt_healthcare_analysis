# healthcare_analytics (dbt project)

Manages the Gold layer transformations (fact_claims, gold_claim_insights) on top
of the Silver Dynamic Tables already created via SQL in Snowflake.

## Local setup
1. `pip install dbt-snowflake`
2. Copy `profiles_example.yml` to `~/.dbt/profiles.yml` and fill in real values
   (or export SNOWFLAKE_ACCOUNT / SNOWFLAKE_USER / SNOWFLAKE_PASSWORD as env vars).
3. `dbt debug` — confirms the connection works.
4. `dbt run` — builds the models.
5. `dbt test` — runs the schema tests (uniqueness, not-null, accepted values).

## CI/CD
`.github/workflows/dbt_ci.yml` runs `dbt run` + `dbt test` automatically on every
push to `main` and on pull requests. Add these repo secrets in
GitHub → Settings → Secrets and variables → Actions:
- `SNOWFLAKE_ACCOUNT`
- `SNOWFLAKE_USER`
- `SNOWFLAKE_PASSWORD`

## Structure
- `models/staging/` — thin renaming layer on top of Silver sources
- `models/marts/` — business-facing Gold tables/views (fact_claims, gold_claim_insights)
- `models/marts/schema.yml` — data quality tests
