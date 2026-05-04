# Audit Newsvendor V4f - Simulacion Dinamica de Inventario
Generado: 2026-04-30 04:53:30

## 1. Contexto
V4c continuo estaba aprobado como politica continua: fill=91.782%, stock/real=1.692x.
V4i/V4d/V4e fallaban porque evaluaban stock entero semanal como si no existiera carry-over.
V4f cambia la evaluacion: cada unidad no servida en una semana se arrastra como inventario a la semana siguiente.
stock_v4_continuo no se recalibra ni se modifica.

## 2. Estrategias V4f
| Estrategia | Fill dinamico % | Stock/real | Rotura | Ceros | Inv final | Valida | Score |
|---|---:|---:|---:|---:|---:|---|---:|
| repl_weekly_round | 89.397 | 1.642 | 124082 | 68890 | 875367 | FALSE | 0.093688 |
| repl_weekly_priority | 88.016 | 1.692 | 140247 | 56404 | 949913 | FALSE | 0.176567 |
| repl_monthly_release | 92.824 | 1.777 | 83982 | 91053 | 993769 | FALSE | 0.090705 |
| repl_block3_release | 92.281 | 1.736 | 90328 | 84976 | 951080 | FALSE | 0.020438 |
| repl_horizon_release | 90.874 | 1.707 | 106795 | 82582 | 933899 | FALSE | 0.005054 |
| repl_hybrid_v4f | 92.22 | 1.741 | 91048 | 85388 | 958217 | FALSE | 0.018592 |
| repl_hybrid_topup_v4f | 90.91 | 1.722 | 106374 | 82582 | 950907 | TRUE | 0.0029 |

## 3. Estrategia Ganadora
**repl_hybrid_topup_v4f**
- Fill dinamico: 90.91%
- Stock/real: 1.722x
- Stock en ceros: 82,582
- Rotura: 106,374
- Inventario final: 950,907
- Recomendacion: **APROBAR**

## 4. Comparacion V3 / V4c / V4i / V4d / V4e / V4f
| Version | Tipo eval | Fill % | Stock/real | Rotura | Ceros | Inv final |
|---|---|---:|---:|---:|---:|---:|
| V3 | dynamic | 91.757 | 1.638 | 96462 | 76150 | 843282 |
| V4c continuo | static | 91.782 | 1.692 | 96166 | 79292 | NA |
| V4i | dynamic | 90.363 | 1.722 | 112781 | 94640 | 957140 |
| V4d | dynamic | 90.515 | 1.751 | 111003 | 78026 | 989381 |
| V4e | dynamic | 92.202 | 1.744 | 91260 | 85724 | 961829 |
| V4f (repl_hybrid_topup_v4f) | dynamic | 90.91 | 1.722 | 106374 | 82582 | 950907 |

## 5. Trade-offs
- Carry-over corrige la evaluacion fisica de inventario, pero no convierte automaticamente una mala temporalizacion en servicio.
- Las estrategias por bloques preservan masa entera y arrastran excedente, a cambio de mayor inventario final.
- repl_hybrid_topup_v4f aplica service-cap: si el hibrido base supera 91.80%, usa horizon_release como base conservadora y top-up ex ante.
- El top-up se ordena solo con score ex ante; real_prov se usa unicamente para simular y detener por metricas globales.
- No se promete wMAPE < 0.20; forecast y decision de reposicion son objetos distintos.

*Script: run_newsvendor_v4f_inventory_simulation.R | set.seed(42)*
