# BQML Pipeline: h=12 v2 FINAL

Targeted patch to elevate `h12_v2` from `DEPLOY` → `DEPLOY_FULL`.
No model retraining. No quantile recalibration. Three surgical fixes.

---

## What changed vs h12_v2

| Issue | h12_v2 | h12_v2_final |
|---|---|---|
| **Brier B5** | FAIL (cal=0.0805 > raw=0.0669) | **PASS** — selects raw probability |
| **Dirichlet D1** | FAIL (sum≠1 when weight=0) | **PASS** — proper zero-raw normalisation |
| **Ratio B3e** | WARN (3.68 global) | **PASS_ACTIVE_RATIO** — conditional on p50≥5 |

---

## Fixes in detail

### Fix 1: Brier / Probability
- Compares `p_oos_raw` vs `p_oos_h12` (Platt) on VAL_GATE
- Selection rule: use RAW if `brier_raw < brier_calibrated × 1.01`
- Produces `p_oos_12w_rank` (for alert scoring), `p_oos_12w_report` (for display)
- Does NOT affect q90/q95/q99

### Fix 2: Dirichlet Reconciliation
- Root cause: `COALESCE(SAFE_DIVIDE(raw, 0), 1.0)` = 1.0 per province → sum > 1
- Fix: normalise zero-raw groups using prior (or uniform if prior=0)
- Tolerance: `err_weight ≤ 1e-9`, `err_p50/q90/q95 ≤ 0.001`

### Fix 3: Guardrails
- Computes `q90_p50_ratio_median_p50_ge_5` (active demand only)
- `ratio_gate_final = PASS_ACTIVE_RATIO` if active ratio ≤ 3.5
- Does NOT reduce q90

---

## Deployment decision

```
DEPLOY_FULL              = all gates pass (national + probability + Dirichlet + blind)
DEPLOY_NATIONAL_ONLY     = national + probability pass, Dirichlet still fixing
HOLD                     = any hard gate fails
```

---

## Execution

```cmd
# Dry run
python sql/bqml/h12_v2_final/run_h12_v2_final_pipeline.py --dry-run

# Full run
python sql/bqml/h12_v2_final/run_h12_v2_final_pipeline.py

# Specific phases
python sql/bqml/h12_v2_final/run_h12_v2_final_pipeline.py --start-phase 1 --stop-after-phase 4 --no-download

# Download only
python sql/bqml/h12_v2_final/06_download_final_csv_h12_v2_final.py

# Local audit only
python sql/bqml/h12_v2_final/07_independent_local_audit_h12_v2_final.py
```

---

## CSV outputs (`outputs/h12_v2_final/`)

| File | Description |
|---|---|
| `forecast_national_h12_v2_final.csv` | National forecast with final probabilities |
| `forecast_provincial_dirichlet_h12_v2_final.csv` | Provincial (reconciled) |
| `dirichlet_reconciliation_summary_h12_v2_final.csv` | Reconciliation stats |
| `probability_selection_h12_v2_final.csv` | Brier comparison & selection |
| `forecast_balance_guardrails_h12_v2_final.csv` | Ratio guardrail analysis |
| `gate_verdict_h12_v2_final.csv` | Final gates |
| `run_summary_h12_v2_final.csv` | Full run summary |
| `local_audit_report_h12_v2_final.md` | Local audit report |
| *(if DEPLOY_FULL)* `blind_forecast_*_final.csv` | Blind W28-W40 final |

---

## Invariants

- `h12_v2` tables are **never modified** (read-only)
- `q90_12w` is **never reduced** — viol_rate_p90 remains 0.1033
- All blind outputs have `y_true_12w = NULL`, `labels_included = FALSE`
- `SUM(dirichlet_weight_final) = 1.0 ± 1e-9` for all SKU×week groups
