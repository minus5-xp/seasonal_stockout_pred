# Reproducibility — Option B (Paper)

## Preconditions (ADC)
1. `gcloud auth login hugo@deval.work`
2. `gcloud auth application-default login`
3. `gcloud config set project <PROJECT_ID>`
4. Set env vars:
   - `GCP_PROJECT_ID=<PROJECT_ID>`
   - `BQ_DATASET_ID=<DATASET_ID>`
   - `BQ_LOCATION=EU`

## One-command pipeline
```powershell
C:/Users/hugod/jupyter-ai/python.exe src/bq/pipeline_optionB.py --project-id $env:GCP_PROJECT_ID --dataset-id $env:BQ_DATASET_ID --location $env:BQ_LOCATION
```

## Artifacts produced
- BigQuery:
  - `pred_oos_h4_canonical`
  - `demand_unconstrained_h4`
  - `pred_quantiles_h4`
  - `policy_sim_results_h4`
  - `submission_readiness_h4`
- Local reports:
  - `reports/B0_definitions_and_protocol.md`
  - `reports/B2_unconstraining_methods.md`
  - `reports/B3_quantiles_eval.md`
  - `reports/B4_policy_simulation.md`
  - `paper/submission_readiness.md`

## Claims guardrails
- All outputs are **sales-only proxy** based.
- Never label model output as true observed stockout.
- If B3/B4 gates fail, final verdict must remain **NO submit-ready yet**.
