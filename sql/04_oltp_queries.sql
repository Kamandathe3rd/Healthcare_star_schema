-- ============================================================
-- 04_oltp_queries.sql
-- Part 2: The 4 business questions on the NORMALIZED (OLTP)
-- schema. Timings and analysis: docs/query_analysis.txt
-- Run AFTER 01 -> 02 -> 03. Read-only (changes no data).
-- ============================================================
USE healthcare_oltp;

-- ------------------------------------------------------------
-- QUESTION 1: Monthly Encounters by Specialty
-- For each month and specialty: total encounters and unique
-- patients, split by encounter type.
-- Joins: encounters -> providers -> specialties (3 tables, 2 joins)
-- Specialty is not on encounters, so it must come via providers.
-- ------------------------------------------------------------
SELECT DATE_FORMAT(e.encounter_date, '%Y-%m') AS encounter_month,
       s.specialty_name,
       e.encounter_type,
       COUNT(*)                     AS total_encounters,
       COUNT(DISTINCT e.patient_id) AS unique_patients
FROM encounters e
JOIN providers   p ON p.provider_id  = e.provider_id
JOIN specialties s ON s.specialty_id = p.specialty_id
GROUP BY encounter_month, s.specialty_name, e.encounter_type
ORDER BY encounter_month, s.specialty_name, e.encounter_type;

-- ------------------------------------------------------------
-- QUESTION 2: Top Diagnosis-Procedure Pairs
-- Most common ICD-10 + CPT combinations, by number of encounters.
-- Joins: encounter_diagnoses -> encounter_procedures (on
-- encounter_id), plus diagnoses and procedures for the codes
-- (4 tables, 3 joins). Every diagnosis is paired with every
-- procedure of the same encounter -> row explosion.
-- ------------------------------------------------------------
SELECT d.icd10_code,
       d.icd10_description,
       p.cpt_code,
       p.cpt_description,
       COUNT(DISTINCT ed.encounter_id) AS encounter_count
FROM encounter_diagnoses ed
JOIN encounter_procedures ep ON ep.encounter_id = ed.encounter_id
JOIN diagnoses  d ON d.diagnosis_id = ed.diagnosis_id
JOIN procedures p ON p.procedure_id = ep.procedure_id
GROUP BY d.icd10_code, d.icd10_description, p.cpt_code, p.cpt_description
ORDER BY encounter_count DESC, d.icd10_code, p.cpt_code
LIMIT 10;

-- ------------------------------------------------------------
-- QUESTION 3: 30-Day Readmission Rate by Specialty
-- Definition used: an Inpatient stay (i) is "readmitted" if the
-- same patient has another Inpatient admission (r) that starts
-- after i's discharge and within 30 days of it.
-- Specialty = specialty of the index stay's provider.
-- Joins: encounters SELF-JOIN (i -> r) + providers + specialties
-- (4 table references, 3 joins).
-- ------------------------------------------------------------
SELECT s.specialty_name,
       COUNT(DISTINCT i.encounter_id) AS inpatient_stays,
       COUNT(DISTINCT CASE WHEN r.encounter_id IS NOT NULL
                           THEN i.encounter_id END) AS readmitted_stays,
       ROUND(100 * COUNT(DISTINCT CASE WHEN r.encounter_id IS NOT NULL
                                       THEN i.encounter_id END)
                 / COUNT(DISTINCT i.encounter_id), 2) AS readmission_rate_pct
FROM encounters i
JOIN providers   p ON p.provider_id  = i.provider_id
JOIN specialties s ON s.specialty_id = p.specialty_id
LEFT JOIN encounters r
       ON  r.patient_id     = i.patient_id
       AND r.encounter_type = 'Inpatient'
       AND r.encounter_date >  i.discharge_date
       AND r.encounter_date <= i.discharge_date + INTERVAL 30 DAY
WHERE i.encounter_type = 'Inpatient'
GROUP BY s.specialty_name
ORDER BY readmission_rate_pct DESC;

-- ------------------------------------------------------------
-- QUESTION 4: Revenue by Specialty & Month
-- Total allowed amount (approved revenue) per specialty per month.
-- Month = SERVICE month (encounter_date), consistent with Q1.
-- JOIN chain: billing -> encounters -> providers -> specialties
-- (4 tables, 3 joins). Denied claims have allowed_amount = 0.
-- ------------------------------------------------------------
SELECT DATE_FORMAT(e.encounter_date, '%Y-%m') AS service_month,
       s.specialty_name,
       COUNT(*)              AS claims,
       SUM(b.allowed_amount) AS total_allowed
FROM billing b
JOIN encounters  e ON e.encounter_id = b.encounter_id
JOIN providers   p ON p.provider_id  = e.provider_id
JOIN specialties s ON s.specialty_id = p.specialty_id
GROUP BY service_month, s.specialty_name
ORDER BY service_month, total_allowed DESC;

-- Q4b: Which specialties generate the most revenue? (all months)
SELECT s.specialty_name,
       COUNT(*)              AS claims,
       SUM(b.allowed_amount) AS total_allowed
FROM billing b
JOIN encounters  e ON e.encounter_id = b.encounter_id
JOIN providers   p ON p.provider_id  = e.provider_id
JOIN specialties s ON s.specialty_id = p.specialty_id
GROUP BY s.specialty_name
ORDER BY total_allowed DESC;