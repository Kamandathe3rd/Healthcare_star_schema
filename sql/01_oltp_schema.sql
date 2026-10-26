-- ============================================================
-- 01_oltp_schema.sql
-- Part 1: Normalized OLTP schema (3NF) for the healthcare lab
-- Run on: MySQL 8.0
-- ============================================================

-- Which MySQL version am I on? (record this in the README)
SELECT VERSION();

-- Create the OLTP database only if it doesn't exist yet
CREATE DATABASE IF NOT EXISTS healthcare_oltp;

-- Work inside it from now on
USE healthcare_oltp;

-- Confirm which database is active
SELECT DATABASE();
