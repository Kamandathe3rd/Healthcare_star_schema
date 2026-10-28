-- ============================================================
-- star_schema.sql
-- Part 3.2: Star schema DDL for healthcare analytics
-- Database: healthcare_star (separate from healthcare_oltp)
--
-- HOW TO RUN (MySQL Workbench): Ctrl + Shift + Enter
-- Run order: 01 -> 02 -> 03 -> star_schema.sql -> 06_etl_load.sql
-- Re-runnable: drops and rebuilds healthcare_star.
-- Dimensions: surrogate keys; key 0 = "Unknown" member (inserted
-- by the ETL) so missing source values never drop a fact row.
-- ============================================================

DROP DATABASE IF EXISTS healthcare_star;
CREATE DATABASE healthcare_star;
USE healthcare_star;

-- ------------------------------------------------------------
-- dim_date: one row per calendar day.
-- Smart key date_key = YYYYMMDD (e.g. 20240512), set by the ETL.
-- calendar_month ('2024-05') lets queries group by month WITHOUT
-- DATE_FORMAT() on every row.
-- ------------------------------------------------------------
CREATE TABLE dim_date (
    date_key        INT         NOT NULL PRIMARY KEY,
    calendar_date   DATE        NOT NULL UNIQUE,
    year            SMALLINT    NOT NULL,
    quarter         TINYINT     NOT NULL,
    month           TINYINT     NOT NULL,
    month_name      VARCHAR(10) NOT NULL,
    calendar_month  CHAR(7)     NOT NULL,   -- 'YYYY-MM'
    day_of_month    TINYINT     NOT NULL,
    day_of_week     TINYINT     NOT NULL,   -- 1 = Monday ... 7 = Sunday
    day_name        VARCHAR(10) NOT NULL,
    week_of_year    TINYINT     NOT NULL,
    is_weekend      TINYINT     NOT NULL,   -- 1 = Sat/Sun
    INDEX idx_dim_date_month (calendar_month)
) COMMENT = 'Calendar dimension: one row per day. date_key = YYYYMMDD.';

-- ------------------------------------------------------------
-- dim_patient: one row per patient (SCD Type 1 = overwrite).
-- age_group is derived in the ETL from date_of_birth.
-- ------------------------------------------------------------
CREATE TABLE dim_patient (
    patient_key     INT          NOT NULL AUTO_INCREMENT PRIMARY KEY,
    patient_id      INT          UNIQUE,    -- natural key from OLTP
    mrn             VARCHAR(20),
    first_name      VARCHAR(100),
    last_name       VARCHAR(100),
    full_name       VARCHAR(201),
    gender          CHAR(1),
    date_of_birth   DATE,
    age_group       VARCHAR(10)             -- '0-17','18-39','40-64','65+'
) COMMENT = 'Patient dimension (SCD Type 1). Key 0 = Unknown.';

-- ------------------------------------------------------------
-- dim_specialty: medical specialties (Q1, Q3, Q4 grouping).
-- ------------------------------------------------------------
CREATE TABLE dim_specialty (
    specialty_key   INT          NOT NULL AUTO_INCREMENT PRIMARY KEY,
    specialty_id    INT          UNIQUE,
    specialty_name  VARCHAR(100) NOT NULL,
    specialty_code  VARCHAR(10)
) COMMENT = 'Medical specialty dimension. Key 0 = Unknown.';

-- ------------------------------------------------------------
-- dim_department: hospital units.
-- ------------------------------------------------------------
CREATE TABLE dim_department (
    department_key  INT          NOT NULL AUTO_INCREMENT PRIMARY KEY,
    department_id   INT          UNIQUE,
    department_name VARCHAR(100) NOT NULL,
    floor           INT,
    capacity        INT
) COMMENT = 'Hospital department dimension. Key 0 = Unknown.';

-- ------------------------------------------------------------
-- dim_provider: clinicians, with specialty and department NAMES
-- copied in (denormalized) for provider-level reports.
-- ------------------------------------------------------------
CREATE TABLE dim_provider (
    provider_key    INT          NOT NULL AUTO_INCREMENT PRIMARY KEY,
    provider_id     INT          UNIQUE,
    first_name      VARCHAR(100),
    last_name       VARCHAR(100),
    full_name       VARCHAR(201),
    credential      VARCHAR(20),
    specialty_name  VARCHAR(100),
    department_name VARCHAR(100)
) COMMENT = 'Provider dimension with denormalized specialty/department names. Key 0 = Unknown.';

-- ------------------------------------------------------------
-- dim_encounter_type: tiny fixed list (keys set by the ETL).
-- ------------------------------------------------------------
CREATE TABLE dim_encounter_type (
    encounter_type_key  INT         NOT NULL PRIMARY KEY,
    encounter_type_name VARCHAR(50) NOT NULL UNIQUE,
    is_inpatient        TINYINT     NOT NULL   -- 1 = Inpatient
) COMMENT = 'Encounter type dimension: Outpatient, Inpatient, ER. Key 0 = Unknown.';

-- ------------------------------------------------------------
-- dim_diagnosis: ICD-10 codes, linked to facts via bridge table.
-- ------------------------------------------------------------
CREATE TABLE dim_diagnosis (
    diagnosis_key     INT          NOT NULL AUTO_INCREMENT PRIMARY KEY,
    diagnosis_id      INT          UNIQUE,
    icd10_code        VARCHAR(10)  NOT NULL,
    icd10_description VARCHAR(200)
) COMMENT = 'ICD-10 diagnosis dimension (used via bridge). Key 0 = Unknown.';

-- ------------------------------------------------------------
-- dim_procedure: CPT codes, linked to facts via bridge table.
-- ------------------------------------------------------------
CREATE TABLE dim_procedure (
    procedure_key   INT          NOT NULL AUTO_INCREMENT PRIMARY KEY,
    procedure_id    INT          UNIQUE,
    cpt_code        VARCHAR(10)  NOT NULL,
    cpt_description VARCHAR(200)
) COMMENT = 'CPT procedure dimension (used via bridge). Key 0 = Unknown.';

-- ------------------------------------------------------------
-- fact_encounters: GRAIN = one row per encounter.
-- Foreign keys to every dimension (0 = Unknown member).
-- Pre-aggregated measures remove OLTP joins at query time:
--   counts from the junction tables, money from billing,
--   readmission flag from the self-join (computed in the ETL).
-- Covering indexes are designed for the 4 business questions.
-- ------------------------------------------------------------
CREATE TABLE fact_encounters (
    encounter_key          INT           NOT NULL AUTO_INCREMENT PRIMARY KEY,
    encounter_id           INT           NOT NULL UNIQUE,  -- degenerate dim (OLTP id)

    -- dimension keys
    encounter_date_key     INT           NOT NULL,
    discharge_date_key     INT,
    patient_key            INT           NOT NULL,
    provider_key           INT           NOT NULL,
    specialty_key          INT           NOT NULL,         -- stored directly: 1 hop
    department_key         INT           NOT NULL,
    encounter_type_key     INT           NOT NULL,

    -- exact timestamps (needed for the 30-day readmission rule)
    encounter_datetime     DATETIME      NOT NULL,
    discharge_datetime     DATETIME,

    -- pre-aggregated / pre-computed measures
    length_of_stay_hours   DECIMAL(8,2),
    diagnosis_count        SMALLINT      NOT NULL DEFAULT 0,
    procedure_count        SMALLINT      NOT NULL DEFAULT 0,
    claim_count            SMALLINT      NOT NULL DEFAULT 0,
    total_claim_amount     DECIMAL(12,2) NOT NULL DEFAULT 0,
    total_allowed_amount   DECIMAL(12,2) NOT NULL DEFAULT 0,
    readmitted_within_30d  TINYINT       NOT NULL DEFAULT 0, -- 1 = inpatient readmit <= 30d

    FOREIGN KEY (encounter_date_key) REFERENCES dim_date(date_key),
    FOREIGN KEY (discharge_date_key) REFERENCES dim_date(date_key),
    FOREIGN KEY (patient_key)        REFERENCES dim_patient(patient_key),
    FOREIGN KEY (provider_key)       REFERENCES dim_provider(provider_key),
    FOREIGN KEY (specialty_key)      REFERENCES dim_specialty(specialty_key),
    FOREIGN KEY (department_key)     REFERENCES dim_department(department_key),
    FOREIGN KEY (encounter_type_key) REFERENCES dim_encounter_type(encounter_type_key),

    -- covering indexes for the 4 business questions
    INDEX idx_fact_month_mix (encounter_date_key, specialty_key, encounter_type_key, patient_key), -- Q1
    INDEX idx_fact_revenue   (encounter_date_key, specialty_key, claim_count, total_allowed_amount), -- Q4
    INDEX idx_fact_readmit   (encounter_type_key, specialty_key, readmitted_within_30d),             -- Q3
    INDEX idx_fact_patient   (patient_key, encounter_datetime)                                       -- history
) COMMENT = 'Fact table. Grain: one row per encounter.';

-- ------------------------------------------------------------
-- bridge_encounter_diagnoses: encounter <-> diagnoses (M:N).
-- PK starts with encounter_key so one encounter's codes are
-- stored together (fast Q2 pairing). diagnosis_sequence 1 = primary.
-- ------------------------------------------------------------
CREATE TABLE bridge_encounter_diagnoses (
    encounter_key       INT NOT NULL,
    diagnosis_key       INT NOT NULL,
    diagnosis_sequence  INT,
    PRIMARY KEY (encounter_key, diagnosis_key),
    INDEX idx_bridge_dx_diagnosis (diagnosis_key),
    FOREIGN KEY (encounter_key) REFERENCES fact_encounters(encounter_key),
    FOREIGN KEY (diagnosis_key) REFERENCES dim_diagnosis(diagnosis_key)
) COMMENT = 'Bridge: encounter <-> diagnoses (many-to-many).';

-- ------------------------------------------------------------
-- bridge_encounter_procedures: encounter <-> procedures (M:N).
-- ------------------------------------------------------------
CREATE TABLE bridge_encounter_procedures (
    encounter_key       INT NOT NULL,
    procedure_key       INT NOT NULL,
    procedure_date_key  INT,
    PRIMARY KEY (encounter_key, procedure_key),
    INDEX idx_bridge_px_procedure (procedure_key),
    FOREIGN KEY (encounter_key)      REFERENCES fact_encounters(encounter_key),
    FOREIGN KEY (procedure_key)      REFERENCES dim_procedure(procedure_key),
    FOREIGN KEY (procedure_date_key) REFERENCES dim_date(date_key)
) COMMENT = 'Bridge: encounter <-> procedures (many-to-many).';