-- ============================================================================
-- STEP 00: TEMPORAL CONTRACT  (h=12 v3_strict)
-- ============================================================================
-- PURPOSE:
--   Single source of truth for split assignments in h12_v3_strict.
--   Every downstream query must JOIN this table to determine which split
--   a decision_week belongs to, never hard-coding week ranges.
--
-- CRITICAL RULE (post-selection bias prevention):
--   - can_tune   = TRUE  → calibration grid may use labels from this week
--   - can_select = TRUE  → policy / probability-mode selection may use labels
--   - can_report_final = TRUE → final metric reporting allowed (read-only,
--                               decisions must already be frozen)
--   - labels_allowed = TRUE   → y_true_12w / stockout_event_12w may appear
--                               in queries (never TRUE for LOCKED_TEST because
--                               W28-W40 labels confirmed blind)
--
-- SPLITS (h=12, iso_year 2024):
--   DEV_TUNE    W01-W08   8 weeks   calibration grid only
--   DEV_SELECT  W09-W16   8 weeks   policy + probability selection only
--   EMBARGO     W17-W27  11 weeks   h=12 buffer — never used
--   LOCKED_TEST W28-W40  13 weeks   final test (labels BLIND → LOCKED_TEST_PENDING)
--   OTHER       rest              TRAIN/CALIB/pre-2024
--
-- WHY EMBARGO W17-W27:
--   A decision on W16 (last DEV_SELECT week) generates targets covering
--   W17-W28 (12 weeks forward). A decision on W28 (first LOCKED_TEST week)
--   generates targets covering W29-W40. There is no target-window overlap
--   between DEV_SELECT and LOCKED_TEST. The embargo exists to ensure no
--   partially-observed target windows from DEV_SELECT bleed into LOCKED_TEST
--   through feature aggregations, panel normalisations, or rolling stats
--   computed over the full dataset before partitioning.
--
-- OUTPUT TABLE:
--   temporal_contract_h12_v3_strict
-- ============================================================================

CREATE OR REPLACE TABLE `{PROJECT_ID}.{BQ_DATASET}.temporal_contract_h12_v3_strict` AS
WITH distinct_weeks AS (
  SELECT DISTINCT week_start_date
  FROM `{PROJECT_ID}.{BQ_DATASET}.base_scores_h12_v1`
  WHERE split IN ('TRAIN', 'CALIB', 'VAL')
),
annotated AS (
  SELECT
    week_start_date                                     AS decision_week,
    EXTRACT(ISOYEAR FROM week_start_date)               AS iso_year,
    EXTRACT(ISOWEEK  FROM week_start_date)              AS iso_week,
    -- 12-week target window starting the day after decision_week
    DATE_ADD(week_start_date, INTERVAL 1 WEEK)          AS target_start_week,
    DATE_ADD(week_start_date, INTERVAL 12 WEEK)         AS target_end_week,
    -- Split classification
    CASE
      WHEN EXTRACT(ISOYEAR FROM week_start_date) = 2024
       AND EXTRACT(ISOWEEK  FROM week_start_date) BETWEEN 1  AND  8 THEN 'DEV_TUNE'
      WHEN EXTRACT(ISOYEAR FROM week_start_date) = 2024
       AND EXTRACT(ISOWEEK  FROM week_start_date) BETWEEN 9  AND 16 THEN 'DEV_SELECT'
      WHEN EXTRACT(ISOYEAR FROM week_start_date) = 2024
       AND EXTRACT(ISOWEEK  FROM week_start_date) BETWEEN 17 AND 27 THEN 'EMBARGO'
      WHEN EXTRACT(ISOYEAR FROM week_start_date) = 2024
       AND EXTRACT(ISOWEEK  FROM week_start_date) BETWEEN 28 AND 40 THEN 'LOCKED_TEST'
      ELSE 'OTHER'
    END AS eval_split_v3,
    -- Operational flags
    CASE
      WHEN EXTRACT(ISOYEAR FROM week_start_date) = 2024
       AND EXTRACT(ISOWEEK  FROM week_start_date) BETWEEN 1 AND 8
      THEN TRUE ELSE FALSE
    END AS can_tune,
    CASE
      WHEN EXTRACT(ISOYEAR FROM week_start_date) = 2024
       AND EXTRACT(ISOWEEK  FROM week_start_date) BETWEEN 9 AND 16
      THEN TRUE ELSE FALSE
    END AS can_select,
    CASE
      WHEN EXTRACT(ISOYEAR FROM week_start_date) = 2024
       AND EXTRACT(ISOWEEK  FROM week_start_date) BETWEEN 28 AND 40
      THEN TRUE ELSE FALSE
    END AS can_report_final,
    -- Labels: ONLY allowed in DEV_TUNE and DEV_SELECT.
    -- LOCKED_TEST W28-W40 confirmed blind (y_true_12w = NULL in source).
    -- Setting labels_allowed = FALSE enforces this in downstream queries.
    CASE
      WHEN EXTRACT(ISOYEAR FROM week_start_date) = 2024
       AND EXTRACT(ISOWEEK  FROM week_start_date) BETWEEN 1 AND 16
      THEN TRUE ELSE FALSE
    END AS labels_allowed
  FROM distinct_weeks
)
SELECT
  a.*,
  CASE a.eval_split_v3
    WHEN 'DEV_TUNE'    THEN
      CONCAT('Calibration grid tuning only (W01-W08 2024). '
             , 'target_end_week=', CAST(a.target_end_week AS STRING), '. '
             , 'Labels available. can_tune=TRUE.')
    WHEN 'DEV_SELECT'  THEN
      CONCAT('Policy + probability mode selection only (W09-W16 2024). '
             , 'target_end_week=', CAST(a.target_end_week AS STRING), '. '
             , 'Labels available. can_select=TRUE. NO final metrics allowed here.')
    WHEN 'EMBARGO'     THEN
      CONCAT('EMBARGO: h=12 buffer (W17-W27 2024). '
             , 'Target windows of DEV_SELECT decisions partially overlap this period. '
             , 'NEVER use for tuning, selection, or reporting.')
    WHEN 'LOCKED_TEST' THEN
      CONCAT('LOCKED_TEST (W28-W40 2024). '
             , 'Labels confirmed BLIND (y_true_12w=NULL). '
             , 'Status: LOCKED_TEST_PENDING. '
             , 'Only frozen decisions may be applied here. No re-selection allowed.')
    ELSE
      CONCAT('OTHER: TRAIN/CALIB row or pre-2024 week (', CAST(a.decision_week AS STRING), ').')
  END AS notes,
  CURRENT_TIMESTAMP() AS contract_created_at
FROM annotated a
ORDER BY decision_week;

-- ── Verification query ────────────────────────────────────────────────────
SELECT
  eval_split_v3,
  COUNT(*)        AS n_weeks,
  MIN(iso_week)   AS iso_week_min,
  MAX(iso_week)   AS iso_week_max,
  MIN(decision_week) AS first_week,
  MAX(decision_week) AS last_week,
  LOGICAL_OR(can_tune)         AS any_can_tune,
  LOGICAL_OR(can_select)       AS any_can_select,
  LOGICAL_OR(can_report_final) AS any_can_report_final,
  LOGICAL_OR(labels_allowed)   AS any_labels_allowed
FROM `{PROJECT_ID}.{BQ_DATASET}.temporal_contract_h12_v3_strict`
GROUP BY eval_split_v3
ORDER BY eval_split_v3;

-- ── Target-overlap sanity check ───────────────────────────────────────────
-- Confirm: no row in DEV_SELECT has target_end_week >= first LOCKED_TEST decision_week
-- (i.e., no target window of DEV_SELECT decision overlaps with LOCKED_TEST decisions)
SELECT
  'TARGET_OVERLAP_CHECK' AS check_name,
  CASE
    WHEN NOT EXISTS (
      SELECT 1
      FROM `{PROJECT_ID}.{BQ_DATASET}.temporal_contract_h12_v3_strict` dev
      JOIN `{PROJECT_ID}.{BQ_DATASET}.temporal_contract_h12_v3_strict` lt
        ON lt.eval_split_v3 = 'LOCKED_TEST'
       AND dev.target_end_week >= lt.decision_week
      WHERE dev.eval_split_v3 = 'DEV_SELECT'
    ) THEN 'PASS — no target_end of DEV_SELECT >= any LOCKED_TEST decision_week'
    ELSE 'WARN — some DEV_SELECT target windows reach into LOCKED_TEST decision period'
  END AS result;
