-- ============================================================
-- 01_oltp_schema.sql
-- Part 1: Normalized OLTP schema (3NF) for the healthcare lab
-- Run on: MySQL 8.0
--
-- HOW TO RUN (in MySQL Workbench):
--   1. Run this whole file:   Ctrl + Shift + Enter
--   2. Then run 02_oltp_sample_data.sql the same way
-- Re-runnable: drops and rebuilds healthcare_oltp each time.
-- WARNING: DROP DATABASE deletes all data in healthcare_oltp.
-- ============================================================

-- Which MySQL version am I on? (record this in the README)
SELECT VERSION();

-- Start clean: remove the old copy (if any), then create fresh
DROP DATABASE IF EXISTS healthcare_oltp;
CREATE DATABASE healthcare_oltp;

-- Work inside it from now on
USE healthcare_oltp;

-- Confirm which database is active
SELECT DATABASE();

-- ------------------------------------------------------------
-- Table: patients
-- One row per patient. patient_id is the system key,
-- mrn is the hospital's medical record number (must be unique).
-- ------------------------------------------------------------
CREATE TABLE patients (
    patient_id    INT PRIMARY KEY,
    first_name    VARCHAR(100),
    last_name     VARCHAR(100),
    date_of_birth DATE,
    gender        CHAR(1),
    mrn           VARCHAR(20) UNIQUE
);

-- ------------------------------------------------------------
-- Table: specialties (lookup)
-- Medical specialties, e.g. Cardiology. Referenced by providers.
-- ------------------------------------------------------------
CREATE TABLE specialties (
    specialty_id   INT PRIMARY KEY,
    specialty_name VARCHAR(100),
    specialty_code VARCHAR(10)
);

-- ------------------------------------------------------------
-- Table: departments (lookup)
-- Hospital units with floor and bed capacity.
-- Referenced by providers and encounters.
-- ------------------------------------------------------------
CREATE TABLE departments (
    department_id   INT PRIMARY KEY,
    department_name VARCHAR(100),
    floor           INT,
    capacity        INT
);

-- ------------------------------------------------------------
-- Table: diagnoses (lookup)
-- ICD-10 diagnosis codes. Linked to encounters via encounter_diagnoses.
-- ------------------------------------------------------------
CREATE TABLE diagnoses (
    diagnosis_id      INT PRIMARY KEY,
    icd10_code        VARCHAR(10),
    icd10_description VARCHAR(200)
);

-- ------------------------------------------------------------
-- Table: procedures (lookup)
-- CPT procedure codes. Linked to encounters via encounter_procedures.
-- ------------------------------------------------------------
CREATE TABLE procedures (
    procedure_id    INT PRIMARY KEY,
    cpt_code        VARCHAR(10),
    cpt_description VARCHAR(200)
);

-- ------------------------------------------------------------
-- Table: providers
-- Doctors/clinicians. Each provider belongs to one specialty
-- and one department (both enforced by foreign keys).
-- ------------------------------------------------------------
CREATE TABLE providers (
    provider_id   INT PRIMARY KEY,
    first_name    VARCHAR(100),
    last_name     VARCHAR(100),
    credential    VARCHAR(20),
    specialty_id  INT,
    department_id INT,
    FOREIGN KEY (specialty_id)  REFERENCES specialties(specialty_id),
    FOREIGN KEY (department_id) REFERENCES departments(department_id)
);

-- ------------------------------------------------------------
-- Table: encounters
-- One row per patient visit (Outpatient, Inpatient or ER).
-- Links patient, provider and department. Central table for
-- all 4 analytics questions. Indexed on encounter_date for
-- date-range filtering.
-- ------------------------------------------------------------
CREATE TABLE encounters (
    encounter_id   INT PRIMARY KEY,
    patient_id     INT,
    provider_id    INT,
    encounter_type VARCHAR(50),   -- 'Outpatient', 'Inpatient', 'ER'
    encounter_date DATETIME,
    discharge_date DATETIME,
    department_id  INT,
    FOREIGN KEY (patient_id)    REFERENCES patients(patient_id),
    FOREIGN KEY (provider_id)   REFERENCES providers(provider_id),
    FOREIGN KEY (department_id) REFERENCES departments(department_id),
    INDEX idx_encounter_date (encounter_date)
);

-- ------------------------------------------------------------
-- Table: encounter_diagnoses (junction / many-to-many)
-- One row per diagnosis recorded on an encounter.
-- diagnosis_sequence: 1 = primary, 2+ = secondary.
-- ------------------------------------------------------------
CREATE TABLE encounter_diagnoses (
    encounter_diagnosis_id INT PRIMARY KEY,
    encounter_id           INT,
    diagnosis_id           INT,
    diagnosis_sequence     INT,
    FOREIGN KEY (encounter_id) REFERENCES encounters(encounter_id),
    FOREIGN KEY (diagnosis_id) REFERENCES diagnoses(diagnosis_id)
);

-- ------------------------------------------------------------
-- Table: encounter_procedures (junction / many-to-many)
-- One row per procedure performed during an encounter.
-- ------------------------------------------------------------
CREATE TABLE encounter_procedures (
    encounter_procedure_id INT PRIMARY KEY,
    encounter_id           INT,
    procedure_id           INT,
    procedure_date         DATE,
    FOREIGN KEY (encounter_id) REFERENCES encounters(encounter_id),
    FOREIGN KEY (procedure_id) REFERENCES procedures(procedure_id)
);

-- ------------------------------------------------------------
-- Table: billing
-- Insurance claim per encounter. claim_amount = billed,
-- allowed_amount = approved by payer (used for revenue).
-- DECIMAL keeps money exact. Indexed on claim_date.
-- ------------------------------------------------------------
CREATE TABLE billing (
    billing_id     INT PRIMARY KEY,
    encounter_id   INT,
    claim_amount   DECIMAL(12, 2),
    allowed_amount DECIMAL(12, 2),
    claim_date     DATE,
    claim_status   VARCHAR(50),
    FOREIGN KEY (encounter_id) REFERENCES encounters(encounter_id),
    INDEX idx_claim_date (claim_date)
);
