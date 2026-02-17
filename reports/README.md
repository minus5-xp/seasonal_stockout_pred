# 📚 Documentación del Proyecto CRUZBER Database

Este directorio contiene toda la documentación técnica y de negocio del proyecto de migración de datos CRUZBER a MySQL 8.0.49.

**Fecha**: 2025-12-20  
**Estado**: ✅ **PRODUCTION READY**  
**Database**: dataset_cruzber (938,230 líneas de albarán)

---

## 📋 Índice de Documentos

### 🎯 Documentos Principales

| Documento | Tipo | Descripción | Estado |
|-----------|------|-------------|--------|
| [PROJECT_STATUS.md](PROJECT_STATUS.md) | **⭐ EJECUTIVO** | Informe de estado final del proyecto | ✅ OFICIAL |
| [pipeline_dataset_cruzber.md](pipeline_dataset_cruzber.md) | Técnico | Pipeline completo ETL desde XLSX a MySQL | ✅ Actualizado |
| [LOGICA_FINANCIERA_FACT_LINEAS_ALBARAN.md](LOGICA_FINANCIERA_FACT_LINEAS_ALBARAN.md) | **⭐ NEGOCIO** | Lógica autoritativa de cálculo de márgenes | ✅ OFICIAL |

### 📊 Documentación Técnica

| Documento | Descripción | Última Actualización |
|-----------|-------------|----------------------|
| [views_dataset_cruzber.md](views_dataset_cruzber.md) | Definición de 12 vistas analíticas con SQL | 2025-12-20 |
| [column_mapping_coverage.md](column_mapping_coverage.md) | Mapeo completo XLSX → MySQL (100% cobertura) | 2025-12-20 |
| [parser_quality_report.md](parser_quality_report.md) | Calidad de parsing: fechas, decimales, tipos | 2025-12-20 |
| [er_diagram.mmd](er_diagram.mmd) | Diagrama Entidad-Relación (Mermaid) | 2025-12-20 |

### 📈 Reportes de Estado (Históricos)

| Documento | Descripción | Tipo |
|-----------|-------------|------|
| [summary.md](summary.md) | Resumen de descarga Eurostat (no CRUZBER) | Histórico |
| [downloader_debug.md](downloader_debug.md) | Debug de descargador Eurostat | Histórico |

### 📁 Archivos de Datos (CSV)

| Archivo | Descripción | Filas |
|---------|-------------|-------|
| [code_resolution.csv](code_resolution.csv) | Resolución de códigos | Variable |
| [download_status.csv](download_status.csv) | Estado de descargas Eurostat | Variable |
| [fixed_download_status.csv](fixed_download_status.csv) | Estado corregido | Variable |
| [all_core_plus_catalog_tech_selection.csv](all_core_plus_catalog_tech_selection.csv) | Selección catálogo técnico | Variable |
| [all_core_plus_catalog_tech_status.csv](all_core_plus_catalog_tech_status.csv) | Estado catálogo técnico | Variable |
| [catalog_codes_without_files.csv](catalog_codes_without_files.csv) | Códigos sin archivos | Variable |
| [tech_top60_manifest.csv](tech_top60_manifest.csv) | Manifiesto top 60 | Variable |
| [tech_top60_selection.csv](tech_top60_selection.csv) | Selección top 60 | Variable |

---

## 🎓 Guía de Lectura Recomendada

### Para Stakeholders de Negocio

1. **[PROJECT_STATUS.md](PROJECT_STATUS.md)** - Visión general del proyecto
2. **[LOGICA_FINANCIERA_FACT_LINEAS_ALBARAN.md](LOGICA_FINANCIERA_FACT_LINEAS_ALBARAN.md)** - ¿Por qué BaseImponible es la fuente de verdad?
3. **[views_dataset_cruzber.md](views_dataset_cruzber.md)** - Qué análisis puedes hacer con la base de datos

### Para Analistas de Datos

1. **[views_dataset_cruzber.md](views_dataset_cruzber.md)** - Vistas SQL listas para usar
2. **[LOGICA_FINANCIERA_FACT_LINEAS_ALBARAN.md](LOGICA_FINANCIERA_FACT_LINEAS_ALBARAN.md)** - Fórmulas de cálculo oficiales
3. **[column_mapping_coverage.md](column_mapping_coverage.md)** - Qué columnas hay disponibles

### Para Data Engineers

1. **[pipeline_dataset_cruzber.md](pipeline_dataset_cruzber.md)** - Pipeline ETL completo
2. **[parser_quality_report.md](parser_quality_report.md)** - Calidad de datos parseados
3. **[column_mapping_coverage.md](column_mapping_coverage.md)** - Mapeo fuente → destino

### Para Auditores

1. **[LOGICA_FINANCIERA_FACT_LINEAS_ALBARAN.md](LOGICA_FINANCIERA_FACT_LINEAS_ALBARAN.md)** - Lógica de cálculo oficial
2. **[PROJECT_STATUS.md](PROJECT_STATUS.md)** - Validaciones pasadas
3. **[pipeline_dataset_cruzber.md](pipeline_dataset_cruzber.md)** - Trazabilidad de transformaciones

---

## 🔍 Búsqueda Rápida

### ¿Buscas información sobre...?

- **Fechas parseadas**: Ver [parser_quality_report.md](parser_quality_report.md) + [PROJECT_STATUS.md](PROJECT_STATUS.md#solución-de-problemas-críticos)
- **Cálculo de márgenes**: Ver [LOGICA_FINANCIERA_FACT_LINEAS_ALBARAN.md](LOGICA_FINANCIERA_FACT_LINEAS_ALBARAN.md#fórmulas-de-cálculo-oficiales)
- **Estructura de tablas**: Ver [pipeline_dataset_cruzber.md](pipeline_dataset_cruzber.md#phase-4-relational-modeling)
- **Vistas analíticas**: Ver [views_dataset_cruzber.md](views_dataset_cruzber.md)
- **Cobertura de columnas**: Ver [column_mapping_coverage.md](column_mapping_coverage.md)
- **Importar a MySQL**: Ver [PROJECT_STATUS.md](PROJECT_STATUS.md#próximos-pasos)

---

## 📊 Métricas del Proyecto

### Datos Procesados

```
📦 FACT TABLE
  - fact_lineas_albaran: 938,230 líneas

📅 CALENDAR DIMENSION
  - dim_fecha: 2,095 días (2019-01-02 a 2024-09-26)

📚 DIMENSIONS
  - dim_nacion: 255
  - dim_provincia: 52
  - dim_municipio: 8,146
  - dim_cliente: 3,986
  - dim_familia: 375
  - dim_agrupacion_articulo: 483
  - dim_articulo: 30,531
  - dim_canal: 32

💾 TOTAL: 982,185 filas procesadas
```

### Calidad de Datos

- ✅ **100% cobertura de columnas** (todas las columnas XLSX importadas)
- ✅ **0 fechas NULL** (938,230 / 938,230 parseadas correctamente)
- ✅ **11 validaciones pasadas** (PKs únicos, FKs válidos, cardinalidad correcta)
- ✅ **163.11 MB SQL dump** generado y listo para importar

---

## 🚀 Inicio Rápido

### 1. Importar Base de Datos

```bash
mysql -u root -p < ../sql/dataset_cruzber_mysql8.sql
```

### 2. Crear Vistas Analíticas

Copiar y ejecutar las definiciones SQL desde [views_dataset_cruzber.md](views_dataset_cruzber.md).

### 3. Primer Query

```sql
USE dataset_cruzber;

-- Ventas totales por trimestre
SELECT 
    f.trimestre_nombre,
    SUM(fa.base_imponible) as ventas
FROM fact_lineas_albaran fa
JOIN dim_fecha f ON fa.fecha_albaran = f.fecha
GROUP BY f.trimestre, f.trimestre_nombre
ORDER BY f.trimestre;
```

---

## 📞 Soporte

Para preguntas sobre:

- **Lógica de negocio**: Ver [LOGICA_FINANCIERA_FACT_LINEAS_ALBARAN.md](LOGICA_FINANCIERA_FACT_LINEAS_ALBARAN.md)
- **Implementación técnica**: Ver [pipeline_dataset_cruzber.md](pipeline_dataset_cruzber.md)
- **Análisis de datos**: Ver [views_dataset_cruzber.md](views_dataset_cruzber.md)

---

## 📝 Historial de Cambios

| Fecha | Versión | Cambios |
|-------|---------|---------|
| 2025-12-20 | 1.0 | Documentación completa del proyecto finalizado |
| 2025-12-20 | 1.0 | Creado documento de lógica financiera autoritativa |
| 2025-12-20 | 1.0 | Actualizadas todas las métricas a 938,230 filas |
| 2025-12-20 | 1.0 | Documentada dim_fecha con cobertura 2019-2024 |

---

**Generado**: 2025-12-20  
**Versión**: 1.0  
**Estado**: ✅ **DOCUMENTACIÓN OFICIAL - PRODUCTION READY**
