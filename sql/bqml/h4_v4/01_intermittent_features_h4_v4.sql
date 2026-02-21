-- ============================================================================
-- STEP 01: INTERMITTENT-DEMAND FEATURES  (h=4 v4)
-- ============================================================================
-- PURPOSE:
--   Augment weekly_features_h4 with three intermittent-demand signals:
--     zero_share_13w        : fraction of weeks with y_sales=0 in last 13w (excl. current)
--     last_nonzero_lag      : number of weeks since last y_sales>0
--     mean_interarrival_13w : mean gap (in weeks) between consecutive nonzero weeks
--                              estimated over the last 13 periods
--
-- LEAKAGE SAFETY:
--   All windows look at [week_start_date - 13w, week_start_date - 1w].
--   The label target_week is HORIZON_WEEKS=4 in the future; no future data is used.
--
-- INPUT TABLE:  thequantitativeledger.cruzber_models_eu.weekly_features_h4
--   Must contain: sku_id, week_start_date, y_sales, split
--   (same table used by v2/v3 pipeline)
--
-- OUTPUT TABLE: thequantitativeledger.cruzber_models_eu.weekly_features_h4_v4
--   = weekly_features_h4 PLUS the three new columns
-- ============================================================================

CREATE OR REPLACE TABLE `thequantitativeledger.cruzber_models_eu.weekly_features_h4_v4` AS

-- ---- 1. Self-join window for the last 13 weeks (exclusive) ------------------
WITH history AS (
  SELECT
    cur.sku_id,
    cur.week_start_date                                AS ref_date,
    hist.week_start_date                               AS hist_date,
    hist.y_sales,
    DATE_DIFF(cur.week_start_date, hist.week_start_date, WEEK) AS lag_weeks
  FROM `thequantitativeledger.cruzber_models_eu.weekly_features_h4` cur
  INNER JOIN `thequantitativeledger.cruzber_models_eu.weekly_features_h4` hist
    ON  cur.sku_id           = hist.sku_id
    -- window: 1..13 weeks before cur (excludes t=0 to avoid same-week leakage)
    AND DATE_DIFF(cur.week_start_date, hist.week_start_date, WEEK)
            BETWEEN 1 AND 13
),

-- ---- 2. Aggregate per (sku, ref_date) ----------------------------------------
intermittent_agg AS (
  SELECT
    sku_id,
    ref_date,
    COUNT(*)                                                    AS n_hist_weeks,

    -- zero_share_13w: fraction of zero-sales weeks
    SAFE_DIVIDE(
      SUM(CASE WHEN y_sales = 0 THEN 1 ELSE 0 END),
      COUNT(*)
    )                                                           AS zero_share_13w,

    -- last_nonzero_lag: how many weeks ago was the last nonzero sale?
    --   = MIN(lag_weeks) where y_sales > 0; NULL if all zeros in window
    MIN(CASE WHEN y_sales > 0 THEN lag_weeks ELSE NULL END)    AS last_nonzero_lag,

    -- For mean_interarrival: collect nonzero lags (sorted asc = oldest gaps go last)
    ARRAY_AGG(
      CASE WHEN y_sales > 0 THEN lag_weeks ELSE NULL END
      IGNORE NULLS
      ORDER BY lag_weeks ASC
    )                                                           AS nonzero_lags_asc
  FROM history
  GROUP BY sku_id, ref_date
),

-- ---- 3. Compute mean interarrival from successive differences of sorted lags ---
interarrival AS (
  SELECT
    sku_id,
    ref_date,
    zero_share_13w,
    last_nonzero_lag,
    -- mean_interarrival_13w: average gap between consecutive nonzero events
    -- If only 1 nonzero event, use last_nonzero_lag itself as a proxy.
    -- If 0 nonzero events, fallback to 13 (max window).
    CASE
      WHEN ARRAY_LENGTH(nonzero_lags_asc) = 0
        THEN 13.0
      WHEN ARRAY_LENGTH(nonzero_lags_asc) = 1
        THEN CAST(nonzero_lags_asc[OFFSET(0)] AS FLOAT64)
      ELSE
        -- successive differences: (lags[1]-lags[0], lags[2]-lags[1], ...)
        -- average = (last - first) / (n - 1)
        SAFE_DIVIDE(
          CAST(
            nonzero_lags_asc[ORDINAL(ARRAY_LENGTH(nonzero_lags_asc))]
            - nonzero_lags_asc[OFFSET(0)]
            AS FLOAT64
          ),
          CAST(ARRAY_LENGTH(nonzero_lags_asc) - 1 AS FLOAT64)
        )
    END                                                         AS mean_interarrival_13w
  FROM intermittent_agg
)

-- ---- 4. Final join: base table + new features --------------------------------
SELECT
  base.*,

  -- new intermittent-demand features (with safe fallbacks)
  COALESCE(ia.zero_share_13w,       0.5)  AS zero_share_13w,
  COALESCE(ia.last_nonzero_lag,     13.0) AS last_nonzero_lag,
  COALESCE(ia.mean_interarrival_13w, 7.0) AS mean_interarrival_13w

FROM `thequantitativeledger.cruzber_models_eu.weekly_features_h4` base
LEFT JOIN interarrival ia
  ON  base.sku_id          = ia.sku_id
  AND base.week_start_date = ia.ref_date
;

-- ---- Diagnostic summary -------------------------------------------------------
SELECT
  COUNT(*)                              AS n_rows,
  ROUND(AVG(zero_share_13w),       4)  AS avg_zero_share_13w,
  ROUND(AVG(last_nonzero_lag),     2)  AS avg_last_nonzero_lag,
  ROUND(AVG(mean_interarrival_13w),2)  AS avg_interarrival,
  COUNTIF(zero_share_13w IS NULL)      AS n_null_zero_share,
  COUNTIF(last_nonzero_lag IS NULL)    AS n_null_last_nonzero,
  COUNTIF(mean_interarrival_13w IS NULL) AS n_null_interarrival
FROM `thequantitativeledger.cruzber_models_eu.weekly_features_h4_v4`;
