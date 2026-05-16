#!/usr/bin/env python3
"""
Extract LOCKED_TEST metrics from h12_v5 OOS State Layer
"""

from google.cloud import bigquery

# Initialize client
client = bigquery.Client(project="thequantitativeledger", location="EU")

# Query
query = """
SELECT 
  metric_family,
  segment_type,
  segment_value,
  n_obs,
  n_flagged_oos,
  n_true_oos_events,
  ROUND(precision_at_top_n, 4) AS precision,
  ROUND(recall_at_top_n, 4) AS recall,
  ROUND(f1_score, 4) AS f1,
  ROUND(lift, 2) AS lift,
  ROUND(false_positive_rate, 4) AS fpr,
  ROUND(pct_expected_lost_sales_captured, 4) AS pct_lost_sales
FROM `thequantitativeledger.cruzber_models_eu.oos_locked_test_metrics_h12_v5_strict`
ORDER BY metric_family, segment_type, segment_value;
"""

print("\n" + "="*80)
print("h12_v5 LOCKED_TEST Metrics")
print("="*80 + "\n")

# Execute query
query_job = client.query(query)
results = query_job.result()

# Print header
print(f"{'Metric Family':<20} {'Segment Type':<20} {'Segment Value':<20} {'N Obs':>8} {'Flagged':>8} {'True OOS':>8} {'Prec':>6} {'Recall':>6} {'F1':>6} {'Lift':>6} {'FPR':>6} {'Lost%':>6}")
print("-" * 150)

# Print results
for row in results:
    # Handle NULL values
    prec = row.precision if row.precision is not None else 0.0
    rec = row.recall if row.recall is not None else 0.0
    f1 = row.f1 if row.f1 is not None else 0.0
    lift = row.lift if row.lift is not None else 0.0
    fpr = row.fpr if row.fpr is not None else 0.0
    lost = row.pct_lost_sales if row.pct_lost_sales is not None else 0.0
    
    print(f"{row.metric_family:<20} {row.segment_type:<20} {row.segment_value:<20} {row.n_obs:>8} {row.n_flagged_oos:>8} {row.n_true_oos_events:>8} {prec:>6.4f} {rec:>6.4f} {f1:>6.4f} {lift:>6.2f} {fpr:>6.4f} {lost:>6.4f}")

print("\n" + "="*80)
print("Metrics extraction complete")
print("="*80 + "\n")

# Calculate base rate from GLOBAL threshold metrics
query_base = """
SELECT 
  n_true_oos_events,
  n_obs,
  ROUND(n_true_oos_events / n_obs, 4) AS base_rate
FROM `thequantitativeledger.cruzber_models_eu.oos_locked_test_metrics_h12_v5_strict`
WHERE metric_family = 'threshold_metrics' 
  AND segment_type = 'GLOBAL'
  AND segment_value = 'ALL';
"""

print("\n" + "="*80)
print("Base Rate Calculation")
print("="*80 + "\n")

query_job = client.query(query_base)
results = query_job.result()

for row in results:
    base_rate = row.base_rate
    print(f"True OOS events: {row.n_true_oos_events}")
    print(f"Total observations: {row.n_obs}")
    print(f"Base rate: {base_rate:.4f} ({base_rate*100:.2f}%)")
    print(f"\nEXPERIMENTAL_STRONG_SIGNAL criteria:")
    print(f"  - Precision >= 2x base rate: >= {2*base_rate:.4f}")
    print(f"  - Recall >= 20%: >= 0.20")

print("\n" + "="*80 + "\n")
