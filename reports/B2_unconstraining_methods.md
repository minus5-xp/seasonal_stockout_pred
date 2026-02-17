# B2 — Unconstraining de Demanda Latente (Sales-only)

## Métodos implementados
- **U1 (Kourentzes-inspired):** uplift robusto con amplitud local y `p_oos`.
- **U2 (EM-like):** esquema E/M aproximado por reweighting probabilístico con gap esperado.
- **U3 (naive):** `demand_uc_naive = sales`.

## Ecuaciones operativas
- U1: `d_uc = sales + lambda(p_oos) * local_scale`, con truncado inferior en `sales`.
- U2: `E[D|y,p_oos] ~= y + p_oos * E[gap]`, seguido de suavizado local (segunda iteración).

## Supuestos
- Datos de ventas censurados por quiebre de stock potencial (no observación de inventario real).
- `p_oos` representa riesgo probabilístico de censura, no evento causal confirmado.
- Estabilidad temporal razonable en ventanas cortas (rolling).

## Limitaciones
- No hay identificación fuerte de demanda real bajo OOS sin inventario observado.
- U1/U2 son aproximaciones reproducibles para BQ (no sustituyen un EM completo estructural).

## Referencias (sección/página en PDFs del repo)
- Kourentzes et al. (2017), *Unconstraining Methods...*: Abstract e Introducción (p.1), discusión de constrained sales y spiral-down (p.2).
- Trapero et al. (2024), *Demand forecasting under lost sales stock policies*: abstract con censura/lost sales (p.1), marco de métodos y política de stock (p.2–p.4).
- Huh & Rusmevichientong (2008), *DataLostSales-MOR*: formulación de inventario con demanda censurada/lost-sales (p.1–p.2).

## Artefacto principal
- Tabla: `{dataset_ref}.demand_unconstrained_h4`
- Columnas: `week_start`, `sku_id`, `segment_keys`, `sales`, `p_oos`, `demand_uc_u1`, `demand_uc_u2`, `demand_uc_naive`, `flags`.
