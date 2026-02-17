-- B0: Canonical protocol and immutable definitions for Option B (paper)
-- Claims policy: sales-only proxy censoring (NOT true stockout ground truth)

CREATE OR REPLACE TABLE `{dataset_ref}.b0_protocol_h4` AS
SELECT
  'option_b_sales_only_v1' AS protocol_id,
  CURRENT_TIMESTAMP() AS protocol_timestamp,
  'sku-week-segment' AS universe_definition,
  'proxy_oos_risk_from_sales_only' AS censoring_label_definition,
  'demand_active := y_sales > 0 OR roll13_mean >= 1' AS demand_active_definition,
  'TRAIN/CALIB/VAL fixed in weekly_features_h4 split column' AS split_definition,
  'rolling_4w_anchor_folds' AS cv_definition,
  'topK=100 for alert-like diagnostics; policy optimized by fill-rate target' AS topk_definition,
  'No true OOS claim; latent demand is estimated with uncertainty' AS claims_guardrail;

CREATE OR REPLACE TABLE `{dataset_ref}.optionb_rolling_folds_h4` AS
WITH weeks AS (
  SELECT DISTINCT week_start_date
  FROM `{dataset_ref}.weekly_features_h4`
  WHERE split IN ('TRAIN', 'CALIB', 'VAL')
),
ordered AS (
  SELECT
    week_start_date,
    DENSE_RANK() OVER (ORDER BY week_start_date) AS week_rank
  FROM weeks
),
anchors AS (
  SELECT DISTINCT
    CAST(FLOOR((week_rank - 1) / 4) AS INT64) AS fold_id,
    MIN(week_start_date) OVER (
      PARTITION BY CAST(FLOOR((week_rank - 1) / 4) AS INT64)
    ) AS fold_start,
    MAX(week_start_date) OVER (
      PARTITION BY CAST(FLOOR((week_rank - 1) / 4) AS INT64)
    ) AS fold_end
  FROM ordered
)
SELECT
  fold_id,
  fold_start,
  fold_end
FROM anchors
ORDER BY fold_id;
