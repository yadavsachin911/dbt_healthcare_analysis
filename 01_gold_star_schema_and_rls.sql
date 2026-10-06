-- ============================================================
-- GOLD LAYER: Star Schema + Row-Level Security
-- Multi-Tenant Enterprise Health & Insurance Analytics Platform
-- ============================================================
-- Run this after Phases 1-3 (warehouse, Bronze, Silver) exist.
-- Assumes a database HEALTHCARE_DB with schemas SILVER and GOLD.
-- ============================================================

USE DATABASE HEALTHCARE_DB;
CREATE SCHEMA IF NOT EXISTS GOLD;
USE SCHEMA GOLD;

-- ------------------------------------------------------------
-- 1. DIMENSION TABLES
-- ------------------------------------------------------------

CREATE OR REPLACE TABLE dim_patient (
    patient_id        STRING PRIMARY KEY,
    first_name        STRING,
    last_name         STRING,
    date_of_birth     DATE,
    gender            STRING,
    region            STRING,          -- used by the row access policy below
    enrolled_date     DATE,
    created_at        TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

CREATE OR REPLACE TABLE dim_provider (
    provider_id       STRING PRIMARY KEY,
    provider_name     STRING,
    specialty         STRING,
    npi_number        STRING,          -- national provider identifier
    region            STRING,
    created_at        TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

CREATE OR REPLACE TABLE dim_policy (
    policy_id         STRING PRIMARY KEY,
    patient_id        STRING REFERENCES dim_patient(patient_id),
    policy_type       STRING,          -- e.g. 'INDIVIDUAL', 'GROUP', 'MEDICARE_ADV'
    effective_date    DATE,
    expiration_date   DATE,
    premium_amount    NUMBER(10,2),
    region            STRING,
    created_at        TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

CREATE OR REPLACE TABLE dim_date (
    date_key          DATE PRIMARY KEY,
    year              NUMBER,
    quarter           NUMBER,
    month             NUMBER,
    month_name        STRING,
    day_of_week       STRING,
    is_weekend        BOOLEAN
);

-- ------------------------------------------------------------
-- 2. FACT TABLE
-- ------------------------------------------------------------

CREATE OR REPLACE TABLE fact_claims (
    claim_id          STRING PRIMARY KEY,
    patient_id        STRING REFERENCES dim_patient(patient_id),
    policy_id         STRING REFERENCES dim_policy(policy_id),
    provider_id       STRING REFERENCES dim_provider(provider_id),
    claim_date        DATE REFERENCES dim_date(date_key),
    diagnosis_code    STRING,          -- ICD-10
    claim_amount      NUMBER(12,2),
    approved_amount   NUMBER(12,2),
    claim_status      STRING,          -- 'SUBMITTED','APPROVED','DENIED','PAID'
    claim_text        STRING,          -- free-text adjuster notes, feeds Cortex AI view
    region            STRING,          -- denormalized for row access policy performance
    created_at        TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

-- ------------------------------------------------------------
-- 3. ANONYMIZED VIEW FOR THE REINSURANCE PARTNER SHARE
--    (referenced in your Phase 4 GRANT statements)
-- ------------------------------------------------------------

CREATE OR REPLACE VIEW ANONYMIZED_CLAIMS AS
SELECT
    SHA2(claim_id, 256)      AS claim_id_hash,
    SHA2(patient_id, 256)    AS patient_id_hash,
    diagnosis_code,
    claim_amount,
    approved_amount,
    claim_status,
    region,
    claim_date
FROM fact_claims;

-- ============================================================
-- 4. ROW-LEVEL SECURITY: restrict claims adjusters to their
--    own region; executives/compliance see everything.
-- ============================================================

CREATE SCHEMA IF NOT EXISTS GOVERNANCE;

-- Mapping table: which Snowflake role is allowed to see which region.
-- Populate this per your org chart, e.g.:
--   INSERT INTO GOVERNANCE.region_role_map VALUES ('CLAIMS_ADJUSTER_NA','NORTH_AMERICA');
--   INSERT INTO GOVERNANCE.region_role_map VALUES ('CLAIMS_ADJUSTER_EU','EUROPE');
CREATE OR REPLACE TABLE GOVERNANCE.region_role_map (
    role_name  STRING,
    region     STRING
);

CREATE OR REPLACE ROW ACCESS POLICY GOVERNANCE.region_access_policy
AS (row_region STRING) RETURNS BOOLEAN ->
    CURRENT_ROLE() IN ('EXECUTIVE_ROLE', 'COMPLIANCE_ADMIN', 'ACCOUNTADMIN')
    OR EXISTS (
        SELECT 1
        FROM GOVERNANCE.region_role_map m
        WHERE m.role_name = CURRENT_ROLE()
          AND m.region = row_region
    );

-- Apply the policy to the fact table
ALTER TABLE fact_claims
    ADD ROW ACCESS POLICY GOVERNANCE.region_access_policy ON (region);

-- ------------------------------------------------------------
-- 5. COLUMN-LEVEL SECURITY: reuse the pii_mask policy from
--    Phase 1 on patient identifiers
-- ------------------------------------------------------------

-- Example: mask the patient's date of birth for non-privileged roles
CREATE OR REPLACE MASKING POLICY GOVERNANCE.dob_mask AS (val DATE) RETURNS DATE ->
    CASE
        WHEN CURRENT_ROLE() IN ('EXECUTIVE_ROLE', 'COMPLIANCE_ADMIN') THEN val
        ELSE DATE_TRUNC('YEAR', val)   -- show year only
    END;

ALTER TABLE dim_patient MODIFY COLUMN date_of_birth SET MASKING POLICY GOVERNANCE.dob_mask;

-- ------------------------------------------------------------
-- 6. TAGGING (governance layer, referenced in Phase 4)
-- ------------------------------------------------------------

CREATE TAG IF NOT EXISTS GOVERNANCE.pii_tag;
ALTER TABLE dim_patient MODIFY COLUMN date_of_birth SET TAG GOVERNANCE.pii_tag = 'PII';
ALTER TABLE dim_patient MODIFY COLUMN first_name    SET TAG GOVERNANCE.pii_tag = 'PII';
ALTER TABLE dim_patient MODIFY COLUMN last_name     SET TAG GOVERNANCE.pii_tag = 'PII';

-- ------------------------------------------------------------
-- Verify: as a role NOT in the mapping table, this returns 0 rows
-- even though the table has data — that's the row access policy working.
-- ------------------------------------------------------------
-- SELECT COUNT(*) FROM fact_claims;
