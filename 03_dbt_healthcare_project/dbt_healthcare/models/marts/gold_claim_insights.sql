{{ config(materialized='view') }}

-- Cortex AI enrichment over claim adjuster notes.
-- Kept as a view (not a table) since Cortex functions run at query time
-- and you generally don't want to pay for re-summarizing unchanged claims.

select
    claim_id,
    snowflake.cortex.summarize(claim_text) as executive_summary,
    snowflake.cortex.sentiment(claim_text) as customer_sentiment_score
from {{ ref('fact_claims') }}
where claim_text is not null
