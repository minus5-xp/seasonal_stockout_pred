# Justificación Motor OOS — Modelo Cruzber

**Proyecto:** CRUZBER — Capa de detección de roturas de stock (OOS)
**Modelo activo:** `h12_v5_1_state_specific_oos_policy_strict`
**Fecha:** 2026-05-16
**Destinatario:** Equipo de negocio / dirección operativa

---

## Por qué existe este motor

El motor OOS de Cruzber responde a una pregunta operativa concreta: **¿cuándo está un producto sin stock en estantería aunque las ventas simplemente muestren cero?**

En distribución y retail, un cero en ventas no siempre significa que no hay demanda. A veces significa que el producto no estaba disponible. Distinguir ambos casos es crítico para no reponer de más, no perder ventas evitables y no auditar referencias que no lo necesitan.

El motor analiza los históricos de punto de venta (POS), patrones de demanda y señales estadísticas para emitir **alertas accionables**: "esta referencia, en esta ubicación, en este horizonte, probablemente tiene una rotura de stock". Esas alertas pueden traducirse en auditorías, reposiciones o intervenciones comerciales.

---

## Qué se ha construido y qué resultados ofrece

Se han desarrollado y validado dos versiones del motor (v5.1 y v5.2) sobre una base de **859.664 registros** con horizon de predicción a 12 semanas. Los resultados del modelo activo son:

| Indicador | Valor | Interpretación de negocio |
|---|---|---|
| **Precisión** | 64,96% | Aproximadamente 2 de cada 3 alertas emitidas son roturas reales |
| **Cobertura (recall)** | 35,16% | El motor detecta alrededor de 1 de cada 3 roturas que ocurren |
| **Alertas generadas** | ~27.264 | Volumen accionable en el periodo de prueba |

Estos números deben leerse en contexto: **la demanda que analiza el motor es altamente intermitente**, con muchos productos que tienen periodos naturales de cero ventas sin que ello implique rotura. En ese entorno, una precisión del 65% y un sistema auditado son un resultado sólido.

---

## Por qué no se puede simplemente "subir la cobertura"

Una pregunta lógica de negocio es: ¿por qué no detectamos más roturas? La respuesta es técnica pero tiene implicaciones operativas muy directas.

La iteración v5.2 se diseñó específicamente para intentar aumentar la cobertura de forma segura. Se evaluaron **81 configuraciones distintas** del algoritmo bajo condiciones de validación estrictas. El resultado fue que **ninguna configuración adicional superó los controles de calidad sin degradar la fiabilidad del sistema**.

Esto no es un fallo del modelo, sino una señal importante: **el motor ha alcanzado la frontera de lo que puede hacer con la información disponible hoy**.

La causa está respaldada por la literatura académica especializada. Chuang (2018) demuestra que los ceros en ventas son señales ambiguas: pueden reflejar demanda real nula o rotura de stock no observada. Sin información adicional, el modelo no puede resolver esa ambigüedad de forma robusta. Forzar más detección convierte ceros estructurales en falsas alarmas, lo que encarece las auditorías y deteriora la confianza en el sistema.

---

## Qué limitaría el sistema y qué lo desbloquearía

### La limitación actual

El motor trabaja exclusivamente con **datos de ventas y señales derivadas**. No tiene acceso a:

- posición de inventario real
- nivel de stock en tienda o almacén
- datos de reposición o recepciones
- disponibilidad en estantería (on-shelf availability)
- resultados de auditorías físicas

Mersereau (2015) establece que las ventas observadas son una medida censurada de la demanda real: no se puede vender lo que no está. Trapero, Holgado de Frutos y Pedregal (2024) confirman que los modelos que no incorporan esa censura tienden a subestimar la demanda perdida. En términos de negocio: sin saber cuánto stock había, el modelo no puede saber con certeza si la venta no ocurrió porque no había demanda o porque no había producto.

### Lo que desbloquearía la siguiente mejora

Existen dos caminos para aumentar la cobertura del motor sin sacrificar fiabilidad:

**Camino 1 — Nuevos datos.** Incorporar al modelo información de inventario, reposiciones, órdenes de compra, recepciones en tienda o resultados de auditorías físicas. Rozas Andaur, Ruz y Goycoolea (2021) demuestran que con estas variables adicionales el recall puede alcanzar rangos del 50–65% manteniendo precisión equivalente. Este es el camino más directo si los datos están disponibles o son obtenibles a coste razonable.

**Camino 2 — Nueva arquitectura de modelo (HMM).** En teoría, sería posible implementar un modelo de estados latentes —conocido como Hidden Markov Model o HMM— que trate el OOS como un estado no observable e infiera probabilísticamente cuándo se produce a partir de la secuencia de ventas. Montoya y González (2019) reportan con esta arquitectura una cobertura de detección del 63,48% con una tasa de falsas alertas del 15,52%.

**Sin embargo, este camino está actualmente cerrado para Cruzber.** Un HMM requiere, de forma imprescindible, observaciones reales del estado del lineal —es decir, resultados de auditorías físicas— para poder calibrar la probabilidad de que el modelo transite entre "en stock" y "en rotura". Sin esas observaciones, el modelo de estados latentes no tiene ancla empírica: los estados que infiere serían estadísticamente plausibles pero operativamente arbitrarios, sin garantía de que correspondan a roturas reales. El propio Montoya y González construyen y validan su modelo contra inspecciones visuales de estantería; sin ese input, la arquitectura no es aplicable.

Dado que Cruzber no dispone hoy de ningún registro de auditoría física, **el Camino 2 no es viable en las condiciones actuales de información**.

---

## Qué no tiene sentido hacer

Hay una tentación lógica pero técnicamente errónea: ajustar manualmente los umbrales del modelo para que emita más alertas. Eso aumentaría la cobertura en el papel, pero degradaría la precisión: se generarían más falsas alarmas, las auditorías perderían utilidad y el equipo operativo dejaría de confiar en el sistema.

Bruzda (2020) y Teunter, Syntetos y Babai (2017) advierten que optimizar métricas de clasificación sin conectarlas con la decisión de negocio (reposición, auditoría, fill rate) puede empeorar el resultado operativo aunque los números de cobertura mejoren. La cobertura solo es un indicador valioso si las alertas adicionales son fiables.

Por tanto, la recomendación es clara: **no crear una nueva versión del motor basada únicamente en relajar criterios sobre los mismos datos**.

---

## Decisión recomendada

### Mantener en producción

Activar y operar el modelo v5.1 como capa de alerta OOS:

```
Modelo:    h12_v5_1_state_specific_oos_policy_strict
Política:  POLICY_E1 + GATE_C_P3_Q3
Estado:    PROMOTE_ADDITIVE_CONTROLLED / ACTIVE PILOT
```

### Cerrar el experimento v5.2

La iteración v5.2 ha cumplido su propósito metodológico: confirmar que no existen mejoras incrementales válidas con la información actual. Se cierra como experimento correcto con resultado negativo esperado.

### Cierre de la investigación en el estado actual

El análisis de la literatura y los experimentos realizados conducen a una conclusión cerrada: con los datos disponibles hoy —exclusivamente ventas POS y señales derivadas, sin auditorías físicas, sin inventario real y sin información de reposición— **el modelo v5.1 es el mejor posible**.

La única vía técnica que podría superar esta frontera sin nuevos datos sería un modelo de estados latentes (HMM), pero como se ha argumentado anteriormente, esa arquitectura es inviable sin observaciones de auditoría física. El otro camino —incorporar variables de inventario, recepciones o resultados de auditoría— depende de una decisión de negocio sobre disponibilidad y coste de esos datos, y excede el alcance de la investigación actual.

La investigación queda por tanto cerrada en su fase actual. Los autores consultados —Chuang (2018), Montoya y González (2019), Mersereau (2015), Rozas Andaur et al. (2021), Trapero et al. (2024), Bruzda (2020) y Teunter et al. (2017)— convergen en el mismo diagnóstico: sin información de disponibilidad real, la señal POS tiene una frontera de identificabilidad que el presente modelo ya ha alcanzado de forma óptima.

---

## Resumen ejecutivo en una frase

> El motor OOS de Cruzber representa el máximo rendimiento alcanzable con la información actualmente disponible. Ni el ajuste de umbrales ni una arquitectura alternativa de estados latentes son viables sin auditorías físicas o datos de inventario. El modelo v5.1 es, por tanto, la mejor solución posible en el estado actual de la investigación.

---

## Referencias

- **Chuang, H. H.-C. (2018).** *Fixing shelf out-of-stock with signals in point-of-sale data.* European Journal of Operational Research, 270, 862–872. — Fundamenta el uso de rachas de ceros en POS como señal de rotura, y la ambigüedad inherente de esa señal sin stock real.

- **Montoya, R. & González, C. (2019).** *A Hidden Markov Model to Detect On-Shelf Out-of-Stocks Using Point-of-Sale Data.* Manufacturing & Service Operations Management. — Benchmark de cobertura superior (63%) mediante modelo de estados latentes; referencia para la siguiente arquitectura.

- **Mersereau, A. J. (2015).** *Demand Estimation from Censored Observations with Inventory Record Inaccuracy.* Manufacturing & Service Operations Management. — Establece que las ventas son demanda censurada por disponibilidad; sin stock, no se puede distinguir cero-demanda de cero-disponibilidad.

- **Rozas Andaur, J. M.; Ruz, G. A.; Goycoolea, M. (2021).** *Predicting Out-of-Stock Using Machine Learning: An Application in a Retail Packaged Foods Manufacturing Company.* Electronics. — Demuestra que incorporar variables de inventario y auditoría eleva el recall al 68% manteniendo alta precisión.

- **Trapero, J. R.; Holgado de Frutos, E.; Pedregal, D. J. (2024).** *Demand forecasting under lost sales stock policies.* International Journal of Forecasting. — Conecta la censura de ventas con la necesidad de variables de stock para estimar demanda latente.

- **Bruzda, J. (2020).** *Demand forecasting under fill rate constraints—The case of re-order points.* International Journal of Forecasting. — Advierte contra optimizar cobertura sin conectarla con la decisión operativa de servicio e inventario.

- **Teunter, R. H.; Syntetos, A. A.; Babai, M. Z. (2017).** *Stock keeping unit fill rate specification.* European Journal of Operational Research. — Respalda la segmentación por SKU y la prudencia ante políticas homogéneas de detección en demanda intermitente.
