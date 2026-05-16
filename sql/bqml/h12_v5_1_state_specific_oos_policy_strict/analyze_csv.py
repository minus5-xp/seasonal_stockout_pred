import pandas as pd

path = r"C:\Users\hugod\OneDrive - Hugo de Val Roig\Descargas\weekly_features_h12_SST_v5_1.csv"

df = pd.read_csv(path, nrows=5)
print("=== COLUMNAS ===")
for c in df.columns:
    print(f"  {c}")

print(f"\n=== SHAPE (muestra 5 filas) ===")
print(f"  Columnas: {len(df.columns)}")

print("\n=== PRIMERAS 3 FILAS (transpuesta) ===")
print(df.head(3).T.to_string())

# Info completa del fichero
df_full = pd.read_csv(path)
print(f"\n=== SHAPE COMPLETO ===")
print(f"  Filas: {len(df_full):,}")
print(f"  Columnas: {len(df_full.columns)}")

print("\n=== TIPOS ===")
print(df_full.dtypes.to_string())

print("\n=== NULOS ===")
nulls = df_full.isnull().sum()
nulls = nulls[nulls > 0]
print(nulls.to_string() if len(nulls) > 0 else "  Ninguno")

print("\n=== VALORES ÚNICOS (columnas clave) ===")
for col in ['eval_split_v3', 'season_group', 'sku_season_state', 'alert_source', 'combined_oos_alert']:
    if col in df_full.columns:
        print(f"  {col}: {df_full[col].value_counts().to_dict()}")
