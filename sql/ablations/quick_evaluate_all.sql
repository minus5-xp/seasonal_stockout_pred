-- Quick evaluation of all 5 ablation models
SELECT 
  'A0_FULL' AS model_id,
  14 AS n_features,
  roc_auc,
  precision,
  recall,
  f1_score,
  log_loss
FROM ML.EVALUATE(
  MODEL `thequantitativeledger.cruzber_models_eu.m_oos_h4`,
  (SELECT * FROM `thequantitativeledger.cruzber_models_eu.weekly_features_h4`
   WHERE split = 'VAL' AND ever_sold_flag = 1 AND y_oos_h4 IS NOT NULL)
)

UNION ALL

SELECT 
  'A1_NO_WHALES',
  11,
  roc_auc,
  precision,
  recall,
  f1_score,
  log_loss
FROM ML.EVALUATE(
  MODEL `thequantitativeledger.cruzber_models_eu.m_ablation_a1_no_whales`,
  (SELECT * FROM `thequantitativeledger.cruzber_models_eu.weekly_features_h4`
   WHERE split = 'VAL' AND ever_sold_flag = 1 AND y_oos_h4 IS NOT NULL)
)

UNION ALL

SELECT 
  'A2_NO_SEASONAL',
  12,
  roc_auc,
  precision,
  recall,
  f1_score,
  log_loss
FROM ML.EVALUATE(
  MODEL `thequantitativeledger.cruzber_models_eu.m_ablation_a2_no_seasonal`,
  (SELECT * FROM `thequantitativeledger.cruzber_models_eu.weekly_features_h4`
   WHERE split = 'VAL' AND ever_sold_flag = 1 AND y_oos_h4 IS NOT NULL)
)

UNION ALL

SELECT 
  'A3_SEASON_ONLY',
  2,
  roc_auc,
  precision,
  recall,
  f1_score,
  log_loss
FROM ML.EVALUATE(
  MODEL `thequantitativeledger.cruzber_models_eu.m_ablation_a3_season_only`,
  (SELECT * FROM `thequantitativeledger.cruzber_models_eu.weekly_features_h4`
   WHERE split = 'VAL' AND ever_sold_flag = 1 AND y_oos_h4 IS NOT NULL)
)

UNION ALL

SELECT 
  'A4_WHALES_ONLY',
  3,
  roc_auc,
  precision,
  recall,
  f1_score,
  log_loss
FROM ML.EVALUATE(
  MODEL `thequantitativeledger.cruzber_models_eu.m_ablation_a4_whales_only`,
  (SELECT * FROM `thequantitativeledger.cruzber_models_eu.weekly_features_h4`
   WHERE split = 'VAL' AND ever_sold_flag = 1 AND y_oos_h4 IS NOT NULL)
)

ORDER BY roc_auc DESC;
