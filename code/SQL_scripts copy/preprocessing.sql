-- 1) Remove duplicate patient records.
DROP TABLE IF EXISTS `aise3010-492923.aise_3010_final_project.patients_dedup`;
CREATE TABLE `aise3010-492923.aise_3010_final_project.patients_dedup` AS
SELECT patient_nbr, age, gender, race
FROM (
  SELECT p.*, ROW_NUMBER() OVER (PARTITION BY patient_nbr ORDER BY patient_nbr) AS rn
  FROM `aise3010-492923.aise_3010_final_project.Patients` p
) s
WHERE rn = 1;

-- 2) Remove duplicate encounter records.
DROP TABLE IF EXISTS `aise3010-492923.aise_3010_final_project.encounters_dedup`;
CREATE TABLE `aise3010-492923.aise_3010_final_project.encounters_dedup` AS
SELECT encounter_id, patient_nbr, time_in_hospital, number_outpatient, number_emergency, number_inpatient, readmitted_label
FROM (
  SELECT e.*, ROW_NUMBER() OVER (PARTITION BY encounter_id ORDER BY encounter_id) AS rn
  FROM `aise3010-492923.aise_3010_final_project.Encounters` e
) s
WHERE rn = 1;

-- 3) Remove duplicate treatment records.
DROP TABLE IF EXISTS `aise3010-492923.aise_3010_final_project.treatments_dedup`;
CREATE TABLE `aise3010-492923.aise_3010_final_project.treatments_dedup` AS
SELECT encounter_id, num_medications, num_lab_procedures, num_procedures, insulin, `change`, diabetesMed
FROM (
  SELECT t.*, ROW_NUMBER() OVER (PARTITION BY encounter_id ORDER BY encounter_id) AS rn
  FROM `aise3010-492923.aise_3010_final_project.Treatments` t
) s
WHERE rn = 1;

-- 4) Remove duplicate diagnosis records.
DROP TABLE IF EXISTS `aise3010-492923.aise_3010_final_project.diagnoses_dedup`;
CREATE TABLE `aise3010-492923.aise_3010_final_project.diagnoses_dedup` AS
SELECT encounter_id, diag_seq, diag_code
FROM (
  SELECT d.*, ROW_NUMBER() OVER (PARTITION BY encounter_id, diag_seq ORDER BY encounter_id, diag_seq) AS rn
  FROM `aise3010-492923.aise_3010_final_project.Diagnoses` d
) s
WHERE rn = 1;

-- 5) Clean patient categorical values (Made robust against auto-detect).
DROP TABLE IF EXISTS `aise3010-492923.aise_3010_final_project.patients_clean`;
CREATE TABLE `aise3010-492923.aise_3010_final_project.patients_clean` AS
SELECT
  patient_nbr,
  COALESCE(NULLIF(TRIM(CAST(age AS STRING)), ''), 'Unknown') AS age,
  COALESCE(NULLIF(TRIM(CAST(gender AS STRING)), ''), 'Unknown') AS gender,
  COALESCE(NULLIF(TRIM(CAST(race AS STRING)), ''), 'Unknown') AS race
FROM `aise3010-492923.aise_3010_final_project.patients_dedup`;

-- 6) Clean encounter numeric values and target.
DROP TABLE IF EXISTS `aise3010-492923.aise_3010_final_project.encounters_clean`;
CREATE TABLE `aise3010-492923.aise_3010_final_project.encounters_clean` AS
SELECT
  encounter_id,
  patient_nbr,
  COALESCE(time_in_hospital, 0) AS time_in_hospital,
  COALESCE(number_outpatient, 0) AS number_outpatient,
  COALESCE(number_emergency, 0) AS number_emergency,
  COALESCE(number_inpatient, 0) AS number_inpatient,
  COALESCE(readmitted_label, 0) AS readmitted_label
FROM `aise3010-492923.aise_3010_final_project.encounters_dedup`;

-- 7) Clean treatment values (Made robust against auto-detect).
DROP TABLE IF EXISTS `aise3010-492923.aise_3010_final_project.treatments_clean`;
CREATE TABLE `aise3010-492923.aise_3010_final_project.treatments_clean` AS
SELECT
  encounter_id,
  COALESCE(num_medications, 0) AS num_medications,
  COALESCE(num_lab_procedures, 0) AS num_lab_procedures,
  COALESCE(num_procedures, 0) AS num_procedures,
  COALESCE(NULLIF(TRIM(CAST(insulin AS STRING)), ''), 'Unknown') AS insulin,
  COALESCE(NULLIF(TRIM(CAST(`change` AS STRING)), ''), 'No') AS change_flag,
  -- Handle diabetesMed whether BigQuery sees it as a Bool or a String
  CASE
    WHEN CAST(diabetesMed AS STRING) IN ('Yes', 'true', 'True', '1') THEN 'Yes'
    ELSE 'No'
  END AS diabetesMed
FROM `aise3010-492923.aise_3010_final_project.treatments_dedup`;

-- 8) Pivot diagnosis rows to wide columns for modeling.
DROP TABLE IF EXISTS `aise3010-492923.aise_3010_final_project.diagnoses_wide`;
CREATE TABLE `aise3010-492923.aise_3010_final_project.diagnoses_wide` AS
SELECT
  encounter_id,
  MAX(CASE WHEN diag_seq = 1 THEN diag_code END) AS diag_1,
  MAX(CASE WHEN diag_seq = 2 THEN diag_code END) AS diag_2,
  MAX(CASE WHEN diag_seq = 3 THEN diag_code END) AS diag_3
FROM `aise3010-492923.aise_3010_final_project.diagnoses_dedup`
GROUP BY encounter_id;

-- 9) Build final clean joined dataset.
DROP TABLE IF EXISTS `aise3010-492923.aise_3010_final_project.diabetes_clean`;
CREATE TABLE `aise3010-492923.aise_3010_final_project.diabetes_clean` AS
SELECT
  e.encounter_id,
  e.patient_nbr,
  p.age,
  p.gender,
  p.race,
  e.time_in_hospital,
  t.num_medications,
  t.num_lab_procedures,
  t.num_procedures,
  e.number_outpatient,
  e.number_emergency,
  e.number_inpatient,
  e.readmitted_label,
  t.insulin,
  t.change_flag,
  t.diabetesMed,
  COALESCE(CAST(d.diag_1 AS STRING), 'UNK') AS diag_1,
  COALESCE(CAST(d.diag_2 AS STRING), 'UNK') AS diag_2,
  COALESCE(CAST(d.diag_3 AS STRING), 'UNK') AS diag_3
FROM `aise3010-492923.aise_3010_final_project.encounters_clean` e
JOIN `aise3010-492923.aise_3010_final_project.patients_clean` p ON p.patient_nbr = e.patient_nbr
JOIN `aise3010-492923.aise_3010_final_project.treatments_clean` t ON t.encounter_id = e.encounter_id
LEFT JOIN `aise3010-492923.aise_3010_final_project.diagnoses_wide` d ON d.encounter_id = e.encounter_id;