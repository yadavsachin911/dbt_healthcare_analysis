-- Thin staging layer: light renaming/typing only, no business logic.
-- Sits on top of the Silver Dynamic Table (which already did JSON flattening).

with source as (
    select * from {{ source('silver', 'silver_claims') }}
),

renamed as (
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
        region
    from source
)

select * from renamed
