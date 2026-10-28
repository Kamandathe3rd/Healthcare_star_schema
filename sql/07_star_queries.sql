-- ============================================================
-- 07_star_queries.sql
-- Part 3.3: The 4 business questions on the STAR schema.
-- Same answers as sql/04_oltp_queries.sql, fewer/simpler joins.
-- Run AFTER star_schema.sql + 06_etl_load.sql. Read-only.
-- Timings and comparison: docs/star_schema_queries.txt
-- ============================================================
USE healthcare_star;

-- ------------------------------------------------------------
-- Q1 (star): Monthly Encounters by Specialty
-- Month comes from dim_date.calendar_month (no DATE_FORMAT per
-- row); specialty_key is ON the fact (1 hop, not 2).
-- Aggregate on integer keys first, then join names (360 rows).
-- ------------------------------------------------------------
WITH monthly AS (
    SELECT d.calendar_month,
           f.specialty_key,
           f.encounter_type_key,
           COUNT(*)                      AS total_encounters,
           COUNT(DISTINCT f.patient_key) AS unique_patients
    FROM fact_encounters f
    JOIN dim_date d ON d.date_key = f.encounter_date_key
    GROUP BY d.calendar_month, f.specialty_key, f.encounter_type_key
)
SELECT m.calendar_month       AS encounter_month,
       s.specialty_name,
       t.encounter_type_name  AS encounter_type,
       m.total_encounters,
       m.unique_patients
FROM monthly m
JOIN dim_specialty      s ON s.specialty_key      = m.specialty_key
JOIN dim_encounter_type t ON t.encounter_type_key = m.encounter_type_key
ORDER BY encounter_month, s.specialty_name, encounter_type;

-- ------------------------------------------------------------
-- Q2 (star): Top Diagnosis-Procedure Pairs
-- Pair the two bridges on encounter_key (narrow integer rows,
-- PK starts with encounter_key), count by key pair, keep the
-- top 10, THEN look up the 10 codes. COUNT(*) is exact because
-- the bridge PKs forbid duplicate codes per encounter.
-- ------------------------------------------------------------
WITH top_pairs AS (
    SELECT bd.diagnosis_key,
           bp.procedure_key,
           COUNT(*) AS encounter_count
    FROM bridge_encounter_diagnoses  bd
    JOIN bridge_encounter_procedures bp ON bp.encounter_key = bd.encounter_key
    GROUP BY bd.diagnosis_key, bp.procedure_key
    ORDER BY encounter_count DESC
    LIMIT 10
)
SELECT dg.icd10_code,
       dg.icd10_description,
       pc.cpt_code,
       pc.cpt_description,
       tp.encounter_count
FROM top_pairs tp
JOIN dim_diagnosis dg ON dg.diagnosis_key = tp.diagnosis_key
JOIN dim_procedure pc ON pc.procedure_key = tp.procedure_key
ORDER BY tp.encounter_count DESC, dg.icd10_code, pc.cpt_code;

-- ------------------------------------------------------------
-- Q3 (star): 30-Day Readmission Rate by Specialty
-- The self-join was done ONCE in the ETL; here we just SUM the
-- 0/1 flag. Covering index idx_fact_readmit.
-- ------------------------------------------------------------
SELECT s.specialty_name,
       COUNT(*)                     AS inpatient_stays,
       SUM(f.readmitted_within_30d) AS readmitted_stays,
       ROUND(100 * SUM(f.readmitted_within_30d) / COUNT(*), 2) AS readmission_rate_pct
FROM fact_encounters f
JOIN dim_encounter_type t ON t.encounter_type_key = f.encounter_type_key
JOIN dim_specialty      s ON s.specialty_key      = f.specialty_key
WHERE t.is_inpatient = 1
GROUP BY s.specialty_name
ORDER BY readmission_rate_pct DESC;

-- ------------------------------------------------------------
-- Q4 (star): Revenue by Specialty & Month
-- Revenue is pre-aggregated on the fact: no billing table, no
-- 3-join chain. Covering index idx_fact_revenue.
-- ------------------------------------------------------------
WITH monthly AS (
    SELECT d.calendar_month,
           f.specialty_key,
           SUM(f.claim_count)          AS claims,
           SUM(f.total_allowed_amount) AS total_allowed
    FROM fact_encounters f
    JOIN dim_date d ON d.date_key = f.encounter_date_key
    GROUP BY d.calendar_month, f.specialty_key
)
SELECT m.calendar_month AS service_month,
       s.specialty_name,
       m.claims,
       m.total_allowed
FROM monthly m
JOIN dim_specialty s ON s.specialty_key = m.specialty_key
ORDER BY service_month, m.total_allowed DESC;