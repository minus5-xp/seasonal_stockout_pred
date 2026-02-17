# B0 — Definiciones Canónicas y Protocolo Temporal

## Alcance bloqueado
- Universo: `sku_id x week_start_date x segment_keys`.
- Censura: `proxy-OOS/risk-of-censorship` basada en ventas (no stock real observado).
- Demand-active: `y_sales > 0 OR roll13_mean >= 1`.
- Splits: `TRAIN/CALIB/VAL` tomados de `weekly_features_h4`.
- Rolling windows: folds anclados cada 4 semanas (`optionb_rolling_folds_h4`).

## Tablas canónicas
- `{dataset_ref}.b0_protocol_h4`
- `{dataset_ref}.optionb_rolling_folds_h4`
- `{dataset_ref}.optionb_spine_h4`
- `{dataset_ref}.pred_oos_h4_canonical`

## Reglas de claims
- Prohibido afirmar “true OOS”: se reporta como probabilidad proxy de censura.
- “Demanda latente” se reporta como `estimated unconstrained demand` con incertidumbre.
- Si B3/B4 no pasan gates, el veredicto final será **NO submit-ready aún**.

## Checklist B0 (gate)
- [ ] Definiciones inmutables versionadas.
- [ ] Splits temporales y folds rolling reproducibles.
- [ ] Semántica de claims validada en reportes posteriores.
