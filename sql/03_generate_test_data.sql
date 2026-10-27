-- ============================================================
-- 03_generate_test_data.sql
-- Part 2: Generate realistic FAKE data for performance testing.
-- No real patients. Adds ~10k patients, ~100k encounters,
-- ~250k diagnosis links, ~150k procedure links, ~90k claims.
--
-- HOW TO RUN (MySQL Workbench):
--   Run 01_oltp_schema.sql -> 02_oltp_sample_data.sql -> this file,
--   each with Ctrl + Shift + Enter (nothing highlighted).
--   Takes ~20-60 seconds. Run ONCE after 01 + 02.
--
-- Reproducible: uses a hash-based rnd() function instead of RAND(),
-- so every run (on any PC) produces exactly the same data.
-- Generated IDs never clash with the lab's sample IDs:
--   providers 201-300, patients 10001-20000,
--   encounters 100001-200000, billing 300001-400000.
-- ============================================================
USE healthcare_oltp;

-- Allow recursive CTEs to count up to 100,000 (default is 1,000)
SET SESSION cte_max_recursion_depth = 100000;

-- ------------------------------------------------------------
-- 0. Helper: rnd(tag, n, max_value) -> repeatable number 0..max_value-1
--    'tag' gives each column its own independent sequence.
--    One central helper instead of repeating the formula everywhere.
-- ------------------------------------------------------------
DROP FUNCTION IF EXISTS rnd;
CREATE FUNCTION rnd(tag VARCHAR(20), n INT, max_value INT)
RETURNS INT
DETERMINISTIC NO SQL
RETURN CONV(LEFT(MD5(CONCAT(tag, '-', n)), 8), 16, 10) % max_value;

-- ------------------------------------------------------------
-- 1. Reference data: 8 specialties/departments, 20 ICD-10, 15 CPT
-- ------------------------------------------------------------
INSERT INTO specialties VALUES
    (4, 'Orthopedics',     'ORTH'),
    (5, 'Neurology',       'NEUR'),
    (6, 'Pediatrics',      'PEDS'),
    (7, 'Oncology',        'ONC'),
    (8, 'General Surgery', 'GSURG');

INSERT INTO departments VALUES
    (4, 'Orthopedics Ward', 4, 25),
    (5, 'Neurology Unit',   5, 20),
    (6, 'Pediatrics Ward',  2, 30),
    (7, 'Oncology Center',  6, 35),
    (8, 'Surgical Unit',    4, 40);

INSERT INTO diagnoses VALUES
    (3004, 'J18.9',    'Pneumonia'),
    (3005, 'J44.9',    'COPD'),
    (3006, 'N39.0',    'Urinary Tract Infection'),
    (3007, 'I48.91',   'Atrial Fibrillation'),
    (3008, 'I21.9',    'Acute Myocardial Infarction'),
    (3009, 'E78.5',    'Hyperlipidemia'),
    (3010, 'F32.9',    'Major Depressive Disorder'),
    (3011, 'M54.5',    'Low Back Pain'),
    (3012, 'J45.909',  'Asthma'),
    (3013, 'K21.9',    'GERD'),
    (3014, 'N18.9',    'Chronic Kidney Disease'),
    (3015, 'R07.9',    'Chest Pain'),
    (3016, 'S72.001A', 'Femur Fracture'),
    (3017, 'G43.909',  'Migraine'),
    (3018, 'C50.919',  'Breast Cancer'),
    (3019, 'R50.9',    'Fever'),
    (3020, 'A41.9',    'Sepsis');

INSERT INTO procedures VALUES
    (4004, '99214', 'Office Visit, Moderate'),
    (4005, '99283', 'ER Visit, Moderate'),
    (4006, '99285', 'ER Visit, High Severity'),
    (4007, '80053', 'Metabolic Panel'),
    (4008, '85025', 'Complete Blood Count'),
    (4009, '93306', 'Echocardiogram'),
    (4010, '70450', 'CT Head'),
    (4011, '72148', 'MRI Lumbar Spine'),
    (4012, '36415', 'Blood Draw'),
    (4013, '99223', 'Initial Hospital Care'),
    (4014, '99232', 'Subsequent Hospital Care'),
    (4015, '27447', 'Total Knee Replacement');

-- ------------------------------------------------------------
-- 2. Providers: 100 (IDs 201-300), spread evenly over 8 specialties.
--    specialty_id = department_id = 1 + (provider_id % 8)
--    -> providers where provider_id % 8 = 2 are Emergency (3).
-- ------------------------------------------------------------
INSERT INTO providers (provider_id, first_name, last_name, credential,
                       specialty_id, department_id)
WITH RECURSIVE seq (n) AS (
    SELECT 1 UNION ALL SELECT n + 1 FROM seq WHERE n < 100
)
SELECT 200 + n,
       ELT(1 + rnd('pf', n, 10), 'Ama','Kwame','Grace','Daniel','Fatima',
                                 'Samuel','Linda','Kofi','Maria','Peter'),
       ELT(1 + rnd('pl', n, 10), 'Mensah','Owusu','Patel','Nguyen','Okafor',
                                 'Brown','Garcia','Asante','Kim','Boateng'),
       ELT(1 + rnd('pc', n, 4), 'MD','MD','DO','NP'),
       1 + (200 + n) % 8,
       1 + (200 + n) % 8
FROM seq;

-- ------------------------------------------------------------
-- 3. Patients: 10,000 (IDs 10001-20000), born 1935-2019.
-- ------------------------------------------------------------
INSERT INTO patients (patient_id, first_name, last_name, date_of_birth,
                      gender, mrn)
WITH RECURSIVE seq (n) AS (
    SELECT 1 UNION ALL SELECT n + 1 FROM seq WHERE n < 10000
)
SELECT 10000 + n,
       ELT(1 + rnd('f', n, 12), 'John','Mary','Kwame','Aisha','David','Grace',
                                'Yaw','Esi','Michael','Sarah','Kofi','Linda'),
       ELT(1 + rnd('l', n, 12), 'Doe','Smith','Mensah','Owusu','Johnson','Asante',
                                'Brown','Boateng','Williams','Addo','Garcia','Osei'),
       DATE_ADD('1935-01-01', INTERVAL rnd('dob', n, 31000) DAY),
       ELT(1 + rnd('g', n, 2), 'M', 'F'),
       CONCAT('MRN', LPAD(10000 + n, 6, '0'))
FROM seq;

-- ------------------------------------------------------------
-- 4. Encounters: 100,000 (IDs 100001-200000) over 2023-2024.
--    Mix: ~60% Outpatient, ~25% ER, ~15% Inpatient.
--    ER visits go to Emergency providers; other visits go to
--    non-Emergency providers. Department = provider's department.
--    Length of stay: Outpatient 30-180 min, ER 2-12 h,
--    Inpatient 1-10 days.
-- ------------------------------------------------------------
INSERT INTO encounters (encounter_id, patient_id, provider_id, encounter_type,
                        encounter_date, discharge_date, department_id)
WITH RECURSIVE seq (n) AS (
    SELECT 1 UNION ALL SELECT n + 1 FROM seq WHERE n < 100000
),
base AS (                       -- pick type and admission date/time
    SELECT n,
           CASE WHEN rnd('t', n, 100) < 60 THEN 'Outpatient'
                WHEN rnd('t', n, 100) < 85 THEN 'ER'
                ELSE 'Inpatient' END                      AS encounter_type,
           TIMESTAMP('2023-01-01 00:00:00')
             + INTERVAL rnd('d', n, 731)  DAY
             + INTERVAL rnd('m', n, 1440) MINUTE          AS encounter_date
    FROM seq
),
picked AS (                     -- pick a provider that fits the type
    SELECT n, encounter_type, encounter_date,
           CASE WHEN encounter_type = 'ER'
                THEN 202 + 8 * rnd('p', n, 13)            -- Emergency docs
                ELSE 201 + rnd('p', n, 100) END           AS provider_raw
    FROM base
),
fixed AS (                      -- non-ER visit landed on an ER doc? shift by 1
    SELECT n, encounter_type, encounter_date,
           IF(encounter_type <> 'ER' AND provider_raw % 8 = 2,
              provider_raw + 1, provider_raw)             AS provider_id
    FROM picked
)
SELECT 100000 + n,
       10001 + rnd('pt', n, 10000),
       provider_id,
       encounter_type,
       encounter_date,
       CASE encounter_type
            WHEN 'Outpatient' THEN encounter_date + INTERVAL 30   + rnd('x', n, 151)   MINUTE
            WHEN 'ER'         THEN encounter_date + INTERVAL 120  + rnd('x', n, 601)   MINUTE
            ELSE                   encounter_date + INTERVAL 1440 + rnd('x', n, 12961) MINUTE
       END,
       1 + provider_id % 8
FROM fixed;

-- ------------------------------------------------------------
-- 5. encounter_diagnoses: 1-4 per encounter (~250k rows).
--    The k-list (1..4) is joined to each encounter; k <= its count.
--    Step of 7 (mod 20) keeps diagnoses distinct within an encounter.
-- ------------------------------------------------------------
INSERT INTO encounter_diagnoses (encounter_diagnosis_id, encounter_id,
                                 diagnosis_id, diagnosis_sequence)
SELECT e.encounter_id * 10 + k.k,
       e.encounter_id,
       3001 + (rnd('dx', e.encounter_id, 20) + k.k * 7) % 20,
       k.k
FROM encounters e
JOIN (SELECT 1 AS k UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 4) k
  ON k.k <= 1 + rnd('ndx', e.encounter_id, 4)
WHERE e.encounter_id > 100000;          -- generated encounters only

-- ------------------------------------------------------------
-- 6. encounter_procedures: 0-3 per encounter (~150k rows).
--    Step of 4 (mod 15) keeps procedures distinct within an encounter.
-- ------------------------------------------------------------
INSERT INTO encounter_procedures (encounter_procedure_id, encounter_id,
                                  procedure_id, procedure_date)
SELECT e.encounter_id * 10 + k.k,
       e.encounter_id,
       4001 + (rnd('px', e.encounter_id, 15) + k.k * 4) % 15,
       DATE(e.encounter_date)
FROM encounters e
JOIN (SELECT 1 AS k UNION ALL SELECT 2 UNION ALL SELECT 3) k
  ON k.k <= rnd('npx', e.encounter_id, 4)
WHERE e.encounter_id > 100000;

-- ------------------------------------------------------------
-- 7. Billing: ~90% of encounters get a claim (IDs 300001+).
--    Claim size depends on type; allowed = 60-90% of claim.
--    Status: ~80% Paid, ~12% Pending, ~8% Denied (allowed = 0).
-- ------------------------------------------------------------
INSERT INTO billing (billing_id, encounter_id, claim_amount, allowed_amount,
                     claim_date, claim_status)
SELECT c.encounter_id + 200000,
       c.encounter_id,
       c.claim_amount,
       CASE WHEN c.claim_status = 'Denied' THEN 0
            ELSE ROUND(c.claim_amount * (60 + rnd('al', c.encounter_id, 31)) / 100, 2)
       END,
       c.claim_date,
       c.claim_status
FROM (
    SELECT e.encounter_id,
           CASE e.encounter_type
                WHEN 'Outpatient' THEN 150  + rnd('c', e.encounter_id, 501)
                WHEN 'ER'         THEN 800  + rnd('c', e.encounter_id, 5001)
                ELSE                   5000 + rnd('c', e.encounter_id, 40001)
           END                                                      AS claim_amount,
           DATE(e.discharge_date) + INTERVAL 1 + rnd('cd', e.encounter_id, 14) DAY
                                                                    AS claim_date,
           CASE WHEN rnd('st', e.encounter_id, 100) < 80 THEN 'Paid'
                WHEN rnd('st', e.encounter_id, 100) < 92 THEN 'Pending'
                ELSE 'Denied' END                                   AS claim_status
    FROM encounters e
    WHERE e.encounter_id > 100000
      AND rnd('b', e.encounter_id, 10) < 9      -- ~10% left unbilled
) c;

-- ------------------------------------------------------------
-- 8. Refresh optimizer statistics so query plans/timings are fair
-- ------------------------------------------------------------
ANALYZE TABLE patients, providers, encounters,
              encounter_diagnoses, encounter_procedures, billing;

-- ------------------------------------------------------------
-- 9. Verify (expected values in comments)
-- ------------------------------------------------------------
SELECT 'specialties' AS table_name, COUNT(*) AS row_count FROM specialties  -- 8
UNION ALL SELECT 'departments',          COUNT(*) FROM departments          -- 8
UNION ALL SELECT 'providers',            COUNT(*) FROM providers            -- 103
UNION ALL SELECT 'patients',             COUNT(*) FROM patients             -- 10003
UNION ALL SELECT 'diagnoses',            COUNT(*) FROM diagnoses            -- 20
UNION ALL SELECT 'procedures',           COUNT(*) FROM procedures           -- 15
UNION ALL SELECT 'encounters',           COUNT(*) FROM encounters           -- 100004
UNION ALL SELECT 'encounter_diagnoses',  COUNT(*) FROM encounter_diagnoses  -- 250081
UNION ALL SELECT 'encounter_procedures', COUNT(*) FROM encounter_procedures -- 149598
UNION ALL SELECT 'billing',              COUNT(*) FROM billing;             -- 90000