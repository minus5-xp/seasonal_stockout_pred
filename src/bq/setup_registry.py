#!/usr/bin/env python3
"""
Setup experiment registry in BigQuery
Ejecuta los pasos necesarios para crear el registry completo
"""

from google.cloud import bigquery
import sys

def main():
    project_id = "thequantitativeledger"
    location = "EU"
    
    client = bigquery.Client(project=project_id, location=location)
    
    print(f"🔧 Configurando experiment registry en {project_id}...")
    
    # Paso 1: Crear dataset
    print("\n[1/3] Creando dataset experiment_registry...")
    dataset_id = f"{project_id}.experiment_registry"
    dataset = bigquery.Dataset(dataset_id)
    dataset.location = location
    dataset.description = "Experiment tracking and model lineage for CRUZBER OOS forecasting"
    
    try:
        dataset = client.create_dataset(dataset, exists_ok=True)
        print(f"✅ Dataset {dataset_id} creado/verificado")
    except Exception as e:
        print(f"❌ Error creando dataset: {e}")
        sys.exit(1)
    
    # Paso 2: Crear tabla runs
    print("\n[2/3] Creando tabla experiment_registry.runs...")
    
    schema = [
        bigquery.SchemaField("run_id", "STRING", mode="REQUIRED"),
        bigquery.SchemaField("run_timestamp", "TIMESTAMP", mode="REQUIRED"),
        bigquery.SchemaField("run_name", "STRING"),
        bigquery.SchemaField("project_id", "STRING", mode="REQUIRED"),
        bigquery.SchemaField("dataset_id", "STRING", mode="REQUIRED"),
        bigquery.SchemaField("location", "STRING", mode="REQUIRED"),
        bigquery.SchemaField("model_name", "STRING"),
        bigquery.SchemaField("label_version", "STRING"),
        bigquery.SchemaField("horizon", "INT64"),
        bigquery.SchemaField("feature_view", "STRING"),
        bigquery.SchemaField("target_column", "STRING"),
        bigquery.SchemaField("split_train_start", "DATE"),
        bigquery.SchemaField("split_train_end", "DATE"),
        bigquery.SchemaField("split_calib_start", "DATE"),
        bigquery.SchemaField("split_calib_end", "DATE"),
        bigquery.SchemaField("split_val_start", "DATE"),
        bigquery.SchemaField("split_val_end", "DATE"),
        bigquery.SchemaField("code_hash", "STRING"),
        bigquery.SchemaField("data_hash", "STRING"),
        bigquery.SchemaField("config_hash", "STRING"),
        bigquery.SchemaField("auc_val", "FLOAT64"),
        bigquery.SchemaField("precision_at_100", "FLOAT64"),
        bigquery.SchemaField("lift_at_100", "FLOAT64"),
        bigquery.SchemaField("brier_score_calibrated", "FLOAT64"),
        bigquery.SchemaField("prevalence_val", "FLOAT64"),
        bigquery.SchemaField("model_type", "STRING"),
        bigquery.SchemaField("calibration_method", "STRING"),
        bigquery.SchemaField("notes", "STRING"),
        bigquery.SchemaField("tags", "STRING", mode="REPEATED"),
        bigquery.SchemaField("author", "STRING"),
        bigquery.SchemaField("created_at", "TIMESTAMP", mode="REQUIRED"),
        bigquery.SchemaField("updated_at", "TIMESTAMP"),
    ]
    
    table_id = f"{dataset_id}.runs"
    table = bigquery.Table(table_id, schema=schema)
    table.time_partitioning = bigquery.TimePartitioning(
        type_=bigquery.TimePartitioningType.DAY,
        field="run_timestamp",
    )
    table.clustering_fields = ["project_id", "model_name", "run_name"]
    
    try:
        table = client.create_table(table, exists_ok=True)
        print(f"✅ Tabla {table_id} creada/verificada")
    except Exception as e:
        print(f"❌ Error creando tabla: {e}")
        sys.exit(1)
    
    print("\n[3/3] Verificando estructura...")
    table = client.get_table(table_id)
    print(f"✅ Tabla correcta: {len(table.schema)} columnas, particionada por {table.time_partitioning.field}")
    
    print(f"\n🎉 Experiment registry configurado correctamente en {project_id}")
    print(f"   Dataset: experiment_registry")
    print(f"   Tabla: runs")
    print(f"   Location: {location}")
    
    return 0

if __name__ == "__main__":
    sys.exit(main())
