-- 1) Basic row counts and null checks.
SELECT COUNT(*) AS total_rows FROM `aise3010-492923.aise_3010_final_project.diabetes_features`;

SELECT
  SUM(CASE WHEN target IS NULL THEN 1 ELSE 0 END) AS null_target,
  SUM(CASE WHEN age_mid IS NULL THEN 1 ELSE 0 END) AS null_age_mid,
  SUM(CASE WHEN diag1_grp IS NULL THEN 1 ELSE 0 END) AS null_diag1,
  SUM(CASE WHEN diag2_grp IS NULL THEN 1 ELSE 0 END) AS null_diag2,
  SUM(CASE WHEN diag3_grp IS NULL THEN 1 ELSE 0 END) AS null_diag3
FROM `aise3010-492923.aise_3010_final_project.diabetes_features`;

-- 2) Duplicate check in modeling table (BigQuery Native).
SELECT
  (SELECT COUNT(*) FROM `aise3010-492923.aise_3010_final_project.diabetes_features`) AS total_rows,
  (SELECT COUNT(*) FROM (SELECT DISTINCT * FROM `aise3010-492923.aise_3010_final_project.diabetes_features`)) AS distinct_rows;

-- 3) Class balance.
SELECT
  target,
  COUNT(*) AS n,
  ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2) AS pct
FROM `aise3010-492923.aise_3010_final_project.diabetes_features`
GROUP BY target
ORDER BY target;

-- 4) Baseline rule-based confusion matrix (without ML model training).
WITH pred AS (
  SELECT
    target AS actual,
    CASE
      WHEN utilization_total >= 6 OR number_inpatient >= 2 OR time_in_hospital >= 8 THEN 1
      ELSE 0
    END AS predicted
  FROM `aise3010-492923.aise_3010_final_project.diabetes_features`
)
SELECT actual, predicted, COUNT(*) AS n
FROM pred
GROUP BY actual, predicted
ORDER BY actual, predicted;

-- 5) Optional derived metrics from the same baseline prediction.
WITH pred AS (
  SELECT
    target AS actual,
    CASE
      WHEN utilization_total >= 6 OR number_inpatient >= 2 OR time_in_hospital >= 8 THEN 1
      ELSE 0
    END AS predicted
  FROM `aise3010-492923.aise_3010_final_project.diabetes_features`
),
cm AS (
  SELECT
    SUM(CASE WHEN actual = 1 AND predicted = 1 THEN 1 ELSE 0 END) AS tp,
    SUM(CASE WHEN actual = 0 AND predicted = 0 THEN 1 ELSE 0 END) AS tn,
    SUM(CASE WHEN actual = 0 AND predicted = 1 THEN 1 ELSE 0 END) AS fp,
    SUM(CASE WHEN actual = 1 AND predicted = 0 THEN 1 ELSE 0 END) AS fn
  FROM pred
)
SELECT
  tp, tn, fp, fn,
  CASE WHEN tp + fp > 0 THEN ROUND(CAST(tp AS FLOAT64) / (tp + fp), 4) END AS precision,
  CASE WHEN tp + fn > 0 THEN ROUND(CAST(tp AS FLOAT64) / (tp + fn), 4) END AS recall,
  CASE WHEN 2 * tp + fp + fn > 0 THEN ROUND(CAST(2 * tp AS FLOAT64) / (2 * tp + fp + fn), 4) END AS f1
FROM cm;