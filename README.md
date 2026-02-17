# OOS Seasonal Fillrate Forecasting (h=4)

**Proyecto**: Predicción de Out-of-Stock con horizonte 4 semanas  
**Cliente**: CRUZBER  
**Dataset**: thequantitativeledger.cruzber_models_eu  

## Estructura

```
oos_seasonal_fillrate/
 sql/                    # Queries SQL/BQML
    bqml/              # Pipeline completo (B0-B5)
    baselines/         # Modelos baseline (H0-H2)
    anti_leakage/      # Tests de validación
    ablations/         # Estudios de ablación
 src/                    # Código Python
    bq/                # Cliente BigQuery + ejecutores
    eval/              # Evaluación (quantiles, policy)
    reports/           # Generadores de informes
    bundle/            # Empaquetado GCS
    config/            # Configuración entorno
 scripts/               # Scripts ejecución
 docs/                  # Documentación
 reports/               # Informes generados
 notebooks/             # Jupyter notebooks
 data/                  # Datos locales (git-ignored)
```

## Ejecución

### Local
```bash
# Pipeline completo
python -m src.entrypoint run

# Solo B3 fix
python src/bq/run_optionB_b3_fix.py --project-id thequantitativeledger --dataset-id cruzber_models_eu
```

### Cloud Shell
```bash
# Ver docs/CLOUD_SHELL_SETUP.md
```

### Docker
```bash
docker build -t oos-h4-pipeline .
docker run --rm -v ~/.config/gcloud:/root/.config/gcloud:ro oos-h4-pipeline
```

## Gates

- **B3**: Conditional coverage [8%, 12%]  
- **B4**: Policy fill-rate vs naive  
- **B5**: Submission readiness (ablations, baselines, anti-leakage)

## Resultados

Ver eports/ para informes completos y 
otebooks/PAPER_READINESS_CRUZBER_H4.ipynb para análisis final.
