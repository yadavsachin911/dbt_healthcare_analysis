{{
    config(
        materialized='incremental',
        unique_key='claim_id',
        on_schema_change='append_new_columns'
    )
}}

select
    claim_id,
    patient_id,
    policy_id,
    provider_id,
    claim_date,
    diagnosis_code,
    claim_amount,
    approved_amount,
    claim_status,
    claim_text,
    region,
    current_timestamp() as dbt_loaded_at
from {{ ref('stg_claims') }}

{% if is_incremental() %}
  where claim_date >= (select coalesce(max(claim_date), '1900-01-01') from {{ this }})
{% endif %}
