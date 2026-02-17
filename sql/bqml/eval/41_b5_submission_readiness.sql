-- B5 final readiness marker in BigQuery (data-driven go/no-go)

CREATE OR REPLACE TABLE `{dataset_ref}.submission_readiness_h4` AS
WITH checks AS (
  SELECT check_name, status FROM `{dataset_ref}.optionb_ablation_scorecard_h4`
),
final AS (
  SELECT
    COUNTIF(status = 'PASS') AS n_pass,
    COUNT(*) AS n_total
  FROM checks
)
SELECT
  CURRENT_TIMESTAMP() AS evaluated_at,
  n_pass,
  n_total,
  CASE WHEN n_pass = n_total THEN 'SUBMIT_READY' ELSE 'NO_SUBMIT_READY_YET' END AS verdict,
  CASE
    WHEN n_pass = n_total THEN 'All paper-critical gates passed under Option B.'
    ELSE 'At least one critical gate failed (coverage or policy constraints).'
  END AS rationale
FROM final;
