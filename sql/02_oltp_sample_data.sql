-- ============================================================
-- 02_oltp_sample_data.sql
-- Part 1: Sample data from the lab brief.
-- Run AFTER 01_oltp_schema.sql. Run ONCE (re-running gives
-- duplicate-key errors).
-- FIX: the brief inserts billing BEFORE encounters, which
-- breaks billing's foreign key (Error 1452). Here, inserts are
-- ordered parents -> children, so billing is loaded last.
-- ============================================================
USE healthcare_oltp;

-- Level 1-2: lookups, providers, patients ---------------------
INSERT INTO specialties VALUES
    (1, 'Cardiology', 'CARD'),
    (2, 'Internal Medicine', 'IM'),
    (3, 'Emergency', 'ER');

INSERT INTO departments VALUES
    (1, 'Cardiology Unit', 3, 20),
    (2, 'Internal Medicine', 2, 30),
    (3, 'Emergency', 1, 45);

INSERT INTO providers VALUES
    (101, 'James', 'Chen', 'MD', 1, 1),
    (102, 'Sarah', 'Williams', 'MD', 2, 2),
    (103, 'Michael', 'Rodriguez', 'MD', 3, 3);

INSERT INTO patients VALUES
    (1001, 'John', 'Doe', '1955-03-15', 'M', 'MRN001'),
    (1002, 'Jane', 'Smith', '1962-07-22', 'F', 'MRN002'),
    (1003, 'Robert', 'Johnson', '1948-11-08', 'M', 'MRN003');

INSERT INTO diagnoses VALUES
    (3001, 'I10', 'Hypertension'),
    (3002, 'E11.9', 'Type 2 Diabetes'),
    (3003, 'I50.9', 'Heart Failure');

INSERT INTO procedures VALUES
    (4001, '99213', 'Office Visit'),
    (4002, '93000', 'EKG'),
    (4003, '71020', 'Chest X-ray');
    
    -- Level 3: encounters (must exist BEFORE anything that points to them)
INSERT INTO encounters VALUES
    (7001, 1001, 101, 'Outpatient', '2024-05-10 10:00:00', '2024-05-10 11:30:00', 1),
    (7002, 1001, 101, 'Inpatient',  '2024-06-02 14:00:00', '2024-06-06 09:00:00', 1),
    (7003, 1002, 102, 'Outpatient', '2024-05-15 09:00:00', '2024-05-15 10:15:00', 2),
    (7004, 1003, 103, 'ER',         '2024-06-12 23:45:00', '2024-06-13 06:30:00', 3);

-- Level 4: children of encounters --------------------------------
INSERT INTO encounter_diagnoses VALUES
    (8001, 7001, 3001, 1), (8002, 7001, 3002, 2),
    (8003, 7002, 3001, 1), (8004, 7002, 3003, 2),
    (8005, 7003, 3002, 1), (8006, 7004, 3001, 1);

INSERT INTO encounter_procedures VALUES
    (9001, 7001, 4001, '2024-05-10'), (9002, 7001, 4002, '2024-05-10'),
    (9003, 7002, 4001, '2024-06-02'), (9004, 7003, 4001, '2024-05-15');

-- FIX: billing moved here (after encounters) -----------------------
INSERT INTO billing VALUES
    (14001, 7001, 350, 280, '2024-05-11', 'Paid'),
    (14002, 7002, 12500, 10000, '2024-06-08', 'Paid');