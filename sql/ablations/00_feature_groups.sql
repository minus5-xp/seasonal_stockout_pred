-- ============================================================================
-- HITO 4: Feature Groups for Ablation Studies
-- ============================================================================
-- Purpose: Document feature categorization for ablation experiments
--
-- Total Features: 14
-- ============================================================================

-- WHALE/CONCENTRATION FEATURES (3 features)
-- Measure customer concentration and demand concentration
-- Business rationale: High HHI = few customers = supply chain vulnerability
-- ============================================================================
-- hhi_base_roll13          - Herfindahl-Hirschman Index (0-1, higher = more concentrated)
-- top_customer_share       - Share of top customer (0-1)
-- n_customers_roll13       - Number of unique customers in 13-week window

-- SEASONAL FEATURES (2 features)
-- Capture time-based patterns and seasonality
-- Business rationale: Tourism peaks cause stockouts
-- ============================================================================
-- is_high_season           - Binary flag for high tourism season (1=high, 0=rest)
-- iso_week                 - Week of year (1-52/53)

-- CORE DEMAND FEATURES (9 features)
-- Fundamental demand signals: lags, volatility, trends
-- Business rationale: Recent demand best predicts near-future stockout risk
-- ============================================================================
-- amplitude                - Demand range (max - min)
-- cv_roll13                - Coefficient of variation (std/mean) over 13 weeks
-- lag_1                    - OOS flag 1 week ago (binary persistence signal)
-- lag_2                    - OOS flag 2 weeks ago
-- lag_4                    - OOS flag 4 weeks ago
-- n_days_nonzero           - Number of days with positive demand
-- roll13_mean              - Mean demand over 13 weeks
-- roll13_std               - Standard deviation over 13 weeks
-- roll4_mean               - Mean demand over 4 weeks (recent trend)

-- ============================================================================
-- ABLATION MODELS DEFINITION
-- ============================================================================

-- A0: FULL MODEL (baseline, current m_oos_h4)
-- Features: All 14 (whales=3, seasonal=2, core=9)
-- Purpose: Reference performance

-- A1: WITHOUT WHALES
-- Features: 11 (seasonal=2, core=9)
-- Excluded: hhi_base_roll13, top_customer_share, n_customers_roll13
-- Hypothesis: Δ_AUC < 0.02 (whales contribute <2pp to AUC)

-- A2: WITHOUT SEASONAL
-- Features: 12 (whales=3, core=9)
-- Excluded: is_high_season, iso_week
-- Hypothesis: Δ_AUC ~ 0.01 (seasonality contributes ~1pp to AUC)

-- A3: SEASON-ONLY
-- Features: 2 (is_high_season, iso_week)
-- Purpose: Establish upper bound on seasonal signal alone
-- Expected: AUC ~ 0.70-0.75 (decent but not excellent)

-- A4: WHALES-ONLY
-- Features: 3 (hhi_base_roll13, top_customer_share, n_customers_roll13)
-- Purpose: Establish upper bound on concentration signal alone
-- Expected: AUC ~ 0.65-0.70 (structural vulnerability signal)

-- ============================================================================
-- EVALUATION METRICS
-- ============================================================================
-- For each model (A0-A4):
--   1. Overall: AUC-ROC, PR-AUC, Precision@100, Lift@100
--   2. Segmented by HIGH_SEASON: AUC, Prec@100 for HIGH vs REST
--   3. Segmented by HHI quartile: AUC, Prec@100 for Q1/Q2/Q3/Q4
--   4. Delta vs A0: Δ_AUC, Δ_PR-AUC, Δ_Prec@100

-- ============================================================================
-- EXPECTED INSIGHTS (Hypotheses)
-- ============================================================================
-- H1: Whales matter more in LOW_HHI segments (many customers = complex patterns)
-- H2: Seasonality matters more in HIGH_SEASON (by definition)
-- H3: Core demand features dominate (A1 and A2 lose <3pp AUC vs A0)
-- H4: No single feature group achieves >0.80 AUC alone (feature synergy exists)
-- H5: A1 (no whales) performs better than A2 (no seasonal) - demand > time patterns
