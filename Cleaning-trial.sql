-- =============================================================================
-- PROJECT: Clinical Trial Adverse Events — Data Cleaning
-- Author:  Bruno Inuggi
--          Nutritionist turned Data Scientist | MSc Data Science, UCM Madrid
-- Tool:    Snowflake
-- DB:      CLINICAL_TRIAL_CLEANING.PUBLIC
-- =============================================================================
--
-- This script documents the full data cleaning pipeline for a simulated adverse events dataset. The goal was to identify and handle data quality issues systematically — working from structural problems down to individual value errors, not the other way around.
--
-- As someone with a clinical background, a lot of the decisions taken goes in order to reflect what's actually possible in a real patient scenario. That perspective shaped both what I flagged and what I chose to exclude vs. keep.
--
-- TABLES
--   ADVERSE_EVENTS  — 10,000 rows  — adverse event reports
--   PATIENTS        —  3,000 rows  — patient demographics
--   DRUGS           —    100 rows  — approved drug reference data
--
-- CLEANING PIPELINE (all views — raw data is never touched)
--   ADVERSE_EVENTS
--     raw              10,000
--     → RI_CLEAN        9,043   [S1]  orphan drug/patient IDs removed
--     → LOGIC_CLEAN     4,119   [S2]  impossible event dates removed
--     → DOSE_CLEAN      4,119   [S3]  dose classification added (flag only)
--     → CLEAN           3,748   [S3]  invalid doses excluded
--     → FINAL           3,748   [S4]  null outcomes flagged, days_to_event added
--
--   PATIENTS
--     raw               3,000
--     → CLEAN           2,707   [S2]  impossible ages excluded
--     → FINAL           2,707   [S4]  BMI calculated, quality flags added
--
-- =============================================================================

USE DATABASE CLINICAL_TRIAL_CLEANING;
USE SCHEMA PUBLIC;

-- =============================================================================
-- SECTION 1: REFERENTIAL INTEGRITY
-- =============================================================================
-- First things first — before looking at individual values, I need to make sure the relationships between tables actually hold. An adverse event record that points to a patient or drug that doesn't exist in the reference tables is essentially useless for any downstream analysis.
--
-- What I found:
--   - 382 orphan drug_ids (all starting with 888)   → 471 events affected
--   - 384 orphan patient_ids (all starting with 999) → 486 events affected
--   - 17 events had both problems at the same time
--   - Total removed: 957 events (9.57%)
-- =============================================================================


-- 1.1 Which drug_ids in ADVERSE_EVENTS don't exist in DRUGS?
-- Without a matching drug record, we can't validate the dose or know the therapeutic class, two things that matter a lot for safety analysis.

SELECT
    ae.drug_id,
    COUNT(*) AS orphan_event_count
FROM ADVERSE_EVENTS ae
LEFT JOIN DRUGS d ON ae.drug_id = d.drug_id
WHERE d.drug_id IS NULL
GROUP BY ae.drug_id
ORDER BY orphan_event_count DESC;

-- How many events are actually affected?
SELECT
    COUNT(*) AS total_events,
    SUM(CASE WHEN d.drug_id IS NULL THEN 1 ELSE 0 END) AS orphan_drug_events,
    ROUND(SUM(CASE WHEN d.drug_id IS NULL THEN 1 ELSE 0 END)
          * 100 / COUNT(*), 2) AS pct_orphan_drug
FROM ADVERSE_EVENTS ae
LEFT JOIN DRUGS d ON ae.drug_id = d.drug_id;


-- 1.2 Same check for patient_ids.
-- No patient record = no age, sex, diagnosis or comorbidity context. These records can't support any kind of clinical subgroup analysis.

SELECT
    ae.patient_id,
    COUNT(*) AS orphan_event_count
FROM ADVERSE_EVENTS ae
LEFT JOIN PATIENTS p ON ae.patient_id = p.patient_id
WHERE p.patient_id IS NULL
GROUP BY ae.patient_id
ORDER BY orphan_event_count DESC;

SELECT
    COUNT(*) AS total_events,
    SUM(CASE WHEN p.patient_id IS NULL THEN 1 ELSE 0 END) AS orphan_patient_events,
    ROUND(SUM(CASE WHEN p.patient_id IS NULL THEN 1 ELSE 0 END)
          * 100.0 / COUNT(*), 2) AS pct_orphan_patient
FROM ADVERSE_EVENTS ae
LEFT JOIN PATIENTS p ON ae.patient_id = p.patient_id;


-- 1.3 How much overlap is there between the two problems?
-- Important for avoiding double-counting when estimating total exclusions.

SELECT
    COUNT(*) AS both_orphan
FROM ADVERSE_EVENTS ae
LEFT JOIN DRUGS    d ON ae.drug_id    = d.drug_id
LEFT JOIN PATIENTS p ON ae.patient_id = p.patient_id
WHERE d.drug_id IS NULL AND p.patient_id IS NULL;


-- -----------------------------------------------------------------------------
-- WHY A VIEW AND NOT DELETE?
-- I could have just deleted these rows, but that would destroy the audit trail. Using a view keeps the raw data intact, makes the exclusion logic visible and reviewable, and means the view automatically updates if the source tables ever change.
-- -----------------------------------------------------------------------------


-- 1.4 ACTION — View with referential integrity guaranteed

CREATE OR REPLACE VIEW ADVERSE_EVENTS_RI_CLEAN AS
SELECT
    ae.event_id,
    ae.patient_id,
    ae.drug_id,
    ae.event_date,
    ae.drug_start_date,
    ae.adverse_event_type,
    ae.severity,
    ae.outcome,
    ae.dose_mg,
    ae.report_source,
    ae.country
FROM ADVERSE_EVENTS ae
INNER JOIN DRUGS    d ON ae.drug_id    = d.drug_id
INNER JOIN PATIENTS p ON ae.patient_id = p.patient_id;


-- 1.5 Verify — confirm row counts and zero orphans remaining

SELECT 'ADVERSE_EVENTS (raw)'AS version, COUNT(*) AS row_count FROM ADVERSE_EVENTS
UNION ALL
SELECT 'ADVERSE_EVENTS_RI_CLEAN', COUNT(*) AS row_count FROM ADVERSE_EVENTS_RI_CLEAN;
-- Results: 10,000 → 9,043

SELECT COUNT(*) AS orphans_remaining
FROM ADVERSE_EVENTS_RI_CLEAN ae
LEFT JOIN DRUGS d ON ae.drug_id = d.drug_id
LEFT JOIN PATIENTS p ON ae.patient_id = p.patient_id
WHERE d.drug_id IS NULL OR p.patient_id IS NULL;
-- Results: 0


-- =============================================================================
-- SECTION 2: LOGICAL INCONSISTENCIES
-- =============================================================================
-- Now that the joins are clean, I can look if the values themselves make sense. This is where clinical background starts to matter, meanwhile some of these issues aren't obvious. Ill try to flag them by having a clinical view of what's actually possible in a patient context. 
--
-- What I found:
--   - 4,924 events where the adverse event date is before the drug start date (54.45% of remaining records — clearly injected intentionally)
--   - 293 patients with age > 110 (9.77%)
--   - 7 pediatric patients (age < 18) with weight > 100kg — flagged, not excluded
-- =============================================================================


-- 2.1 Events where the adverse event happened before the drug was even started. This is clinically impossible — you can't have a drug reaction before exposure.
-- A 54% rate tells me this was introduced systematically in the test dataset.

SELECT
    COUNT(*) AS total_events,
    SUM(CASE WHEN event_date < drug_start_date THEN 1 ELSE 0 END) AS impossible_dates,
    ROUND(SUM(CASE WHEN event_date < drug_start_date THEN 1 ELSE 0 END)
        * 100.0 / COUNT(*),2)AS pct_impossible
FROM ADVERSE_EVENTS_RI_CLEAN;

-- A few examples to confirm the pattern
SELECT
    event_id,
    patient_id,
    drug_id,
    event_date,
    drug_start_date,
    DATEDIFF('day', drug_start_date, event_date) AS days_difference
FROM ADVERSE_EVENTS_RI_CLEAN
WHERE event_date < drug_start_date
ORDER BY days_difference
LIMIT 20;


-- 2.2 Patients with impossible ages.
-- I'm using 110 as a conservative clinical cutoff — anything above that is almost certainly a data entry error.

SELECT
    COUNT(*) AS total_patients,
    SUM(CASE WHEN age > 110 THEN 1 ELSE 0 END) AS impossible_age,
    SUM(CASE WHEN age < 0   THEN 1 ELSE 0 END) AS negative_age,
    ROUND(
        SUM(CASE WHEN age > 110 OR age < 0 THEN 1 ELSE 0 END)* 100.0 / COUNT(*),2)AS pct_impossible_age
FROM PATIENTS;

-- How are these distributed?
SELECT age,COUNT(*) AS count
FROM PATIENTS
WHERE age > 110
GROUP BY age
ORDER BY age;


-- 2.3 Pediatric patients with adult-level weight.
-- A child under 18 weighing over 100kg is clinically implausible in most cases but not impossible. Severe pediatric obesity exists, and automatically excluding these records could introduce bias in any analysis involving pediatric subgroups.
-- Flagging them for review rather than removing them outright.

SELECT
    patient_id,
    age,
    weight_kg,
    diagnosis
FROM PATIENTS
WHERE age < 18 AND weight_kg > 100
ORDER BY weight_kg DESC;


-- -----------------------------------------------------------------------------
-- DECISIONS
-- 2.1 event_date < drug_start_date → excluded.
--     There's no valid clinical scenario where an adverse event precedes drug exposure. Correcting the dates would be ideal, but since I can't acces to the source, exclusion is the only viable choice.
--
-- 2.2 age > 110 → excluded.
--     Threshold of 110 is conservative but clinically justified.
--     No negative ages were found in this dataset.
--
-- 2.3 age < 18 with weight > 100kg → flagged, not excluded.
--     Extreme pediatric obesity is rare but real. Whether these records should be included depends on the research question leaving the decision to whoever uses the data downstream.
-- -----------------------------------------------------------------------------


-- 2.4 ACTION — Clean view with impossible dates removed

CREATE OR REPLACE VIEW ADVERSE_EVENTS_LOGIC_CLEAN AS
SELECT *
FROM ADVERSE_EVENTS_RI_CLEAN
WHERE event_date >= drug_start_date;


-- 2.5 ACTION — Clean patients view

CREATE OR REPLACE VIEW PATIENTS_CLEAN AS
SELECT
    patient_id,
    age,
    sex,
    weight_kg,
    height_cm,
    diagnosis,
    comorbidities,
    country,
    CASE
        WHEN age < 18 AND weight_kg > 100 THEN 'flag_review'
        ELSE 'ok'
    END AS data_quality_flag
FROM PATIENTS
WHERE age <= 110
  AND age >= 0;


-- 2.6 Verify

SELECT 'ADVERSE_EVENTS_RI_CLEAN' AS version, COUNT(*) AS row_count FROM ADVERSE_EVENTS_RI_CLEAN
UNION ALL
SELECT 'ADVERSE_EVENTS_LOGIC_CLEAN',COUNT(*) AS row_count FROM ADVERSE_EVENTS_LOGIC_CLEAN
UNION ALL
SELECT 'PATIENTS (raw)', COUNT(*) AS row_count FROM PATIENTS
UNION ALL
SELECT 'PATIENTS_CLEAN', COUNT(*) AS row_count FROM PATIENTS_CLEAN;
-- Expected: 9,043 → 4,119 | 3,000 → 2,707


-- =============================================================================
-- SECTION 3: OUTLIERS — DOSE_MG
-- =============================================================================
-- Dose is one of the most clinically meaningful variables in this dataset.
-- An adverse event linked to a dose of 4,714mg when the approved maximum is ~200mg isn't just an outlier — it's almost certainly a data entry error.
-- To validate doses properly, I'm comparing against the approved range per drug from the DRUGS reference table.
--
-- What I found:
--   Negative doses:   33 events  (0.80%)
--   Above maximum:   193 events  (4.69%)
--   Below minimum:   145 events  (3.52%)
--   Null doses:      201 events  (4.88%) — retained with flag
--   Total excluded:  371 events
-- =============================================================================


-- 3.1 Statistical overview of dose_mg before making any decisions.

SELECT
    COUNT(*) AS total_events,
    COUNT(dose_mg) AS non_null_doses,
    COUNT(*) - COUNT(dose_mg) AS null_doses,
    ROUND(MIN(dose_mg), 2) AS min_dose,
    ROUND(MAX(dose_mg), 2) AS max_dose,
    ROUND(AVG(dose_mg), 2) AS avg_dose,
    ROUND(PERCENTILE_CONT(0.25) WITHIN GROUP (ORDER BY dose_mg), 2) AS p25,
    ROUND(PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY dose_mg), 2) AS median,
    ROUND(PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY dose_mg), 2) AS p75,
    ROUND(PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY dose_mg), 2) AS p95,
    ROUND(PERCENTILE_CONT(0.99) WITHIN GROUP (ORDER BY dose_mg), 2) AS p99
FROM ADVERSE_EVENTS_LOGIC_CLEAN;


-- 3.2 Negative doses a dose can't be negative.

SELECT COUNT(*) AS negative_doses
FROM ADVERSE_EVENTS_LOGIC_CLEAN
WHERE dose_mg < 0;

SELECT event_id, drug_id, dose_mg
FROM ADVERSE_EVENTS_LOGIC_CLEAN
WHERE dose_mg < 0
ORDER BY dose_mg
LIMIT 20;


-- 3.3 Doses outside the approved range for each specific drug.
-- Generic thresholds aren't enough here, a dose of 200mg might be fine for one drug and a 10x overdose for another. That's why I'm comparing against the per-drug approved range from the DRUGS reference table.

SELECT
    ae.event_id,
    ae.drug_id,
    d.drug_name,
    d.therapeutic_class,
    ae.dose_mg,
    d.approved_dose_min,
    d.approved_dose_max,
    CASE
        WHEN ae.dose_mg < d.approved_dose_min THEN 'below_minimum'
        WHEN ae.dose_mg > d.approved_dose_max THEN 'above_maximum'
        ELSE 'within_range'
    END AS dose_status
FROM ADVERSE_EVENTS_LOGIC_CLEAN ae
JOIN DRUGS d ON ae.drug_id = d.drug_id
WHERE ae.dose_mg IS NOT NULL
ORDER BY dose_status, ae.dose_mg DESC
LIMIT 50;

-- Summary by category
SELECT
    CASE
        WHEN ae.dose_mg < d.approved_dose_min THEN 'below_minimum'
        WHEN ae.dose_mg > d.approved_dose_max THEN 'above_maximum'
        ELSE 'within_range'
    END                                                AS dose_status,
    COUNT(*)                                           AS count,
    ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER(), 2) AS pct
FROM ADVERSE_EVENTS_LOGIC_CLEAN ae
JOIN DRUGS d ON ae.drug_id = d.drug_id
WHERE ae.dose_mg IS NOT NULL
GROUP BY dose_status
ORDER BY count DESC;

-- 3.4 Are null doses random, or concentrated in specific groups?
-- If nulls cluster around a specific event type or severity level, that's a reporting pattern worth documenting.

SELECT
    adverse_event_type,
    severity,
    COUNT(*) AS total,
    SUM(CASE WHEN dose_mg IS NULL THEN 1 ELSE 0 END) AS null_doses,
    ROUND(
        SUM(CASE WHEN dose_mg IS NULL THEN 1 ELSE 0 END)
        * 100.0 / COUNT(*),2)AS pct_null
FROM ADVERSE_EVENTS_LOGIC_CLEAN
GROUP BY adverse_event_type, severity
ORDER BY pct_null DESC;


-- -----------------------------------------------------------------------------
-- DECISIONS
-- Negative doses → excluded. No clinical interpretation possible.
--
-- Above maximum → excluded. A dose of 4,714mg vs. a ~200mg ceiling isn't a borderline case, it's almost certainly a data entry error. Even in intentional overdose scenarios, this dataset doesn't have the context to support that interpretation.
--
-- Below minimum → excluded. These are more likely entry errors than actual clinical scenarios.
--
-- Null doses → retained with flag. A missing dose value doesn't mean the adverse event didn't happen. Patient-reported events often lack precise dosage data, excluding them would skew the dataset toward hospital-reported cases and introduce reporting bias.
-- -----------------------------------------------------------------------------


-- 3.5 ACTION — Dose classification view + final clean view

CREATE OR REPLACE VIEW ADVERSE_EVENTS_DOSE_CLEAN AS
SELECT
    ae.event_id,
    ae.patient_id,
    ae.drug_id,
    ae.event_date,
    ae.drug_start_date,
    ae.adverse_event_type,
    ae.severity,
    ae.outcome,
    ae.dose_mg,
    ae.report_source,
    ae.country,
    CASE
        WHEN ae.dose_mg IS NULL THEN 'null_dose'
        WHEN ae.dose_mg < 0 THEN 'negative'
        WHEN ae.dose_mg < d.approved_dose_min THEN 'below_minimum'
        WHEN ae.dose_mg > d.approved_dose_max THEN 'above_maximum'
        ELSE 'valid'
    END AS dose_status
FROM ADVERSE_EVENTS_LOGIC_CLEAN ae
JOIN DRUGS d ON ae.drug_id = d.drug_id;

-- Final view: valid doses and null doses only
CREATE OR REPLACE VIEW ADVERSE_EVENTS_CLEAN AS
SELECT *
FROM ADVERSE_EVENTS_DOSE_CLEAN
WHERE dose_status IN ('valid', 'null_dose');


-- 3.6 Verify

SELECT 'ADVERSE_EVENTS_LOGIC_CLEAN' AS version, COUNT(*) AS row_count FROM ADVERSE_EVENTS_LOGIC_CLEAN
UNION ALL
SELECT 'ADVERSE_EVENTS_DOSE_CLEAN',COUNT(*) AS row_count FROM ADVERSE_EVENTS_DOSE_CLEAN
UNION ALL
SELECT 'ADVERSE_EVENTS_CLEAN',COUNT(*) AS row_count FROM ADVERSE_EVENTS_CLEAN;
-- Expected: 4,119 → 4,119 (flag only) → 3,748

SELECT
    dose_status,
    COUNT(*) AS count,
    ROUND(COUNT(*) * 100 / SUM(COUNT(*)) OVER(), 2) AS pct
FROM ADVERSE_EVENTS_DOSE_CLEAN
GROUP BY dose_status
ORDER BY count DESC;


-- =============================================================================
-- SECTION 4: NULL VALUES
-- =============================================================================
-- Last step — handling the remaining nulls. By this point the structural and logical issues are resolved, so these are just missing values to document and decide on. Neither of the remaining null columns is critical enough to justify excluding records over.
--
-- Remaining nulls:
--   outcome    (ADVERSE_EVENTS): 201 records — flagged as 'unknown'
--   height_cm  (PATIENTS):        97 records — BMI set to NULL where missing
-- =============================================================================


-- 4.1 Are null outcomes random, or do they concentrate in specific groups? If they cluster around patient-reported events, that's expected behavior.. patients often don't follow up the same way hospitals do.

SELECT
    severity,
    adverse_event_type,
    COUNT(*) AS total,
    SUM(CASE WHEN outcome IS NULL THEN 1 ELSE 0 END)  AS null_outcome,
    ROUND(
        SUM(CASE WHEN outcome IS NULL THEN 1 ELSE 0 END)* 100 / COUNT(*),2) AS pct_null
FROM ADVERSE_EVENTS_CLEAN
GROUP BY severity, adverse_event_type
ORDER BY pct_null DESC;

-- Distribution of non-null outcomes for reference
SELECT
    outcome,
    COUNT(*)AS count,
    ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER(), 2) AS pct
FROM ADVERSE_EVENTS_CLEAN
GROUP BY outcome
ORDER BY count DESC;


-- 4.2 Are null heights random across sex and diagnosis groups?

SELECT
    sex, diagnosis,
    COUNT(*) AS total,
    SUM(CASE WHEN height_cm IS NULL THEN 1 ELSE 0 END)    AS null_height,
    ROUND(
        SUM(CASE WHEN height_cm IS NULL THEN 1 ELSE 0 END)* 100/ COUNT(*),2) AS pct_null
FROM PATIENTS_CLEAN
GROUP BY sex, diagnosis
ORDER BY pct_null DESC;

-- Height distribution for reference
SELECT
    ROUND(MIN(height_cm), 1) AS min_height,
    ROUND(MAX(height_cm), 1) AS max_height,
    ROUND(AVG(height_cm), 1) AS avg_height,
    ROUND(PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY height_cm), 1) AS median_height
FROM PATIENTS_CLEAN
WHERE height_cm IS NOT NULL;


-- -----------------------------------------------------------------------------
-- DECISIONS
-- outcome nulls → retained, flagged as 'unknown'.
--     A missing outcome doesn't mean the event didn't happen or wasn't real. It usually just means no follow-up was recorded — which is especially common in patient-reported cases. Excluding these would skew the data toward hospital reports and underrepresent certain patient populations.
-- height_cm nulls → retained.
--     Height isn't needed for most adverse event analyses. BMI is calculated where both height and weight are available, and set to NULL otherwise. If a specific analysis requires BMI, those records can be filtered out when its needed
-- -----------------------------------------------------------------------------


-- 4.3 ACTION — Final ADVERSE_EVENTS view
-- Added: days_to_event (derived from date diff), outcome_clean (null → 'unknown')

CREATE OR REPLACE VIEW ADVERSE_EVENTS_FINAL AS
SELECT
    event_id, patient_id, drug_id,event_date, drug_start_date,
    DATEDIFF('day',drug_start_date, event_date) AS days_to_event,
    adverse_event_type,
    severity,
    outcome,
    CASE
        WHEN outcome IS NULL THEN 'unknown'
        ELSE outcome
    END AS outcome_clean,
    dose_mg,
    dose_status,
    report_source,
    country
FROM ADVERSE_EVENTS_CLEAN;


-- 4.4 ACTION — Final PATIENTS view
-- Added: bmi (calculated from weight_kg and height_cm where available)

CREATE OR REPLACE VIEW PATIENTS_FINAL AS
SELECT
    patient_id,
    age,
    sex,
    weight_kg,
    height_cm,
    CASE
        WHEN height_cm IS NOT NULL AND weight_kg IS NOT NULL
        THEN ROUND(weight_kg / POWER(height_cm / 100.0, 2), 1)
        ELSE NULL
    END AS bmi,
    diagnosis,
    comorbidities,
    country,
    data_quality_flag
FROM PATIENTS_CLEAN;


-- 4.5 Full pipeline verification

SELECT 'ADVERSE_EVENTS (raw)' AS version, COUNT(*) AS row_count FROM ADVERSE_EVENTS
UNION ALL
SELECT 'ADVERSE_EVENTS_RI_CLEAN', COUNT(*) AS row_count FROM ADVERSE_EVENTS_RI_CLEAN
UNION ALL
SELECT 'ADVERSE_EVENTS_LOGIC_CLEAN', COUNT(*) AS row_count FROM ADVERSE_EVENTS_LOGIC_CLEAN
UNION ALL
SELECT 'ADVERSE_EVENTS_CLEAN',COUNT(*) AS row_count FROM ADVERSE_EVENTS_CLEAN
UNION ALL
SELECT 'ADVERSE_EVENTS_FINAL',COUNT(*) AS row_count FROM ADVERSE_EVENTS_FINAL
UNION ALL
SELECT '---', NULL
UNION ALL
SELECT 'PATIENTS (raw)',COUNT(*) AS row_count FROM PATIENTS
UNION ALL
SELECT 'PATIENTS_CLEAN',COUNT(*) AS row_count FROM PATIENTS_CLEAN
UNION ALL
SELECT 'PATIENTS_FINAL', COUNT(*) AS row_count FROM PATIENTS_FINAL;
-- Expected:
--   ADVERSE_EVENTS:  10,000 → 9,043 → 4,119 → 3,748 → 3,748
--   PATIENTS:         3,000 → 2,707 → 2,707
