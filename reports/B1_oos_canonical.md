# B1 — Modelo canónico de censura (proxy-OOS)

## Decisión canónica
- Modelo fuente: `score_oos_h4_calibrated` (Platt calibrado) con anti-leakage PASS en reportes existentes.
- Salida operacional: `{dataset_ref}.pred_oos_h4_canonical`.

## Notas
- `p_oos` se usa como probabilidad de censura para unconstraining.
- No se interpreta como stockout real confirmado.
