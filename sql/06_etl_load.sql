-- ============================================================
-- 06_etl_load.sql
-- Part 3.4: ETL - load healthcare_star from healthcare_oltp
-- Run order: 01 -> 02 -> 03 -> star_schema.sql -> this file
-- Full refresh: run star_schema.sql first (empties the star).
-- ============================================================
USE healthcare_star;

-- Store a real 0 in AUTO_INCREMENT columns (Unknown members)
SET SESSION sql_mode = CONCAT(@@sql_mode, ',NO_AUTO_VALUE_ON_ZERO');
-- dim_date needs ~1,100 recursive steps (default limit 1,000)
SET SESSION cte_max_recursion_depth = 10000;

-- ------------------------------------------------------------
-- 1. dim_date: one-time generated load, 2023-01-01 .. 2025-12-31
-- ------------------------------------------------------------
INSERT INTO dim_date (date_key, calendar_date, year, quarter, month,
                      month_name, calendar_month, day_of_month,
                      day_of_week, day_name, week_of_year, is_weekend)
WITH RECURSIVE days (d) AS (
    SELECT DATE('2023-01-01')
    UNION ALL
    SELECT d + INTERVAL 1 DAY FROM days WHERE d < '2025-12-31'
)
SELECT CAST(DATE_FORMAT(d, '%Y%m%d') AS UNSIGNED),  -- 20240512
       d,
       YEAR(d),
       QUARTER(d),
       MONTH(d),
       MONTHNAME(d),
       DATE_FORMAT(d, '%Y-%m'),                      -- '2024-05'
       DAY(d),
       WEEKDAY(d) + 1,                               -- 1 = Monday
       DAYNAME(d),
       WEEK(d, 3),                                   -- ISO week number
       IF(WEEKDAY(d) >= 5, 1, 0)                     -- Sat/Sun
FROM days;

-- ------------------------------------------------------------
-- 2. Unknown members (key 0) + fixed encounter types
-- ------------------------------------------------------------
INSERT INTO dim_patient (patient_key, patient_id, mrn, first_name, last_name,
                         full_name, gender, date_of_birth, age_group)
VALUES (0, NULL, NULL, 'Unknown', 'Unknown', 'Unknown', NULL, NULL, 'Unknown');

INSERT INTO dim_specialty (specialty_key, specialty_id, specialty_name, specialty_code)
VALUES (0, NULL, 'Unknown', 'UNK');

INSERT INTO dim_department (department_key, department_id, department_name, floor, capacity)
VALUES (0, NULL, 'Unknown', NULL, NULL);

INSERT INTO dim_provider (provider_key, provider_id, first_name, last_name, full_name,
                          credential, specialty_name, department_name)
VALUES (0, NULL, 'Unknown', 'Unknown', 'Unknown', NULL, 'Unknown', 'Unknown');

INSERT INTO dim_diagnosis (diagnosis_key, diagnosis_id, icd10_code, icd10_description)
VALUES (0, NULL, 'UNK', 'Unknown');

INSERT INTO dim_procedure (procedure_key, procedure_id, cpt_code, cpt_description)
VALUES (0, NULL, 'UNK', 'Unknown');

INSERT INTO dim_encounter_type (encounter_type_key, encounter_type_name, is_inpatient)
VALUES (0, 'Unknown',    0),
       (1, 'Outpatient', 0),
       (2, 'Inpatient',  1),
       (3, 'ER',         0);

-- ------------------------------------------------------------
-- 3. Simple dimensions: straight copies from OLTP
-- ------------------------------------------------------------
INSERT INTO dim_specialty (specialty_id, specialty_name, specialty_code)
SELECT specialty_id, specialty_name, specialty_code
FROM healthcare_oltp.specialties
ORDER BY specialty_id;

INSERT INTO dim_department (department_id, department_name, floor, capacity)
SELECT department_id, department_name, floor, capacity
FROM healthcare_oltp.departments
ORDER BY department_id;

INSERT INTO dim_diagnosis (diagnosis_id, icd10_code, icd10_description)
SELECT diagnosis_id, icd10_code, icd10_description
FROM healthcare_oltp.diagnoses
ORDER BY diagnosis_id;

INSERT INTO dim_procedure (procedure_id, cpt_code, cpt_description)
SELECT procedure_id, cpt_code, cpt_description
FROM healthcare_oltp.procedures
ORDER BY procedure_id;

-- ------------------------------------------------------------
-- 4. dim_patient: add full_name and age_group (age as of today)
-- ------------------------------------------------------------
INSERT INTO dim_patient (patient_id, mrn, first_name, last_name, full_name,
                         gender, date_of_birth, age_group)
SELECT patient_id,
       mrn,
       first_name,
       last_name,
       CONCAT(first_name, ' ', last_name),
       gender,
       date_of_birth,
       CASE WHEN date_of_birth IS NULL                            THEN 'Unknown'
            WHEN TIMESTAMPDIFF(YEAR, date_of_birth, CURDATE()) < 18 THEN '0-17'
            WHEN TIMESTAMPDIFF(YEAR, date_of_birth, CURDATE()) < 40 THEN '18-39'
            WHEN TIMESTAMPDIFF(YEAR, date_of_birth, CURDATE()) < 65 THEN '40-64'
            ELSE '65+'
       END
FROM healthcare_oltp.patients
ORDER BY patient_id;

-- ------------------------------------------------------------
-- 5. dim_provider: denormalize specialty and department NAMES
--    LEFT JOIN + COALESCE: a provider with a missing specialty
--    is still loaded, labelled 'Unknown'.
-- ------------------------------------------------------------
INSERT INTO dim_provider (provider_id, first_name, last_name, full_name,
                          credential, specialty_name, department_name)
SELECT p.provider_id,
       p.first_name,
       p.last_name,
       CONCAT(p.first_name, ' ', p.last_name),
       p.credential,
       COALESCE(s.specialty_name,  'Unknown'),
       COALESCE(d.department_name, 'Unknown')
FROM healthcare_oltp.providers p
LEFT JOIN healthcare_oltp.specialties s ON s.specialty_id  = p.specialty_id
LEFT JOIN healthcare_oltp.departments d ON d.department_id = p.department_id
ORDER BY p.provider_id;

-- ------------------------------------------------------------
-- 6. fact_encounters: one row per OLTP encounter
--    - dimension keys looked up by natural key; LEFT JOIN +
--      COALESCE(...,0) sends missing values to the Unknown row
--    - child tables are AGGREGATED FIRST (one row per encounter)
--      and then joined, so nothing is multiplied or double-counted
--    - readmission flag computed once here (replaces Q3 self-join)
-- ------------------------------------------------------------
INSERT INTO fact_encounters (
       encounter_id, encounter_date_key, discharge_date_key,
       patient_key, provider_key, specialty_key, department_key, encounter_type_key,
       encounter_datetime, discharge_datetime, length_of_stay_hours,
       diagnosis_count, procedure_count,
       claim_count, total_claim_amount, total_allowed_amount,
       readmitted_within_30d)
SELECT e.encounter_id,
       CAST(DATE_FORMAT(e.encounter_date, '%Y%m%d') AS UNSIGNED),
       CAST(DATE_FORMAT(e.discharge_date, '%Y%m%d') AS UNSIGNED),
       COALESCE(dp.patient_key,         0),
       COALESCE(dpr.provider_key,       0),
       COALESCE(ds.specialty_key,       0),
       COALESCE(dd.department_key,      0),
       COALESCE(dt.encounter_type_key,  0),
       e.encounter_date,
       e.discharge_date,
       ROUND(TIMESTAMPDIFF(MINUTE, e.encounter_date, e.discharge_date) / 60, 2),
       COALESCE(dx.n, 0),
       COALESCE(px.n, 0),
       COALESCE(b.n, 0),
       COALESCE(b.claim_total, 0),
       COALESCE(b.allowed_total, 0),
       CASE WHEN e.encounter_type = 'Inpatient' AND EXISTS (
                SELECT 1
                FROM healthcare_oltp.encounters r
                WHERE r.patient_id     = e.patient_id
                  AND r.encounter_type = 'Inpatient'
                  AND r.encounter_date >  e.discharge_date
                  AND r.encounter_date <= e.discharge_date + INTERVAL 30 DAY)
            THEN 1 ELSE 0
       END
FROM healthcare_oltp.encounters e
-- key lookups (natural key -> surrogate key)
LEFT JOIN healthcare_oltp.providers pr ON pr.provider_id          = e.provider_id
LEFT JOIN dim_patient        dp  ON dp.patient_id                 = e.patient_id
LEFT JOIN dim_provider       dpr ON dpr.provider_id               = e.provider_id
LEFT JOIN dim_specialty      ds  ON ds.specialty_id               = pr.specialty_id
LEFT JOIN dim_department     dd  ON dd.department_id              = e.department_id
LEFT JOIN dim_encounter_type dt  ON dt.encounter_type_name        = e.encounter_type
-- pre-aggregated child tables (one row per encounter each)
LEFT JOIN (SELECT encounter_id, COUNT(*) AS n
           FROM healthcare_oltp.encounter_diagnoses
           GROUP BY encounter_id) dx ON dx.encounter_id = e.encounter_id
LEFT JOIN (SELECT encounter_id, COUNT(*) AS n
           FROM healthcare_oltp.encounter_procedures
           GROUP BY encounter_id) px ON px.encounter_id = e.encounter_id
LEFT JOIN (SELECT encounter_id,
                  COUNT(*)            AS n,
                  SUM(claim_amount)   AS claim_total,
                  SUM(allowed_amount) AS allowed_total
           FROM healthcare_oltp.billing
           GROUP BY encounter_id) b  ON b.encounter_id  = e.encounter_id
ORDER BY e.encounter_id;

-- ------------------------------------------------------------
-- 7. Bridges: translate encounter_id -> encounter_key via the fact
-- ------------------------------------------------------------
INSERT INTO bridge_encounter_diagnoses (encounter_key, diagnosis_key, diagnosis_sequence)
SELECT f.encounter_key,
       COALESCE(dg.diagnosis_key, 0),
       ed.diagnosis_sequence
FROM healthcare_oltp.encounter_diagnoses ed
JOIN fact_encounters f      ON f.encounter_id  = ed.encounter_id
LEFT JOIN dim_diagnosis dg  ON dg.diagnosis_id = ed.diagnosis_id;

INSERT INTO bridge_encounter_procedures (encounter_key, procedure_key, procedure_date_key)
SELECT f.encounter_key,
       COALESCE(dpc.procedure_key, 0),
       CAST(DATE_FORMAT(ep.procedure_date, '%Y%m%d') AS UNSIGNED)
FROM healthcare_oltp.encounter_procedures ep
JOIN fact_encounters f      ON f.encounter_id   = ep.encounter_id
LEFT JOIN dim_procedure dpc ON dpc.procedure_id = ep.procedure_id;

-- ------------------------------------------------------------
-- 8. Refresh optimizer statistics (fair query plans and timings)
-- ------------------------------------------------------------
ANALYZE TABLE dim_date, dim_patient, dim_provider, dim_specialty,
              dim_department, dim_encounter_type, dim_diagnosis,
              dim_procedure, fact_encounters,
              bridge_encounter_diagnoses, bridge_encounter_procedures;