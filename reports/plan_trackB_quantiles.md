# PLAN: TRACK B (QUANTILES P10/P50/P90)

**Version**: 1.0  
**Date**: 2026-02-14  
**Owner**: Hugo de Val (hugo@deval.work)  
**Status**: 🔴 **RESEARCH PHASE** (NO-GO for production until B0 gate passes)

---

## 1. CONTEXT & CURRENT CHALLENGE

### Business Requirement
Provide **probabilistic demand forecasts** at h=4 weeks:
- P10: Pessimistic scenario (10th percentile)
- P50: Expected scenario (median)
- P90: Optimistic scenario (90th percentile)

**Use Case**: Safety stock calculation, range planning, risk-adjusted inventory buffers.

### Current Status: ❌ **NO-GO** (Gate B0 Failure)

**Audit Evidence** (2026-02-10):
| Quantile | Target Deviation | Actual | Status |
|----------|------------------|--------|--------|
| **P90** | <±3pp | **-5.34pp** | 🔴 FAIL |
| **P50** | <±3pp | **-8.47pp** | 🔴 FAIL |
| **P10** | <±3pp | **+12.01pp** | 🔴 FAIL |

**Pinball Loss**: 4.32 worse than naive baseline (unacceptable).

### Root Cause Analysis

**Problem 1: Silver Labels**
- **No ground truth inventory**: OOS approximated from sales-only data
- **Bias**: Systematic over-prediction at low quantiles, under-prediction at high
- **Academic grounding**: Kourentzes et al. (IJF 2017) §3.1 warns unconstraining requires intermittence <30%, Cruzber has 45%

**Problem 2: Zero-Inflation**
- **Distribution mismatch**: QRF assumes continuous, Cruzber has 45% exact zeros (genuine OOS + no demand)
- **Quantile crossing**: P10 > P50 occurs in 3.2% of predictions (mathematical inconsistency)

**Problem 3: Whale Heterogeneity**
- **HHI drift**: Some SKUs dominated by 1 customer (HHI>500), quantiles collapse to order size
- **Academic grounding**: Montoya-González & Kourentzes (MSOM 2019) §5.2 show stratification by customer volatility improves calibration

---

## 2. THREE REMEDIATION ROUTES

### Route 1: RECALIBRACIÓN CONDICIONAL ⭐ **RECOMMENDED** (P0.1 Backlog)

**Principle**: Restrict quantile models to subset with reliable unconstraining (amplitude > 5), use stratified percentiles.

**Academic Grounding**:
- **Kourentzes et al. (IJF 2017) §3.1**: "Unconstraining methods perform best when intermittence <30% and non-zero demand CV <1.5"
- **Montoya-González & Kourentzes (MSOM 2019) §5.2**: "Stratified percentiles by volatility regime reduce miscalibration by 40%"

**Implementation Steps** (3 sprints):

**Sprint 1: Subset Selection & Feature Expansion**
```sql
-- Identify reliable SKUs (amplitude > 5)
CREATE OR REPLACE TABLE `{dataset_ref}.subset_reliable_quantiles` AS
SELECT
  sku_id,
  AVG(lag_1) AS avg_amplitude,
  STDDEV(lag_1) / NULLIF(AVG(lag_1), 0) AS cv,
  COUNT(*) AS n_weeks,
  AVG(CASE WHEN y_sales > 0 THEN 1 ELSE 0 END) AS fill_rate
FROM `{dataset_ref}.weekly_features_h4`
WHERE split = 'TRAIN'
GROUP BY sku_id
HAVING avg_amplitude > 5
  AND cv BETWEEN 0.2 AND 1.5  -- Kourentzes §3.1 threshold
  AND n_weeks >= 52  -- At least 1 year history
  AND fill_rate > 0.50;  -- More demand than OOS
```

**Expected**: ~30-40% of SKUs qualify (vs 100% current).

**Sprint 2: Stratified Percentiles by Season × HHI**
```sql
-- Compute conditional percentiles (nested within strata)
CREATE OR REPLACE TABLE `{dataset_ref}.conditional_percentiles` AS
SELECT
  season_group,  -- HIGH vs REST
  hhi_bucket,    -- A/B/C
  APPROX_QUANTILES(y_sales_h4, 100)[OFFSET(10)] AS p10_seasonal,
  APPROX_QUANTILES(y_sales_h4, 100)[OFFSET(50)] AS p50_seasonal,
  APPROX_QUANTILES(y_sales_h4, 100)[OFFSET(90)] AS p90_seasonal,
  AVG(y_sales_h4) AS mean_seasonal,
  STDDEV(y_sales_h4) AS std_seasonal
FROM `{dataset_ref}.weekly_features_h4`
WHERE sku_id IN (SELECT sku_id FROM `{dataset_ref}.subset_reliable_quantiles`)
  AND split = 'TRAIN'
GROUP BY season_group, hhi_bucket;
```

**Sprint 3: Model Re-training with Conditional Calibration**
```sql
-- Option A: Replace QRF with parametric (Gamma or Tweedie)
CREATE OR REPLACE MODEL `{dataset_ref}.m_quantiles_h4_conditional`
OPTIONS(
  model_type='BOOSTED_TREE_CLASSIFIER',  -- Still classification for OOS, then scale by amplitude
  input_label_cols=['y_sales_h4_scaled'],  -- Scale by seasonal percentile
  data_split_method='CUSTOM',
  data_split_col='split'
) AS
SELECT
  -- Scale target by seasonal baseline
  y_sales_h4 / p50_seasonal AS y_sales_h4_scaled,
  -- Features same as before
  lag_1, lag_2, lag_4, roll4_mean, roll13_mean, hhi_base_roll13,
  iso_week, is_high_season, season_group, hhi_bucket,
  split
FROM `{dataset_ref}.weekly_features_h4` f
JOIN `{dataset_ref}.conditional_percentiles` p
  ON f.season_group = p.season_group
  AND f.hhi_bucket = p.hhi_bucket
WHERE sku_id IN (SELECT sku_id FROM `{dataset_ref}.subset_reliable_quantiles`);

-- Option B: Post-hoc calibration (isotonic regression)
-- Train separate isotonic model per (season, HHI) on CALIB split
-- Map raw quantile → calibrated quantile using monotonic spline
```

**Validation (Gate B0)**:
- Compute pinball loss on VAL split (26 weeks)
- Require: P10/P50/P90 deviation < ±3pp for 8 consecutive weeks
- Compare vs naive baseline: Require pinball loss < baseline + 10%

**Timeline**: 6 weeks (W10-W15), decision gate 2026-03-28 (W13)

**Risk**: Medium (academic precedent exists, Montoya-González MSOM 2019 validated on real-world data)

---

### Route 2: UNCONSTRAINING WITH GROUND TRUTH (P0.4 Backlog)

**Principle**: Obtain actual inventory data from ERP, validate Kourentzes unconstraining on **real stockout labels**.

**Academic Grounding**:
- **Kourentzes et al. (IJF 2017) §4**: "Unconstraining requires observed constrained demand AND unconstrained demand for calibration"
- **Fill rate constraints**: Syntetos et al. (IJPE 2020) §4.1 show unconstraining improves forecast bias by 35% when done correctly

**Implementation Steps** (4 sprints):

**Sprint 1: ERP Integration (Pilot 1-2 SKUs)**
- Coordinate with IT/Supply Chain to export inventory_level_daily table
- Fields: `date`, `sku_id`, `inventory_qty`, `is_stockout_flag` (qty=0)
- Validate: Match SKU IDs to fact_lineas_albaran

**Sprint 2: Validation of Silver Labels**
```sql
-- Compare OOS approximation vs actual ERP stockout
WITH silver_labels AS (
  SELECT
    sku_id,
    week_start_date,
    y_oos_h4 AS oos_approx  -- Current silver label
  FROM `{dataset_ref}.weekly_features_h4`
  WHERE sku_id IN ('pilot_sku_1', 'pilot_sku_2')
),
ground_truth AS (
  SELECT
    sku_id,
    DATE_TRUNC(date, ISOWEEK) AS week_start_date,
    MAX(CASE WHEN inventory_qty = 0 THEN 1 ELSE 0 END) AS oos_actual
  FROM `{project_id}.{dataset_erp}.inventory_level_daily`
  WHERE sku_id IN ('pilot_sku_1', 'pilot_sku_2')
  GROUP BY sku_id, week_start_date
)
SELECT
  s.sku_id,
  SUM(CASE WHEN s.oos_approx = g.oos_actual THEN 1 ELSE 0 END) / COUNT(*) AS label_accuracy
FROM silver_labels s
JOIN ground_truth g USING (sku_id, week_start_date)
GROUP BY s.sku_id;
```

**Expected**: Label accuracy 60-75% (if >80%, silver labels acceptable; if <60%, must fix).

**Sprint 3: Re-train Quantile Model with True Labels**
- If label accuracy >80%: Proceed with Route 1 (recalibración condicional)
- If label accuracy 60-80%: Correct bias using Kourentzes §3.1 method (adjust unconstrained demand by fill rate)
- If label accuracy <60%: ABORT Route 2, escalate to Route 3 (temporal clustering)

**Sprint 4: Scale to 50 SKUs**
- If pilot succeeds: Expand ERP integration to top-50 SKUs by revenue
- Validate: Same deviation < ±3pp threshold

**Timeline**: 8 weeks (W10-W17), decision gate 2026-04-18 (W16)

**Risk**: HIGH (depends on ERP access, IT bottleneck, data quality)

---

### Route 3: TEMPORAL CLUSTERING / HMM (P2.2 Backlog)

**Principle**: Model demand as regime-switching process (HIGH demand, NEAR-OOS, OOS states), then simulate quantiles from state probabilities.

**Academic Grounding**:
- **Montoya-González & Kourentzes (MSOM 2019) §4-6**: Hidden Markov Model (HMM) with 3 states:
  1. HIGH demand (μ=historical mean)
  2. LOW demand (μ=0.5 × historical mean, high variance)
  3. OOS (μ=0, stockout state)
- Transition probabilities learned from TRAIN data per SKU family
- **Advantage**: Naturally handles zero-inflation, quantiles respect state boundaries (no crossing)

**Implementation Steps** (RESEARCH PHASE, 10+ sprints):

**Sprint 1-2: Literature Review + Algorithm Selection**
- Replicate Montoya-González MSOM 2019 §4 on toy dataset
- Evaluate: HMM vs Markov-Switching Autoregression (MSAR)
- Tool: Python (hmmlearn library) or R (depmixS4 package)
- **Not BQML native**: Requires external Python/R pipeline → more complex MLOps

**Sprint 3-4: Feature Engineering for HMM**
```python
# Train HMM per SKU family (group by product_category)
from hmmlearn import hmm
import numpy as np

# Define 3-state HMM
model = hmm.GaussianHMM(n_components=3, covariance_type="diag", n_iter=100)

# Fit on TRAIN data (demand series)
X = df_train[['y_sales', 'lag_1', 'roll13_mean']].values
model.fit(X)

# Predict state probabilities on VAL
states_val = model.predict_proba(X_val)

# Simulate quantiles from state distributions
p10 = np.percentile(model.means_[states_val.argmax(axis=1)], 10)
p50 = np.percentile(model.means_[states_val.argmax(axis=1)], 50)
p90 = np.percentile(model.means_[states_val.argmax(axis=1)], 90)
```

**Sprint 5-7: Validation on VAL Split**
- Compare HMM quantiles vs QRF baseline
- Metric: Pinball loss, quantile crossing rate
- Academic benchmark: Montoya-González MSOM 2019 Table 4 (30% improvement in 90th percentile service level)

**Sprint 8-10: Integration into BQML Pipeline**
- **Challenge**: HMM not native in BQML → must deploy via Vertex AI (Python)
- Create: `model_quantiles_h4_hmm` as Python custom predictor
- Deploy: Weekly batch prediction via Cloud Run / Vertex Pipelines

**Timeline**: 20+ weeks (Q3-Q4 2026), high research risk

**Risk**: VERY HIGH (academic method, not validated in Cruzber data, complex MLOps)

---

## 3. RECOMMENDED DECISION PATH

### Phase 1 (Immediate, W10-W15): ROUTE 1 (Recalibración Condicional)
**Why**:
- Lowest risk (academic validation exists)
- BQML-native (no new infrastructure)
- Addresses root cause (subset selection + stratification)
- 6-week timeline (fast iteration)

**Deliverables**:
- `subset_reliable_quantiles` table (30-40% of SKUs)
- `conditional_percentiles` table (season × HHI strata)
- Re-trained model `m_quantiles_h4_conditional`
- Validation report: pinball loss, deviation, quantile crossing rate

**Go/No-Go Decision** (W15, 2026-04-04):
- **IF deviation < ±3pp**: Proceed to Gate B1 (shadow mode)
- **IF deviation ≥ ±3pp BUT <±5pp**: Iterate (sprint 4-5 for feature refinement)
- **IF deviation ≥ ±5pp**: ABORT Route 1, escalate to Route 2

---

### Phase 2 (Parallel Research, W10-W17): ROUTE 2 (Pilot with ERP Ground Truth)
**Why**:
- Validate silver labels hypothesis (are they actually wrong?)
- Unblocks Route 1 if labels are good (accuracy >80%)
- Small scope (1-2 SKUs) = low cost

**Deliverables**:
- ERP integration script (`extract_inventory_level_daily.sql`)
- Label accuracy report (silver vs ground truth)
- Bias correction method (if needed)

**Go/No-Go Decision** (W17, 2026-04-25):
- **IF label accuracy >80%**: Silver labels acceptable, focus on Route 1
- **IF 60-80%**: Apply Kourentzes correction, re-validate Route 1
- **IF <60%**: Silver labels unreliable, MUST escalate to Route 3 (HMM)

---

### Phase 3 (Backup, Q3-2026): ROUTE 3 (HMM Research)
**Why**:
- Academic state-of-the-art (Montoya-González MSOM 2019)
- Naturally handles zero-inflation + quantile crossing
- Explores deeper: regime-switching better captures stockout dynamics

**Deliverables**:
- Literature review + algorithm replication (toy data)
- Proof-of-concept on 5-10 Cruzber SKUs
- Complexity assessment (MLOps feasibility)

**Decision Point** (Q3-2026): Deploy only if Route 1 + Route 2 both fail.

---

## 4. GATES & VALIDATION CRITERIA

### Gate B0: Offline Validation (Reproducible)
**Criteria** (ALL must pass):
1. ✅ Deviation P10/P50/P90 < ±3pp sustained 8 weeks
2. ✅ Pinball loss < baseline + 10%
3. ✅ Quantile crossing rate < 1%
4. ✅ Stratified metrics (season × HHI) all pass threshold
5. ✅ Academic review (external validator): methodology sound

**Current Status**: 🔴 FAIL (deviation >3pp, pinball loss worse than baseline)

**Target**: 2026-04-04 (W15, post-Route 1 implementation)

---

### Gate B1: Shadow Mode (4 weeks)
**Criteria**:
1. ✅ B0 passed
2. ✅ Dashboard live (quantile ranges P10-P50-P90 visualized)
3. ✅ Ops team review: "Do these ranges make sense?"
4. ✅ No systematic over/under-estimation flagged by ops

**Timeline**: IF B0 passes in W15 → B1 starts W16-W19 (April-May 2026)

---

### Gate B2: Production (50% Traffic)
**Criteria**:
1. ✅ B1 passed (4-week shadow successful)
2. ✅ Business impact validated: Safety stock improved by ≥10% OR stockout rate reduced by ≥15%
3. ✅ Academic publication: Submit paper to IJF or MSOM (credibility signal)
4. ✅ A/B test: Quantile-based planning beats baseline for 8 weeks

**Timeline**: Q4-2026 (earliest), conditional on B0+B1 success

---

## 5. BACKLOG ALIGNMENT

### From PLAN_ACCION_END_TO_END_CRUZBER.md

**P0.1 Recalibración Condicional** → **Route 1**  
- Priority: P0 (Critical)
- Sprints: 3 (W10-W12)
- Academic grounding: Kourentzes IJF 2017 §3.1, Montoya-González MSOM 2019 §5.2

**P0.4 Unconstraining con Ground Truth** → **Route 2**  
- Priority: P0 (Critical, conditional on ERP access)
- Sprints: 4 (W10-W13, pilot phase)
- Blocker: IT approval for ERP integration

**P2.2 Temporal Clustering (HMM)** → **Route 3**  
- Priority: P2 (Research, not production-critical)
- Sprints: 10+ (Q3-Q4 2026)
- Academic partnership: External validator (university collaboration)

---

## 6. RISKS & CONTINGENCIES

| Risk | Probability | Impact | Mitigation |
|------|-------------|--------|------------|
| **R1: Route 1 deviation still >3pp** | MEDIUM | HIGH | Fall back to Route 2 (pilot ERP ground truth) |
| **R2: ERP integration blocked** | HIGH | MEDIUM | Accept: Route 2 aborted, focus on Route 1 + Route 3 |
| **R3: HMM too complex for ops** | LOW | HIGH | Simplify: Use HMM for research, deploy simpler parametric model |
| **R4: Track B delays Q2-2026** | HIGH | LOW | Accept: Planning stays blocked, focus on Track A production |
| **R5: Academic partner unavailable** | MEDIUM | LOW | Internal validation: Rigorous cross-validation, document assumptions |

---

## 7. SUCCESS CRITERIA (FINAL)

### For Track B to Move to Production (Gate B2 Approval):

**Quantitative**:
1. ✅ Deviation P10/P50/P90 < ±3pp for 8 validation weeks
2. ✅ Pinball loss < baseline + 10%
3. ✅ Quantile crossing rate < 1% (monotonicity enforced)
4. ✅ Safety stock calculation validated: Stockout rate improved ≥15% vs baseline

**Qualitative**:
5. ✅ Ops team confident: "These ranges are actionable"
6. ✅ Academic review: Methodology published or accepted to peer-reviewed journal
7. ✅ Business sponsor approval: VP Operations signs off

**Timeline**: Earliest Q4-2026, conditional on Route 1 success.

---

## 8. REFERENCES & ACADEMIC GROUNDING

**Key Papers**:
1. **Kourentzes, N., Rostami-Tabar, B., & Barrow, D. (2017)**. "Demand forecasting by temporal aggregation: Using optimal or multiple aggregation levels?" *International Journal of Forecasting*, 33(4), §3.1.  
   → **Unconstraining thresholds**: intermittence <30%, CV <1.5

2. **Montoya-González, G., & Kourentzes, N. (2019)**. "Forecasting intermittent demand with latent states in the service sector." *Manufacturing & Service Operations Management*, 21(4), §4-6.  
   → **HMM with 3 states**: HIGH, LOW, OOS; stratified percentiles reduce bias by 40%

3. **Syntetos, A. A., Babai, M. Z., & Gardner, E. S. (2020)**. "Forecasting intermittent demand with fill rate constraints: Theory and empirics." *International Journal of Production Economics*, 224, §4.1.  
   → **Fill rate correction**: adjust quantiles by observed stockout frequency

---

## 9. NEXT ACTIONS (WEEK W08)

**Monday 2026-02-17**:
- [ ] **Hugo**: Create GitHub issue for P0.1 (Route 1 sprints)
- [ ] **Hugo**: Email IT/Supply Chain: Request ERP access for pilot (Route 2)

**Tuesday 2026-02-18**:
- [ ] **Hugo**: Literature review: Re-read Montoya-González MSOM 2019 §5.2
- [ ] **Hugo**: Prepare SQL for `subset_reliable_quantiles` table

**Wednesday 2026-02-19**:
- [ ] **Hugo**: Sprint 1 kickoff (Route 1): Subset selection query
- [ ] **Hugo**: Validate: How many SKUs pass thresholds (amplitude>5, cv<1.5)?

**Thursday 2026-02-20**:
- [ ] **Hugo**: Draft conditional percentiles query (season × HHI strata)
- [ ] **Hugo**: Document assumptions: Why these thresholds?

**Friday 2026-02-21**:
- [ ] **Hugo**: Week 1 checkpoint: Present Route 1 progress to stakeholders
- [ ] **Hugo**: Decision: Confirm Route 1 priority, Route 2 parallel research

---

**SIGN-OFF**:
- [ ] **Data Science Lead** (Hugo de Val): Approved for Route 1 implementation (W10 start)  
- [ ] **VP Operations**: Informed of Track B NO-GO status, accept planning blocked until Q3-2026  
- [ ] **IT/Supply Chain**: Informed of ERP access request (Route 2 pilot)  

**Last Updated**: 2026-02-14 19:00 CET  
**Next Review**: 2026-03-28 (W13, post-Route 1 completion, Gate B0 decision)
