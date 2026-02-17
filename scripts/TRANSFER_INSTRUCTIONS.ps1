# ===========================================================================
# TRANSFER MODELS TO thequantitativeledger - MANUAL STEPS
# ===========================================================================
# Las credenciales de gcloud necesitan renovarse para transferencias cross-project
# Ejecuta estos comandos en orden:

# 1. Renovar credenciales de gcloud
gcloud auth login hugo@deval.work

# 2. Copiar tabla de features (async copy, ~5 min) 
bq --project_id=voltaic-tuner-475510-s4 cp `
    --sync=false `
    --location=EU `
    voltaic-tuner-475510-s4:dataset_cruzber_eu.weekly_features_h4 `
    thequantitativeledger:cruzber_models.weekly_features_h4

# 3. Verificar que la copia completó
bq --project_id=thequantitativeledger show thequantitativeledger:cruzber_models.weekly_features_h4

# 4. Entrenar modelo m_oos_h4 en el proyecto destino
$env:GCP_PROJECT_ID="thequantitativeledger"
$env:BQ_DATASET_ID="cruzber_models"
$env:BQ_LOCATION="europe-southwest1"
python src/bq/run_sql.py --sql-file sql/models/10_train_oos_h4.sql

# 5. Score validation set
python src/bq/run_sql.py --sql-file sql/models/11_score_oos_h4.sql

# 6. Train calibration model
python src/bq/run_sql.py --sql-file sql/models/12_calibrate_platt.sql

# 7. Verificar modelos creados
bq --project_id=thequantitativeledger ls --models cruzber_models

# ✅ COMPLETO
# Los modelos estarán disponibles en:
#  - thequantitativeledger.cruzber_models.m_oos_h4
#  - thequantitativeledger.cruzber_models.m_platt_oos_h4
