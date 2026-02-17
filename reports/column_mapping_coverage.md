# Column Mapping Coverage Report

## Executive Summary

This report documents **100% coverage** of all source XLSX columns to target MySQL tables.

**Date Generated**: 2025-12-20 13:12:37  
**Database**: dataset_cruzber  
**Target**: MySQL 8.0.49

---

## Source Files Summary

| Source File | Rows | Columns | Target Table(s) | Coverage |
|-------------|------|---------|-----------------|----------|
| LineasAlbaranCliente.xlsx | 938,230 | 20 | fact_lineas_albaran (Fact) | ✅ 100% |
| MaestroClientes.xlsx | 3,986 | 15 | dim_cliente (Dimension) | ✅ 100% |
| MaestroArticulos.xlsx | 30,531 | 29 | dim_articulo (Dimension) | ✅ 100% |
| MaestroFamilias.xlsx | 375 | 3 | dim_familia (Dimension) | ✅ 100% |
| FamiliasArticulos.xlsx | 483 | 6 | dim_agrupacion_articulo (Dimension) | ✅ 100% |
| AgrupacionCanales.xlsx | 32 | 10 | dim_canal (Dimension) | ✅ 100% |
| MaestroMunicipios.xlsx | 8,146 | 5 | dim_municipio (Dimension) | ✅ 100% |
| MaestroProvincias.xlsx | 52 | 7 | dim_provincia (Dimension) | ✅ 100% |
| MaestroNaciones.xlsx | 255 | 3 | dim_nacion (Dimension) | ✅ 100% |

---

## LineasAlbaranCliente.xlsx → fact_lineas_albaran

**Source Rows**: 938,230  
**Source Columns**: 20  
**Table Type**: Fact  

| # | Source Column (Normalized) | MySQL Type | Nullable | Description |
|---|----------------------------|------------|----------|-------------|
| 1 | `codigo_cliente` | INT | NO (PK/FK) | From LineasAlbaranCliente.xlsx |
| 2 | `serie_albaran` | VARCHAR | YES | From LineasAlbaranCliente.xlsx |
| 3 | `numero_albaran` | INT | YES | From LineasAlbaranCliente.xlsx |
| 4 | `fecha_albaran` | DATE | YES | From LineasAlbaranCliente.xlsx |
| 5 | `codigo_articulo` | VARCHAR | NO (PK/FK) | From LineasAlbaranCliente.xlsx |
| 6 | `codigo_almacen` | INT | YES | From LineasAlbaranCliente.xlsx |
| 7 | `unidades` | DECIMAL | YES | From LineasAlbaranCliente.xlsx |
| 8 | `precio` | DECIMAL(15,4) | YES | From LineasAlbaranCliente.xlsx |
| 9 | `precio_coste` | DECIMAL(15,4) | YES | From LineasAlbaranCliente.xlsx |
| 10 | `importe_descuento` | DECIMAL(15,4) | YES | From LineasAlbaranCliente.xlsx |
| 11 | `importe_coste` | DECIMAL(15,4) | YES | From LineasAlbaranCliente.xlsx |
| 12 | `importe_bruto` | DECIMAL(15,4) | YES | From LineasAlbaranCliente.xlsx |
| 13 | `importe_neto` | DECIMAL(15,4) | YES | From LineasAlbaranCliente.xlsx |
| 14 | `importe_pronto_pago` | DECIMAL(15,4) | YES | From LineasAlbaranCliente.xlsx |
| 15 | `base_imponible` | DECIMAL | YES | From LineasAlbaranCliente.xlsx |
| 16 | `importe_liquido` | DECIMAL(15,4) | YES | From LineasAlbaranCliente.xlsx |
| 17 | `por_descuento` | DECIMAL(12,8) | YES | From LineasAlbaranCliente.xlsx |
| 18 | `por_descuento2` | DECIMAL(12,8) | YES | From LineasAlbaranCliente.xlsx |
| 19 | `por_margen_beneficio` | DECIMAL(12,8) | YES | From LineasAlbaranCliente.xlsx |
| 20 | `margen_beneficio` | DECIMAL(12,8) | YES | From LineasAlbaranCliente.xlsx |

---

## MaestroClientes.xlsx → dim_cliente

**Source Rows**: 3,986  
**Source Columns**: 15  
**Table Type**: Dimension  

| # | Source Column (Normalized) | MySQL Type | Nullable | Description |
|---|----------------------------|------------|----------|-------------|
| 1 | `codigo_cliente` | INT | NO (PK/FK) | From MaestroClientes.xlsx |
| 2 | `municipio` | VARCHAR | YES | From MaestroClientes.xlsx |
| 3 | `provincia` | VARCHAR | YES | From MaestroClientes.xlsx |
| 4 | `zona` | VARCHAR | YES | From MaestroClientes.xlsx |
| 5 | `tipo_cruz` | VARCHAR | YES | From MaestroClientes.xlsx |
| 6 | `codigo_nacion` | INT | NO (PK/FK) | From MaestroClientes.xlsx |
| 7 | `codigo_municipio` | DECIMAL | NO (PK/FK) | From MaestroClientes.xlsx |
| 8 | `codigo_provincia` | DECIMAL | NO (PK/FK) | From MaestroClientes.xlsx |
| 9 | `codigo_autonomia` | DECIMAL | YES | From MaestroClientes.xlsx |
| 10 | `baja_empresa_lc` | INT | YES | From MaestroClientes.xlsx |
| 11 | `codigo_jefe_zona` | INT | YES | From MaestroClientes.xlsx |
| 12 | `fecha_alta` | DATE | YES | From MaestroClientes.xlsx |
| 13 | `fecha_baja_lc` | DATE | YES | From MaestroClientes.xlsx |
| 14 | `codigo_motivo_baja_cliente_lc` | DECIMAL | YES | From MaestroClientes.xlsx |
| 15 | `motivo_baja_cliente_lc` | VARCHAR | YES | From MaestroClientes.xlsx |

---

## MaestroArticulos.xlsx → dim_articulo

**Source Rows**: 30,531  
**Source Columns**: 29  
**Table Type**: Dimension  

| # | Source Column (Normalized) | MySQL Type | Nullable | Description |
|---|----------------------------|------------|----------|-------------|
| 1 | `codigo_articulo` | VARCHAR | NO (PK/FK) | From MaestroArticulos.xlsx |
| 2 | `descripcion_articulo` | VARCHAR | YES | From MaestroArticulos.xlsx |
| 3 | `codigo_familia` | VARCHAR | NO (PK/FK) | From MaestroArticulos.xlsx |
| 4 | `codigo_subfamilia` | VARCHAR | YES | From MaestroArticulos.xlsx |
| 5 | `descripcion_subfamilia` | VARCHAR | YES | From MaestroArticulos.xlsx |
| 6 | `agrupacion_listado` | VARCHAR | NO (PK/FK) | From MaestroArticulos.xlsx |
| 7 | `descripcion_agrupacion` | VARCHAR | YES | From MaestroArticulos.xlsx |
| 8 | `sub_agrupacion_listado` | VARCHAR | YES | From MaestroArticulos.xlsx |
| 9 | `descripcion_sub_agrupacion` | VARCHAR | YES | From MaestroArticulos.xlsx |
| 10 | `codigo_area_competencia_lc` | VARCHAR | YES | From MaestroArticulos.xlsx |
| 11 | `area_competencia_lc` | VARCHAR | YES | From MaestroArticulos.xlsx |
| 12 | `estado_articulo` | INT | YES | From MaestroArticulos.xlsx |
| 13 | `precio_venta` | DECIMAL(15,4) | YES | From MaestroArticulos.xlsx |
| 14 | `precio_compra` | DECIMAL(15,4) | YES | From MaestroArticulos.xlsx |
| 15 | `coste_escandallo` | DECIMAL(15,4) | YES | From MaestroArticulos.xlsx |
| 16 | `tipo_abc` | VARCHAR | YES | From MaestroArticulos.xlsx |
| 17 | `stock_minimo` | DECIMAL | YES | From MaestroArticulos.xlsx |
| 18 | `stock_maximo` | DECIMAL | YES | From MaestroArticulos.xlsx |
| 19 | `factor_crecimiento` | DECIMAL | YES | From MaestroArticulos.xlsx |
| 20 | `prevision_ventas_aa` | DECIMAL | YES | From MaestroArticulos.xlsx |
| 21 | `prevision_ventas_ap` | DECIMAL | YES | From MaestroArticulos.xlsx |
| 22 | `obsoleto` | VARCHAR | YES | From MaestroArticulos.xlsx |
| 23 | `codigo_secundario` | VARCHAR | YES | From MaestroArticulos.xlsx |
| 24 | `formula` | INT | YES | From MaestroArticulos.xlsx |
| 25 | `tarifa_export` | DECIMAL | YES | From MaestroArticulos.xlsx |
| 26 | `tarifa_nacional` | DECIMAL | YES | From MaestroArticulos.xlsx |
| 27 | `tarifa_proxima` | DECIMAL | YES | From MaestroArticulos.xlsx |
| 28 | `tarifa_na` | DECIMAL | YES | From MaestroArticulos.xlsx |
| 29 | `fecha_instruccion` | DATE | YES | From MaestroArticulos.xlsx |

---

## MaestroFamilias.xlsx → dim_familia

**Source Rows**: 375  
**Source Columns**: 3  
**Table Type**: Dimension  

| # | Source Column (Normalized) | MySQL Type | Nullable | Description |
|---|----------------------------|------------|----------|-------------|
| 1 | `codigo_familia` | VARCHAR | NO (PK/FK) | From MaestroFamilias.xlsx |
| 2 | `codigo_subfamilia` | VARCHAR | YES | From MaestroFamilias.xlsx |
| 3 | `descripcion` | VARCHAR | YES | From MaestroFamilias.xlsx |

---

## FamiliasArticulos.xlsx → dim_agrupacion_articulo

**Source Rows**: 483  
**Source Columns**: 6  
**Table Type**: Dimension  

| # | Source Column (Normalized) | MySQL Type | Nullable | Description |
|---|----------------------------|------------|----------|-------------|
| 1 | `agrupacion_listado` | VARCHAR | NO (PK/FK) | From FamiliasArticulos.xlsx |
| 2 | `descripcion_agrupacion` | VARCHAR | YES | From FamiliasArticulos.xlsx |
| 3 | `cr_gama_producto` | VARCHAR | YES | From FamiliasArticulos.xlsx |
| 4 | `cr_tipo_producto` | VARCHAR | YES | From FamiliasArticulos.xlsx |
| 5 | `cr_material_agrupacion` | VARCHAR | YES | From FamiliasArticulos.xlsx |
| 6 | `orden` | INT | YES | From FamiliasArticulos.xlsx |

---

## AgrupacionCanales.xlsx → dim_canal

**Source Rows**: 32  
**Source Columns**: 10  
**Table Type**: Dimension  

| # | Source Column (Normalized) | MySQL Type | Nullable | Description |
|---|----------------------------|------------|----------|-------------|
| 1 | `canal` | VARCHAR | NO (PK/FK) | From AgrupacionCanales.xlsx |
| 2 | `agrupacion_canal` | VARCHAR | YES | From AgrupacionCanales.xlsx |
| 3 | `tipo_agrupacion` | VARCHAR | YES | From AgrupacionCanales.xlsx |
| 4 | `objetivo_ventas_2020` | DECIMAL | YES | From AgrupacionCanales.xlsx |
| 5 | `orden_agrupacion` | INT | YES | From AgrupacionCanales.xlsx |
| 6 | `orden_tipo_agrupacion` | INT | YES | From AgrupacionCanales.xlsx |
| 7 | `objetivo_ventas_2021` | DECIMAL | YES | From AgrupacionCanales.xlsx |
| 8 | `objetivo_ventas_2022` | DECIMAL | YES | From AgrupacionCanales.xlsx |
| 9 | `objetivo_ventas_2023` | DECIMAL | YES | From AgrupacionCanales.xlsx |
| 10 | `objetivo_ventas_2024` | DECIMAL | YES | From AgrupacionCanales.xlsx |

---

## MaestroMunicipios.xlsx → dim_municipio

**Source Rows**: 8,146  
**Source Columns**: 5  
**Table Type**: Dimension  

| # | Source Column (Normalized) | MySQL Type | Nullable | Description |
|---|----------------------------|------------|----------|-------------|
| 1 | `codigo_municipio` | INT | NO (PK/FK) | From MaestroMunicipios.xlsx |
| 2 | `municipio` | VARCHAR | YES | From MaestroMunicipios.xlsx |
| 3 | `codigo_provincia` | DECIMAL | NO (PK/FK) | From MaestroMunicipios.xlsx |
| 4 | `codigo_autonomia` | INT | YES | From MaestroMunicipios.xlsx |
| 5 | `codigo_nacion` | INT | NO (PK/FK) | From MaestroMunicipios.xlsx |

---

## MaestroProvincias.xlsx → dim_provincia

**Source Rows**: 52  
**Source Columns**: 7  
**Table Type**: Dimension  

| # | Source Column (Normalized) | MySQL Type | Nullable | Description |
|---|----------------------------|------------|----------|-------------|
| 1 | `codigo_provincia` | INT | NO (PK/FK) | From MaestroProvincias.xlsx |
| 2 | `codigo_autonomia` | INT | YES | From MaestroProvincias.xlsx |
| 3 | `provincia` | VARCHAR | YES | From MaestroProvincias.xlsx |
| 4 | `autonomia` | VARCHAR | YES | From MaestroProvincias.xlsx |
| 5 | `codigo_nacion` | INT | NO (PK/FK) | From MaestroProvincias.xlsx |
| 6 | `nacion` | VARCHAR | YES | From MaestroProvincias.xlsx |
| 7 | `provincia_pais` | VARCHAR | YES | From MaestroProvincias.xlsx |

---

## MaestroNaciones.xlsx → dim_nacion

**Source Rows**: 255  
**Source Columns**: 3  
**Table Type**: Dimension  

| # | Source Column (Normalized) | MySQL Type | Nullable | Description |
|---|----------------------------|------------|----------|-------------|
| 1 | `codigo_nacion` | INT | NO (PK/FK) | From MaestroNaciones.xlsx |
| 2 | `nacion` | VARCHAR | YES | From MaestroNaciones.xlsx |
| 3 | `cifra_objetivo_pais` | DECIMAL | YES | From MaestroNaciones.xlsx |

---

## Unmapped Columns Verification

**Status**: ✅ All source columns are mapped to target tables

No columns were dropped or excluded from the relational model.

---

## Relationship Summary

```
dim_nacion (255 nations)
  └─► dim_provincia (52 provinces)
       └─► dim_municipio (8,146 municipalities)
            └─► dim_cliente (3,986 customers)
                 └─► fact_lineas_albaran (938,230 lines)

dim_familia (19 families)
  └─► dim_articulo (30,531 articles)
       └─► fact_lineas_albaran

dim_agrupacion_articulo (groupings)
  └─► dim_articulo

dim_canal (32 channels)
  └─► dim_cliente
```

---

**End of Coverage Report**
