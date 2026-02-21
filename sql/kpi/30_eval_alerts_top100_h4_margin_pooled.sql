-- ============================================================================
-- KPI STEP 30: EVALUATION — MARGIN-RANKED ALERTS TOP-100 (POOLED)
-- ============================================================================
-- PURPOSE:
--   Evaluate alerts_top100_h4_margin on the same metrics as the standard eval
--   (precision@100, recall@100, lift@100) and add business aggregates:
--     - sum / avg €_at_risk in top-100
--     - sum margin_unit in top-100
--     - sum q90 (proxy for units coverage) in top-100
--
-- OUTPUT TABLE:
--   thequantitativeledger.cruzber_models_eu.eval_alerts_top100_h4_margin_pooled
--
-- METRIC DEFINITIONS:
--   precision@100  = TP / 100  (fraction of top-100 alerts that were real OOS)
--   recall@100     = TP / total_stockouts_in_universe
--   lift@100       = precision@100 / prevalence
--   prevalence     = total_stockouts / total_rows_in_universe
--
-- Two label definitions (mirrors the standard eval):
--   label_model   = true_stockout_label    (model-defined OOS event)
--   label_sales0  = true_stockout_sales0   (sales = 0 in target week)
--
-- IDEMPOTENCE: CREATE OR REPLACE.
-- ============================================================================

CREATE OR REPLACE TABLE `thequantitativeledger.cruzber_models_eu.eval_alerts_top100_h4_margin_pooled` AS

WITH

-- ── Universe (VAL, for prevalence and total stockout counts) ──────────────
universe AS (
  SELECT
    season_group,
    COUNT(*) OVER (PARTITION BY season_group)                      AS n_universe,
    CAST(stockout_event_h4 AS INT64)                               AS label_model,
    CASE WHEN y_true_h4 = 0 THEN 1 ELSE 0 END                     AS label_sales0
  FROM `thequantitativeledger.cruzber_models_eu.forecast_h4_v4_kpi`
  WHERE split = 'VAL'
),

universe_agg AS (
  SELECT
    season_group,
    n_universe,
    SUM(label_model)                                               AS n_stockouts_model,
    SUM(label_sales0)                                              AS n_stockouts_sales0,
    SAFE_DIVIDE(SUM(label_model),  n_universe)                     AS prevalence_model,
    SAFE_DIVIDE(SUM(label_sales0), n_universe)                     AS prevalence_sales0
  FROM universe
  GROUP BY season_group, n_universe
),

-- ── Alert performance (per season_group + GLOBAL) ────────────────────────
alerts AS (
  SELECT
    season_group,
    CAST(true_stockout_label AS INT64)  AS label_model,
    CAST(true_stockout_sales0 AS INT64) AS label_sales0,
    eur_at_risk,
    margen_unit,
    q90_h4
  FROM `thequantitativeledger.cruzber_models_eu.alerts_top100_h4_margin`
),

alert_perf AS (
  SELECT
    season_group,
    COUNT(*)                               AS n_alerts,
    COUNTIF(label_model  = 1)             AS n_tp_model,
    COUNTIF(label_sales0 = 1)             AS n_tp_sales0,
    SAFE_DIVIDE(COUNTIF(label_model  = 1), COUNT(*)) AS precision_model,
    SAFE_DIVIDE(COUNTIF(label_sales0 = 1), COUNT(*)) AS precision_sales0,
    -- Business aggregates
    ROUND(SUM(COALESCE(eur_at_risk, 0)),  2)  AS sum_eur_at_risk_top100,
    ROUND(AVG(COALESCE(eur_at_risk, 0)),  4)  AS avg_eur_at_risk_top100,
    ROUND(SUM(COALESCE(margen_unit, 0)),  4)  AS sum_margin_unit_top100,
    ROUND(SUM(COALESCE(q90_h4,     0)),   4)  AS sum_q90_top100
  FROM alerts
  GROUP BY season_group
),

-- ── Combine precision / recall / lift ────────────────────────────────────
per_season AS (
  SELECT
    'PER_SEASON'                         AS period,
    ap.season_group,
    ap.n_alerts,
    ap.n_tp_model,
    ua.n_stockouts_model                 AS n_total_stockouts_model,
    ap.precision_model,
    SAFE_DIVIDE(ap.n_tp_model, ua.n_stockouts_model)        AS recall_model,
    SAFE_DIVIDE(ap.precision_model, ua.prevalence_model)    AS lift_model,
    ap.n_tp_sales0,
    ua.n_stockouts_sales0                AS n_total_stockouts_sales0,
    ap.precision_sales0,
    SAFE_DIVIDE(ap.n_tp_sales0,  ua.n_stockouts_sales0)     AS recall_sales0,
    SAFE_DIVIDE(ap.precision_sales0, ua.prevalence_sales0)  AS lift_sales0,
    ap.sum_eur_at_risk_top100,
    ap.avg_eur_at_risk_top100,
    ap.sum_margin_unit_top100,
    ap.sum_q90_top100
  FROM alert_perf ap
  JOIN universe_agg ua USING (season_group)
),

-- ── GLOBAL pooled row ────────────────────────────────────────────────────
global_row AS (
  SELECT
    'GLOBAL'                             AS period,
    'ALL'                                AS season_group,
    SUM(n_alerts)                        AS n_alerts,
    SUM(n_tp_model)                      AS n_tp_model,
    SUM(n_total_stockouts_model)         AS n_total_stockouts_model,
    SAFE_DIVIDE(SUM(n_tp_model), SUM(n_alerts))             AS precision_model,
    SAFE_DIVIDE(SUM(n_tp_model), SUM(n_total_stockouts_model)) AS recall_model,
    SAFE_DIVIDE(
      SAFE_DIVIDE(SUM(n_tp_model), SUM(n_alerts)),
      SAFE_DIVIDE(SUM(n_total_stockouts_model),
                  (SELECT SUM(n_universe) FROM universe_agg))
    )                                                        AS lift_model,
    SUM(n_tp_sales0)                     AS n_tp_sales0,
    SUM(n_total_stockouts_sales0)        AS n_total_stockouts_sales0,
    SAFE_DIVIDE(SUM(n_tp_sales0), SUM(n_alerts))            AS precision_sales0,
    SAFE_DIVIDE(SUM(n_tp_sales0), SUM(n_total_stockouts_sales0)) AS recall_sales0,
    SAFE_DIVIDE(
      SAFE_DIVIDE(SUM(n_tp_sales0), SUM(n_alerts)),
      SAFE_DIVIDE(SUM(n_total_stockouts_sales0),
                  (SELECT SUM(n_universe) FROM universe_agg))
    )                                                        AS lift_sales0,
    ROUND(SUM(sum_eur_at_risk_top100), 2) AS sum_eur_at_risk_top100,
    ROUND(AVG(avg_eur_at_risk_top100), 4) AS avg_eur_at_risk_top100,
    ROUND(SUM(sum_margin_unit_top100), 4) AS sum_margin_unit_top100,
    ROUND(SUM(sum_q90_top100),         4) AS sum_q90_top100
  FROM per_season
)

SELECT * FROM per_season
UNION ALL
SELECT * FROM global_row
ORDER BY period DESC, season_group;


-- ── Final display ────────────────────────────────────────────────────────
SELECT
  period,
  season_group,
  n_alerts,
  n_tp_model,
  ROUND(precision_model, 4)             AS precision_model,
  ROUND(recall_model,    4)             AS recall_model,
  ROUND(lift_model,      4)             AS lift_model,
  ROUND(precision_sales0, 4)            AS precision_sales0,
  ROUND(recall_sales0,    4)            AS recall_sales0,
  ROUND(lift_sales0,      4)            AS lift_sales0,
  sum_eur_at_risk_top100,
  avg_eur_at_risk_top100,
  sum_margin_unit_top100,
  sum_q90_top100
FROM `thequantitativeledger.cruzber_models_eu.eval_alerts_top100_h4_margin_pooled`
ORDER BY period DESC, season_group;
