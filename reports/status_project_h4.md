# PROJECT STATUS REPORT: CRUZBER OOS FORECASTING

**Date**: 2026-02-14  
**Project**: Stockout Prediction System (h=4 weeks)  
**Owner**: Hugo de Val (hugo@deval.work)

---

## 1. OVERALL STATUS: 🟡 CONDITIONAL GO

### Semaphore Summary

| Track | System | Status | Gate | Next Milestone |
|-------|--------|--------|------|----------------|
| **Track A** | ALERTING (Top-K) | 🟡 **CONDITIONAL GO** | A0 PASS, A1 PENDING | Shadow mode (4 weeks) |
| **Track B** | QUANTILES (P10/P50/P90) | 🔴 **NO-GO** | B0 FAIL (deviation >3pp) | Recalibration research phase |

---

## 2. TRACK A: ALERTING (TOP-K) - DETAILED STATUS

### Current Metrics (Validation H2-2024)

| Metric | Target | Actual | Status | Evidence |
|--------|--------|--------|--------|----------|
| **Precision@100** | ≥20% | **24.1% pooled** | ✅ **PASS** | `scorecard_go_nogo_h4` S03 |
| **Lift@100** | ≥10x | **13.95x-14.94x** | ✅ **PASS** | `scorecard_go_nogo_h4` S04 |
| **AUC** | ≥0.75 | **0.8455** | ✅ **PASS** | `scorecard_go_nogo_h4` S02 |
| **Recall@100** | ≥30% | **36.9%-57.8%** (HIGH) | ✅ **PASS** | `metrics_alerting_pooled` |
| **Brier Score** | <0.05 | **0.0171** | ✅ **PASS** | `scorecard_go_nogo_h4` S07 |
| **Leakage** | <0.05 | **0.0029** | ✅ **PASS** | `scorecard_go_nogo_h4` S01 |
| **HHI Drift** | Ratio <2x | **10.19x** | 🟠 **MARGINAL** | `scorecard_go_nogo_h4` S06 |
| **Stability (CV)** | <0.50 | **0.5042** | 🟠 **MARGINAL** | `scorecard_go_nogo_h4` S08 |

### Gate Status: A0, A1, A2

**A0: Offline Validation** ✅ **PASS**
- Scorecard: 5 PASS, 0 FAIL, 2 MARGINAL (acceptable per plan)
- Precision@100 > 20% sustained across 26 validation weeks
- HHI bucket stratification implemented (buckets A/B/C)

**A1: Shadow Mode** ⏳ **PENDING**
- Duration: 4 weeks (2026-W08 to W11)
- Requirements:
  - [ ] Dashboard live in Looker Studio (latest_metrics_weekly view)
  - [ ] Ops team trained (ALERTING_RUNBOOK.md)
  - [ ] Feedback loop active (alerts_feedback table populated)
  - [ ] Daily precision monitoring (automated query)
- **Target Start**: 2026-02-17 (Monday W08)

**A2: Production (50% Traffic)** ⏳ **BLOCKED BY A1**
- Triggers: Feedback precision ≥ model precision - 5pp for 3 weeks
- Estimated: 2026-03-24 (W13, post-shadow)

### Known Issues & Mitigations

**Issue 1: HHI Drift (VAL/TRAIN ratio 10.19x vs target <2x)**  
- **Root Cause**: 2024 saw customer concentration spike (whales)
- **Impact**: Model may underperform on diversified SKUs (bucket A)
- **Mitigation**: 
  - Stratified alerting (separate Top-K per HHI bucket)
  - Monitor precision by HHI bucket weekly
  - Planned: P0.3 backlog (bucket-specific models) Q2-2026

**Issue 2: Stability CV = 0.5042 (marginal, target <0.5)**  
- **Root Cause**: Precision@100 varied 20.1%-30.2% across 26 weeks (intrinsic seasonality)
- **Impact**: Ops experience variable alert quality HIGH vs REST season
- **Mitigation**:
  - Season-stratified Top-K (TOP-50 HIGH, TOP-100 REST)
  - SLA adjustment: HIGH season → 24h, REST → 72h
  - Planned: P1.1 backlog (season-aware features) Q3-2026

---

## 3. TRACK B: QUANTILES (P10/P50/P90) - DETAILED STATUS

### Current Metrics (Audit Completed 2026-02-10)

| Metric | Target | Actual | Status | Evidence |
|--------|--------|--------|--------|----------|
| **P90 Deviation** | <3pp | **-5.34pp** | 🔴 **FAIL** | Audit Table 15 |
| **P50 Deviation** | <3pp | **-8.47pp** | 🔴 **FAIL** | Audit Table 15 |
| **P10 Deviation** | <3pp | **+12.01pp** | 🔴 **FAIL** | Audit Table 15 |
| **Pinball Loss (P90)** | <baseline | **4.32 worse** | 🔴 **FAIL** | Audit Table 16 |

### Gate Status: B0, B1, B2

**B0: Offline Validation** 🔴 **FAIL**
- Verdict: NO-GO until deviation <±3pp sustained 8 weeks
- Scorecard: 0 PASS, 4 FAIL
- Systematic bias: Over-predicts low quantiles, under-predicts high

**B1: Shadow Mode** ⏳ **BLOCKED BY B0**  
**B2: Production** ⏳ **BLOCKED BY B0**

### Root Cause (from Audit RCA)
1. **Silver Labels**: No ground truth inventory, only sales-based OOS approximation
2. **Unconstraining Bias**: Kourentzes (2017) method requires intermittence <30%, Cruzber has 45%
3. **Quantile Regression Limitations**: QRF trained on biased silver labels propagates error

### Remediation Plan (See plan_trackB_quantiles.md)

**Option 1: Recalibración Condicional** (P0.1, 3 sprints)
- Subset: amplitude > 5 (excludes long-tail)
- Stratified percentiles by season × HHI
- Academic grounding: Kourentzes (2017) §3.1, Montoya-González (2019) §5.2

**Option 2: Unconstraining with Ground Truth** (P0.4, 4 sprints)
- Require: Inventory snapshot from ERP (1-2 SKUs pilot)
- Validate: Kourentzes method with actual stock
- Scale: If pilot succeeds, expand to 50 SKUs

**Option 3: Temporal Clustering** (P2.2, research phase)
- HMM from Montoya-González MSOM 2019 §4-6
- Regime-switching: HIGH demand vs NEAR-OOS vs OOS states
- Timeline: Q3-2026 (academic partnership)

**DECISION**: Prioritize Option 1 (start 2026-W10), parallel research on Option 3.

---

## 4. TECHNICAL INFRASTRUCTURE STATUS

### BigQuery ML Pipeline

**Components** ✅ **COMPLETE**
- [x] SQL modular structure (13 files across 4 phases)
- [x] Python runner with ADC (`src/bq/run_sql.py`)
- [x] PowerShell orchestrators (`run_pipeline_trackA.ps1`, `run_eval_only.ps1`)
- [x] Automated scorecard (8 checks S01-S08)
- [x] HHI stratification (buckets A/B/C)
- [x] Human-in-loop feedback schema
- [x] Dashboard views (latest_metrics_weekly, latest_scorecard, etc.)

**Authentication** ✅ **ADC ONLY**
- No hardcoded credentials
- Deployment: `gcloud auth application-default login`
- IAM role: `BigQuery Data Editor` + `BigQuery Job User`

**Parameterization** ✅ **MULTI-ENVIRONMENT READY**
- Environment variables: `GCP_PROJECT_ID`, `BQ_DATASET_ID`, `BQ_LOCATION`
- SQL placeholders: `{project_id}`, `{dataset_id}`, `{dataset_ref}`
- Tested: dev environment (local), ready for staging/prod

### Tables Created (20+)

| Phase | Table | Rows | Purpose |
|-------|-------|------|---------|
| **Features** | `sales_weekly_base` | ~500k | Dense spine (calendar × SKU) |
| | `weekly_features_h4` | ~480k | Lag + roll + HHI features |
| **Models** | `m_oos_h4` | Model | BQML Boosted Tree Classifier |
| | `m_platt_oos_h4` | Model | Platt calibration (logistic) |
| | `score_oos_h4_raw` | ~120k | Predictions CALIB+VAL raw |
| | `score_oos_h4_calibrated` | ~120k | Predictions CALIB+VAL calibrated |
| | `feature_importance_oos_h4` | 13 rows | Feature importance scores |
| **Eval** | `metrics_alerting_weekly` | ~78 | Prec@K weekly (k=50,100,200) |
| | `metrics_alerting_pooled` | 12 | Prec@K pooled by season×HHI |
| | `scorecard_go_nogo_h4` | 8 rows | Automated GO/NO-GO checks |
| **Alerting** | `hhi_buckets` | ~2000 | HHI stratification A/B/C |
| | `alerts_topk_weekly` | ~2600 | Top-K alerts (26 weeks × 100) |
| | `alerts_feedback` | 0 (empty) | Human feedback (to populate) |

---

## 5. RISKS & DEPENDENCIES

### Active Risks

| Risk | Probability | Impact | Mitigation |
|------|-------------|--------|------------|
| **R1: Ops team not trained** | MEDIUM | HIGH | Create training session W08 (Feb 17) |
| **R2: Dashboard not live by A1** | LOW | HIGH | Pre-build Looker Studio dashboard W07 |
| **R3: Feedback loop not adopted** | MEDIUM | MEDIUM | Gamification: leaderboard for reviewers |
| **R4: HHI drift worsens** | LOW | HIGH | Monitor weekly, trigger P0.3 if ratio >15x |
| **R5: Track B delays planning** | HIGH | MEDIUM | Accept: planning stays blocked until B0 passes |

### External Dependencies

| Dependency | Owner | Status | Blocker For |
|------------|-------|--------|-------------|
| **ERP inventory snapshot** | IT/Supply Chain | 🟠 Pending approval | Track B Option 2 (pilot) |
| **Looker Studio access** | IT/BI Team | ✅ Approved | A1 shadow mode dashboard |
| **IAM permissions** | Cloud Admin | ⏳ Requested (Feb 12) | Production deployment |

---

## 6. NEXT 7-DAY ACTIONS (2026-W08)

### Monday 2026-02-17
- [ ] **Hugo**: Deploy dashboard to Looker Studio (connect to `latest_*` views)
- [ ] **Ops Lead**: Schedule training session (2h, all ops team)

### Tuesday 2026-02-18
- [ ] **Hugo**: Conduct training (ALERTING_RUNBOOK.md walkthrough)
- [ ] **Ops Team**: First shadow alert review (this week's Top-100)

### Wednesday 2026-02-19
- [ ] **Ops Team**: Record feedback for 10 alerts (alerts_feedback table)
- [ ] **Hugo**: Monitor precision (query feedback_summary_weekly)

### Thursday 2026-02-20
- [ ] **Hugo**: Weekly metrics review (precision@100 last 4 weeks)
- [ ] **Ops Lead**: Adjust SLA if needed (HIGH 24h, MEDIUM 72h)

### Friday 2026-02-21
- [ ] **Hugo + Ops**: Week 1 retrospective (what worked, what didn't)
- [ ] **Hugo**: Document learnings in runbook updates

### Next Week Prep
- [ ] **Hugo**: Prepare A1 gate checklist (4-week shadow mode targets)
- [ ] **Hugo**: Start P0.1 research (recalibración condicional for Track B)

---

## 7. KEY PERFORMANCE INDICATORS (WEEKLY TRACKING)

### Alerting Metrics (Track A)

**Query: Last 4 Weeks Precision**
```sql
SELECT
  week_start_date,
  season_group,
  ROUND(precision_at_k, 3) AS prec,
  ROUND(lift_at_k, 2) AS lift
FROM `voltaic-tuner-475510-s4.dataset_cruzber_eu.metrics_alerting_weekly`
WHERE k = 100
  AND week_start_date >= DATE_SUB(CURRENT_DATE(), INTERVAL 4 WEEK)
ORDER BY week_start_date DESC, season_group;
```

**Target**: Precision@100 ≥ 20% sustained (no week <18%)

### Feedback Metrics (Track A Shadow Mode)

**Query: Feedback Precision**
```sql
SELECT
  week_start_date,
  feedback_count,
  ROUND(precision_feedback, 3) AS feedback_prec,
  ROUND(model_precision_at_k, 3) AS model_prec,
  ROUND(precision_feedback - model_precision_at_k, 3) AS delta
FROM `voltaic-tuner-475510-s4.dataset_cruzber_eu.feedback_summary_weekly`
WHERE week_start_date >= DATE_SUB(CURRENT_DATE(), INTERVAL 4 WEEK)
ORDER BY week_start_date DESC;
```

**Target**: feedback_prec ≥ model_prec - 5pp (within 3 weeks)

---

## 8. STAKEHOLDER COMMUNICATION

### Weekly Update (Mondays)
**To**: Ops Manager, VP Operations, Data Science Team  
**Format**: Email with:
- Precision@100 last week (single number + 🟢/🟡/🔴)
- Top-5 alerts this week (SKUs + prob_oos)
- Issues encountered (if any)

### Bi-Weekly Deep Dive (Fridays)
**To**: Extended stakeholders (Supply Chain, Finance, Account Managers)  
**Format**: 30-min meeting with:
- Dashboard walkthrough
- Whale alerts review (bucket C)
- Feedback loop status
- Track B progress update

---

## 9. BUDGET & RESOURCES

### Compute Costs (BigQuery)

**Estimated Monthly Cost**: $120-180 USD
- Feature engineering: ~15 GB processed/week → $0.75/week → $3/month
- Model training (quarterly): 50 GB → $2.50/quarter → $0.83/month
- Scoring (weekly): 5 GB/week → $0.25/week → $1/month
- Monitoring queries: 2 GB/week → $0.10/week → $0.40/month
- **Total**: ~$5-6/month (negligible vs business impact)

### Human Resources

| Role | Hours/Week | Phase | Total Sprints |
|------|------------|-------|---------------|
| **Data Scientist** (Hugo) | 8h | Shadow mode monitoring | 4 sprints (W08-W11) |
| **Ops Team** (5 FTEs) | 2h each | Alert review + feedback | Ongoing |
| **Data Engineer** | 4h | Dashboard + IAM setup | 1 sprint (W07) |

---

## 10. SUCCESS CRITERIA (GATE APPROVAL)

### Track A: Move to Production (A2)
✅ **Criteria**:
1. Shadow mode completed (4 weeks)
2. Feedback precision ≥ 19% (model - 5pp)
3. Ops team trained and confident
4. No Severity 1 incidents during shadow
5. Dashboard live and monitored daily

**Decision Date**: 2026-03-21 (Friday W12)

### Track B: Move to Shadow Mode (B1)
✅ **Criteria**:
1. Offline deviation P10/P50/P90 < ±3pp
2. Pinball loss < baseline heuristic +10%
3. Sustained 8 validation weeks
4. Academic review (external validator)

**Decision Date**: TBD (currently NO-GO, estimated Q3-2026)

---

## 11. REFERENCES

**Code Repository**: `c:\Users\hugod\...\ISDI - MDA\Troncal`  
**Key Files**:
- Pipeline: `src/run_pipeline_trackA.ps1`
- Runbooks: `docs/runbooks/ALERTING_RUNBOOK.md`, `MONITORING_ROLLBACK.md`
- SQL: `sql/features/*.sql`, `sql/models/*.sql`, etc.
- Action Plan: `PLAN_ACCION_END_TO_END_CRUZBER.md` (11.2k lines)

**Dashboards**:
- BigQuery Console: [scorecard_go_nogo_h4](https://console.cloud.google.com/bigquery?project=voltaic-tuner-475510-s4&ws=!1m5!1m4!4m3!1svoltaic-tuner-475510-s4!2sdataset_cruzber_eu!3sscorecard_go_nogo_h4)
- Looker Studio: [TBD - to be created W08]

---

**SIGN-OFF**:
- [ ] **Data Science Lead** (Hugo de Val): Approved for A1 shadow mode  
- [ ] **Ops Manager**: Approved for A1 shadow mode  
- [ ] **VP Operations**: Informed of Track B NO-GO status  

**Last Updated**: 2026-02-14 18:30 CET  
**Next Review**: 2026-02-21 (post-week 1 shadow mode)
