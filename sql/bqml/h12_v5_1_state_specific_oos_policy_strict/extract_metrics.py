#!/usr/bin/env python3
"""
Extract and display key metrics from h12_v5_1 pipeline results.
"""

from google.cloud import bigquery
import sys

def main():
    client = bigquery.Client()
    
    print("=" * 80)
    print("h12_v5_1 STATE-SPECIFIC OOS POLICY - METRICS SUMMARY")
    print("=" * 80)
    print()
    
    # ============================================================================
    # 1. LOCKED_TEST GLOBAL METRICS
    # ============================================================================
    print("=" * 80)
    print("1. LOCKED_TEST GLOBAL METRICS")
    print("=" * 80)
    
    query_metrics = """
    SELECT
      n_obs,
      n_true_oos,
      base_rate,
      n_stable_alerts,
      stable_precision,
      stable_recall,
      n_difficult_alerts,
      difficult_precision,
      difficult_recall,
      n_combined_alerts,
      combined_precision,
      combined_recall,
      incremental_alerts,
      incremental_recall_points
    FROM `thequantitativeledger.cruzber_models_eu.final_locked_test_metrics_h12_v5_1_strict`
    WHERE segment_type = 'GLOBAL'
    """
    
    try:
        df_metrics = client.query(query_metrics).to_dataframe()
        if not df_metrics.empty:
            row = df_metrics.iloc[0]
            print(f"Total Observations:     {row['n_obs']:,}")
            print(f"Total Stockouts:        {row['n_true_oos']:,} ({row['base_rate']:.2%})")
            print()
            print(f"Stable Alerts:          {row['n_stable_alerts']:,}")
            print(f"  Precision:            {row['stable_precision']:.4f}")
            print(f"  Recall:               {row['stable_recall']:.4f}")
            print()
            print(f"Difficult State Alerts: {row['n_difficult_alerts']:,}")
            print(f"  Precision:            {row['difficult_precision']:.4f}")
            print(f"  Recall:               {row['difficult_recall']:.4f}")
            print()
            print(f"Combined Alerts:        {row['n_combined_alerts']:,}")
            print(f"  Precision:            {row['combined_precision']:.4f}")
            print(f"  Recall:               {row['combined_recall']:.4f}")
            print()
            print(f"Incremental:            +{row['incremental_alerts']:,} alerts, +{row['incremental_recall_points']:.4f} recall points")
        else:
            print("⚠️  No global metrics found")
    except Exception as e:
        print(f"❌ Error reading metrics: {e}")
    
    print()
    
    # ============================================================================
    # 2. INCREMENTAL UPLIFT ANALYSIS & VERDICT
    # ============================================================================
    print("=" * 80)
    print("2. INCREMENTAL UPLIFT ANALYSIS & DECISION VERDICT")
    print("=" * 80)
    
    query_uplift = """
    SELECT
      baseline_alerts,
      baseline_precision,
      baseline_recall,
      baseline_f1,
      incremental_alerts,
      incremental_precision,
      incremental_recall,
      incremental_f1,
      net_f1_gain,
      precision_degradation,
      alert_volume_increase_pct,
      weekly_alert_std,
      decision_verdict,
      verdict_reason
    FROM `thequantitativeledger.cruzber_models_eu.incremental_uplift_analysis_h12_v5_1_strict`
    """
    
    try:
        df_uplift = client.query(query_uplift).to_dataframe()
        if not df_uplift.empty:
            row = df_uplift.iloc[0]
            
            print("\n🔹 BASELINE (Stable Core Alerts Only):")
            print(f"   Alerts:     {row['baseline_alerts']:,}")
            print(f"   Precision:  {row['baseline_precision']:.4f}")
            print(f"   Recall:     {row['baseline_recall']:.4f}")
            print(f"   F1 Score:   {row['baseline_f1']:.4f}")
            
            print("\n🔹 INCREMENTAL (Difficult State Alerts):")
            print(f"   Alerts:     {row['incremental_alerts']:,}")
            print(f"   Precision:  {row['incremental_precision']:.4f}")
            print(f"   Recall:     {row['incremental_recall']:.4f}")
            print(f"   F1 Score:   {row['incremental_f1']:.4f}")
            
            print("\n🔹 NET IMPACT:")
            print(f"   F1 Gain:             {row['net_f1_gain']:+.6f}")
            print(f"   Precision Loss:      {row['precision_degradation']:+.6f}")
            print(f"   Alert Volume ↑:      {row['alert_volume_increase_pct']:.2%}")
            print(f"   Weekly Alert Std:    {row['weekly_alert_std']:.2f}")
            
            print("\n" + "=" * 80)
            verdict = row['decision_verdict']
            reason = row['verdict_reason']
            
            verdict_emoji = {
                'PROMOTE': '🎉',
                'EXPERIMENTAL': '🧪',
                'REJECT': '❌',
                'KEEP_STABLE_ONLY': '⚠️'
            }.get(verdict, '❓')
            
            print(f"{verdict_emoji} DECISION VERDICT: {verdict}")
            print("=" * 80)
            print(f"Reason: {reason}")
            print("=" * 80)
        else:
            print("⚠️  No uplift analysis found")
    except Exception as e:
        print(f"❌ Error reading uplift analysis: {e}")
    
    print()
    
    # ============================================================================
    # 3. FROZEN POLICY PARAMETERS
    # ============================================================================
    print("=" * 80)
    print("3. FROZEN DIFFICULT STATE POLICY")
    print("=" * 80)
    
    query_policy = """
    SELECT
      candidate_id,
      gate_set,
      percentile_config,
      quota_config,
      selection_loss,
      dev_select_precision,
      dev_select_recall,
      dev_select_f1
    FROM `thequantitativeledger.cruzber_models_eu.frozen_difficult_state_policy_h12_v5_1_strict`
    """
    
    try:
        df_policy = client.query(query_policy).to_dataframe()
        if not df_policy.empty:
            row = df_policy.iloc[0]
            print(f"Selected Candidate:  {row['candidate_id']}")
            print(f"Gate Set:            {row['gate_set']}")
            print(f"Percentile Config:   {row['percentile_config']}")
            print(f"Quota Config:        {row['quota_config']}")
            print(f"\nDEV_SELECT Performance:")
            print(f"  Selection Loss:    {row['selection_loss']:.6f}")
            print(f"  Precision:         {row['dev_select_precision']:.4f}")
            print(f"  Recall:            {row['dev_select_recall']:.4f}")
            print(f"  F1 Score:          {row['dev_select_f1']:.4f}")
        else:
            print("⚠️  No frozen policy found")
    except Exception as e:
        print(f"❌ Error reading policy: {e}")
    
    print()
    
    # ============================================================================
    # 4. TOP ALERTS BREAKDOWN
    # ============================================================================
    print("=" * 80)
    print("4. TOP ALERTS BREAKDOWN")
    print("=" * 80)
    
    query_top_alerts = """
    SELECT
      alert_source,
      COUNT(*) as alert_count
    FROM `thequantitativeledger.cruzber_models_eu.top_alerts_combined_h12_v5_1_strict`
    GROUP BY alert_source
    ORDER BY alert_count DESC
    """
    
    try:
        df_alerts = client.query(query_top_alerts).to_dataframe()
        if not df_alerts.empty:
            for _, row in df_alerts.iterrows():
                print(f"{row['alert_source']:30s}: {row['alert_count']:,}")
        else:
            print("⚠️  No top alerts found")
    except Exception as e:
        print(f"❌ Error reading top alerts: {e}")
    
    print()
    
    # ============================================================================
    # 5. LEAKAGE AUDIT SUMMARY
    # ============================================================================
    print("=" * 80)
    print("5. ANTI-LEAKAGE AUDIT")
    print("=" * 80)
    
    query_audit = """
    SELECT
      check_id,
      check_name,
      check_status,
      check_value
    FROM `thequantitativeledger.cruzber_models_eu.leakage_audit_h12_v5_1_strict`
    ORDER BY check_id
    """
    
    try:
        df_audit = client.query(query_audit).to_dataframe()
        if not df_audit.empty:
            pass_count = (df_audit['check_status'] == 'PASS').sum()
            fail_count = (df_audit['check_status'] == 'FAIL').sum()
            warn_count = (df_audit['check_status'] == 'WARNING').sum()
            
            print(f"✅ PASS:    {pass_count}")
            print(f"⚠️  WARNING: {warn_count}")
            print(f"❌ FAIL:    {fail_count}")
            print()
            
            # Show any failures or warnings
            issues = df_audit[df_audit['check_status'].isin(['FAIL', 'WARNING'])]
            if not issues.empty:
                print("Issues detected:")
                for _, row in issues.iterrows():
                    emoji = '❌' if row['check_status'] == 'FAIL' else '⚠️'
                    print(f"  {emoji} #{row['check_id']:02d} {row['check_name']}: {row['check_value']}")
            else:
                print("🎉 All checks passed!")
                
            # Show final verdict
            final = df_audit[df_audit['check_id'] == 17]
            if not final.empty:
                verdict_row = final.iloc[0]
                print()
                print("=" * 80)
                print(f"FINAL AUDIT VERDICT: {verdict_row['check_status']}")
                print("=" * 80)
        else:
            print("⚠️  No audit results found")
    except Exception as e:
        print(f"❌ Error reading audit: {e}")
    
    print()
    print("=" * 80)
    print("END OF METRICS SUMMARY")
    print("=" * 80)

if __name__ == "__main__":
    main()
