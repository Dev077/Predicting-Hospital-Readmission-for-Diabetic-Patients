DROP TABLE IF EXISTS `aise3010-492923.aise_3010_final_project.diabetes_features`;
CREATE TABLE `aise3010-492923.aise_3010_final_project.diabetes_features` AS
SELECT
  -- Classification target
  readmitted_label AS target,

  -- Base numeric features
  time_in_hospital,
  num_medications,
  num_lab_procedures,
  num_procedures,
  number_outpatient,
  number_emergency,
  number_inpatient,

  -- Engineered utilization features
  (number_outpatient + number_emergency + number_inpatient) AS utilization_total,
  CASE
    WHEN time_in_hospital > 0 THEN CAST(num_medications AS FLOAT64) / time_in_hospital
    ELSE 0
  END AS meds_per_day,
  CASE
    WHEN time_in_hospital > 0 THEN CAST(num_procedures AS FLOAT64) / time_in_hospital
    ELSE 0
  END AS procedures_per_day,

  -- Binary flags
  CASE WHEN diabetesMed = 'Yes' THEN 1 ELSE 0 END AS diabetesmed_flag,
  CASE WHEN insulin IN ('Up', 'Down', 'Steady') THEN 1 ELSE 0 END AS insulin_used_flag,
  CASE WHEN change_flag = 'Ch' THEN 1 ELSE 0 END AS med_changed_flag,
  CASE WHEN number_inpatient >= 2 THEN 1 ELSE 0 END AS high_inpatient_flag,

  -- Age bucket to numeric midpoint
  CASE age
    WHEN '[0-10)' THEN 5
    WHEN '[10-20)' THEN 15
    WHEN '[20-30)' THEN 25
    WHEN '[30-40)' THEN 35
    WHEN '[40-50)' THEN 45
    WHEN '[50-60)' THEN 55
    WHEN '[60-70)' THEN 65
    WHEN '[70-80)' THEN 75
    WHEN '[80-90)' THEN 85
    WHEN '[90-100)' THEN 95
    ELSE NULL
  END AS age_mid,

  -- Keep useful categorical columns
  gender,
  race,
  insulin,
  change_flag,
  diabetesMed,

  -- Group diagnosis code prefixes using BigQuery syntax
  SUBSTR(CAST(diag_1 AS STRING), 1, 3) AS diag1_grp,
  SUBSTR(CAST(diag_2 AS STRING), 1, 3) AS diag2_grp,
  SUBSTR(CAST(diag_3 AS STRING), 1, 3) AS diag3_grp

FROM `aise3010-492923.aise_3010_final_project.diabetes_clean`;