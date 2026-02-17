# Cruzber Parser Quality Report

**Generated:** 2025-12-20 10:46:31

---

## 1. Table Inventory

| Table | Rows | Columns |
|-------|-----:|--------:|
| MaestroFamilias | 19 | 2 |
| MaestroMunicipios | 8,146 | 3 |
| FamiliasArticulos | 483 | 2 |
| MaestroProvincias | 52 | 3 |
| MaestroArticulos | 30,531 | 4 |
| LineasAlbaranCliente | 938,230 | 20 |
| MaestroNaciones | 255 | 2 |
| AgrupacionCanalesVenta | 32 | 2 |
| MaestroClientes | 3,986 | 3 |

---

## 2. Data Types

### MaestroFamilias

| Column | Type | Null Count | Null % |
|--------|------|------------|--------|
| CodigoFamilia | object | 0 | 0.00% |
| DescripcionFamilia | object | 0 | 0.00% |

### MaestroMunicipios

| Column | Type | Null Count | Null % |
|--------|------|------------|--------|
| CodigoMunicipio | object | 0 | 0.00% |
| DescripcionMunicipio | object | 0 | 0.00% |
| CodigoProvincia | object | 1 | 0.01% |

### FamiliasArticulos

| Column | Type | Null Count | Null % |
|--------|------|------------|--------|
| CodigoArticulo | object | 0 | 0.00% |
| CodigoFamilia | object | 0 | 0.00% |

### MaestroProvincias

| Column | Type | Null Count | Null % |
|--------|------|------------|--------|
| CodigoProvincia | object | 0 | 0.00% |
| DescripcionProvincia | object | 0 | 0.00% |
| CodigoNacion | object | 0 | 0.00% |

### MaestroArticulos

| Column | Type | Null Count | Null % |
|--------|------|------------|--------|
| CodigoArticulo | object | 0 | 0.00% |
| DescripcionArticulo | object | 10 | 0.03% |
| PrecioVenta | float64 | 0 | 0.00% |
| CosteEstandar | float64 | 0 | 0.00% |

### LineasAlbaranCliente

| Column | Type | Null Count | Null % |
|--------|------|------------|--------|
| NumeroAlbaran | int64 | 0 | 0.00% |
| FechaAlbaran | datetime64[ns] | 938,230 | 100.00% |
| CodigoCliente | int64 | 0 | 0.00% |
| CodigoArticulo | object | 0 | 0.00% |
| Unidades | float64 | 0 | 0.00% |
| ImporteBruto | float64 | 0 | 0.00% |
| ImporteNeto | float64 | 0 | 0.00% |
| ImporteLiquido | float64 | 0 | 0.00% |
| BaseImponible | float64 | 0 | 0.00% |
| ImporteCoste | float64 | 0 | 0.00% |
| MargenBeneficio | float64 | 0 | 0.00% |
| PorMargenBeneficio | float64 | 0 | 0.00% |

### MaestroNaciones

| Column | Type | Null Count | Null % |
|--------|------|------------|--------|
| CodigoNacion | object | 0 | 0.00% |
| DescripcionNacion | object | 0 | 0.00% |

### AgrupacionCanalesVenta

| Column | Type | Null Count | Null % |
|--------|------|------------|--------|
| CanalVenta | object | 0 | 0.00% |
| AgrupacionCanal | object | 0 | 0.00% |

### MaestroClientes

| Column | Type | Null Count | Null % |
|--------|------|------------|--------|
| CodigoCliente | int64 | 0 | 0.00% |
| CodigoMunicipio | float64 | 767 | 19.24% |
| FechaAlta | datetime64[ns] | 3,986 | 100.00% |

---

## 3. Primary Key Validations

| Table | PK Columns | Total Rows | Unique Keys | Duplicates | Valid |
|-------|------------|------------|-------------|------------|-------|
| MaestroFamilias | CodigoFamilia | 19 | 19 | 0 | ✅ |
| MaestroMunicipios | CodigoMunicipio | 8,146 | 8,146 | 0 | ✅ |
| MaestroProvincias | CodigoProvincia | 52 | 52 | 0 | ✅ |
| MaestroArticulos | CodigoArticulo | 30,531 | 30,531 | 0 | ✅ |
| MaestroNaciones | CodigoNacion | 255 | 255 | 0 | ✅ |
| AgrupacionCanalesVenta | CanalVenta | 32 | 32 | 0 | ✅ |
| MaestroClientes | CodigoCliente | 3,986 | 3,986 | 0 | ✅ |
| LineasAlbaranCliente | NumeroAlbaran, NumeroLinea | 938,230 | 0 | 0 | ✅ |

---

## 4. Foreign Key Validations

| Child Table | Parent Table | FK Column | Orphans | Orphan % | Valid |
|-------------|--------------|-----------|---------|----------|-------|
| MaestroMunicipios | MaestroProvincias | CodigoProvincia | 1,551 | 19.04% | ❌ |
| MaestroProvincias | MaestroNaciones | CodigoNacion | 0 | 0.00% | ✅ |
| FamiliasArticulos | MaestroArticulos | CodigoArticulo | 482 | 99.79% | ❌ |
| FamiliasArticulos | MaestroFamilias | CodigoFamilia | 483 | 100.00% | ❌ |
| MaestroClientes | MaestroMunicipios | CodigoMunicipio | 3,219 | 80.76% | ❌ |
| MaestroClientes | AgrupacionCanalesVenta | CanalVenta | 0 | 0.00% | ❌ |
| LineasAlbaranCliente | MaestroClientes | CodigoCliente | 0 | 0.00% | ✅ |
| LineasAlbaranCliente | MaestroArticulos | CodigoArticulo | 0 | 0.00% | ✅ |

**MaestroMunicipios.CodigoProvincia - Orphan Values (top 10):**

- `09`: 372 occurrences
- `08`: 311 occurrences
- `05`: 248 occurrences
- `06`: 165 occurrences
- `03`: 141 occurrences
- `04`: 103 occurrences
- `02`: 87 occurrences
- `07`: 68 occurrences
- `01`: 53 occurrences
- `55`: 2 occurrences

**FamiliasArticulos.CodigoArticulo - Orphan Values (top 10):**

- `000`: 1 occurrences
- `921`: 1 occurrences
- `813M`: 1 occurrences
- `018R`: 1 occurrences
- `018M`: 1 occurrences
- `012R`: 1 occurrences
- `001R`: 1 occurrences
- `T976`: 1 occurrences
- `T975SS`: 1 occurrences
- `T975`: 1 occurrences

**FamiliasArticulos.CodigoFamilia - Orphan Values (top 10):**

- `Mont. elem. de tubos y barras: barras`: 4 occurrences
- `FIRRAK Mont. elem. de tubos y barras: barras`: 4 occurrences
- `CRUZ Alu Side - Vehiculos comerciales`: 3 occurrences
- `CRUZ soportes para Safari`: 2 occurrences
- `Thule Technical Backpack`: 2 occurrences
- `Thule Child carriers`: 2 occurrences
- `FIRRAK Barras transformadas`: 2 occurrences
- `Barras transformadas`: 2 occurrences
- `THULE Enganches`: 2 occurrences
- `THULE Enganches especiales y Remolques`: 2 occurrences

**MaestroClientes.CodigoMunicipio - Orphan Values (top 10):**

- `28079.0`: 152 occurrences
- `46250.0`: 100 occurrences
- `8019.0`: 78 occurrences
- `29067.0`: 49 occurrences
- `41091.0`: 45 occurrences
- `14021.0`: 41 occurrences
- `50297.0`: 35 occurrences
- `47186.0`: 32 occurrences
- `7040.0`: 29 occurrences
- `18087.0`: 27 occurrences

---

## 5. Null Rates (Critical Columns)

### MaestroArticulos

| Column | Null % |
|--------|--------|
| CodigoArticulo | 0.00% |
| DescripcionArticulo | 0.03% |

### LineasAlbaranCliente

| Column | Null % |
|--------|--------|
| NumeroAlbaran | 0.00% |
| FechaAlbaran | 100.00% |
| CodigoCliente | 0.00% |
| CodigoArticulo | 0.00% |
| BaseImponible | 0.00% |
| ImporteCoste | 0.00% |

### MaestroClientes

| Column | Null % |
|--------|--------|
| CodigoCliente | 0.00% |

---

## 6. Margin Validation (Authoritative Logic)

**Financial Rule:**
- `MargenBeneficio = BaseImponible - ImporteCoste`
- `PorMargenBeneficio = 100 × (MargenBeneficio / BaseImponible)`

**BaseImponible is the SOURCE OF TRUTH** (net revenue without VAT).

### Summary

| Metric | Value |
|--------|-------|
| Total Rows | 938,230 |
| Evaluable Rows | 927,446 |
| Not Evaluable | 10,379 (1.11%) |

### MargenBeneficio Validation

| Status | Count | % of Evaluable |
|--------|-------|----------------|
| ✅ OK | 927,446 | 100.00% |
| ❌ FAIL | 0 | 0.00% |

**Delta Statistics:**

- Mean: -0.0000
- Std Dev: 0.0000
- Min: -0.0000
- Max: 0.0000

### PorMargenBeneficio Validation

| Status | Count | % of Evaluable |
|--------|-------|----------------|
| ✅ OK | 927,446 | 100.00% |
| ❌ FAIL | 0 | 0.00% |

**Delta Statistics:**

- Mean: -0.0000%
- Std Dev: 0.0000%
- Min: -0.0000%
- Max: 0.0000%

### Combined Validation (Both OK)

**927,446 rows** (100.00%) passed both validations.

---

## Conclusion

All datasets have been parsed, validated, and exported.
Review validation results above for data quality issues.

**Authoritative Margin Logic:**
- All margin calculations are based on **BaseImponible** (net revenue without VAT)
- Discount columns are NOT used for margin validation
- BaseImponible already reflects all discounts, pronto pago, and commercial adjustments

---

*Report generated on 2025-12-20 10:46:31*
