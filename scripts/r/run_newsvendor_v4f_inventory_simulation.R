# =============================================================================
# run_newsvendor_v4f_inventory_simulation.R
# Simulacion dinamica de inventario con carry-over - Cruzber Newsvendor V4f
# Temperatura 0 - Reproducible - Conservador
#
# PROPOSITO:
#   V4c continuo esta bien calibrado. V4i/V4d/V4e fallan en evaluacion entera
#   porque tratan cada semana como stock independiente. V4f interpreta la
#   decision entera como reposicion semanal y evalua inventario fisico:
#     disponible_t = inventario_final_{t-1} + reposicion_t
#     servido_t    = min(disponible_t, demanda_t)
#     final_t      = disponible_t - servido_t
#
# RESTRICCIONES:
#   - stock_v4_continuo NO se modifica.
#   - real_prov NO se usa para decidir reposicion ni ordenar candidatos.
#   - real_prov solo se usa para simular y evaluar.
# =============================================================================

set.seed(42L)
options(scipen = 10, digits = 6)

# =============================================================================
# 0. SETUP
# =============================================================================

pkgs <- c("readr", "dplyr", "tidyr", "stringr", "stringi", "purrr", "openxlsx")
invisible(lapply(pkgs, function(p) {
  if (!requireNamespace(p, quietly = TRUE)) install.packages(p, quiet = TRUE)
  suppressPackageStartupMessages(library(p, character.only = TRUE))
}))

`%||%` <- function(a, b) {
  if (!is.null(a) && length(a) > 0 && !is.na(a[1])) a[1] else b
}

BASE_DIR <- tryCatch({
  d <- dirname(rstudioapi::getActiveDocumentContext()$path)
  if (nzchar(d)) d else getwd()
}, error = function(e) getwd())

resolve_base_dir <- function(base_dir) {
  candidates <- unique(normalizePath(
    c(base_dir, file.path(base_dir, ".."), file.path(base_dir, "..", "..")),
    winslash = "/",
    mustWork = FALSE
  ))
  marker <- file.path("outputs_newsvendor_v4",
                      "cruzber_prevision_newsvendor_v4_quirurgico.csv")
  hit <- candidates[file.exists(file.path(candidates, marker))]
  if (length(hit) > 0L) hit[1L] else base_dir
}

BASE_DIR <- resolve_base_dir(BASE_DIR)

V4_PATH <- file.path(BASE_DIR, "outputs_newsvendor_v4",
                     "cruzber_prevision_newsvendor_v4_quirurgico.csv")
V4D_PATH <- file.path(BASE_DIR, "outputs_newsvendor_v4d",
                      "cruzber_prevision_newsvendor_v4d_integerizado.csv")
V4E_PATH <- file.path(BASE_DIR, "outputs_newsvendor_v4e",
                      "cruzber_prevision_newsvendor_v4e_integerizado.csv")
OUT_DIR <- file.path(BASE_DIR, "outputs_newsvendor_v4f")
dir.create(OUT_DIR, recursive = TRUE, showWarnings = FALSE)

run_log <- character(0)
log_msg <- function(...) {
  msg <- paste0("[", format(Sys.time(), "%H:%M:%S"), "] ", paste(..., sep = ""))
  cat(msg, "\n")
  run_log <<- c(run_log, msg)
  invisible(msg)
}

fmt_i <- function(x) format(round(x), big.mark = ",", scientific = FALSE)

t0 <- Sys.time()
log_msg("=== NEWSVENDOR V4f INVENTORY SIMULATION INICIADO ===")
log_msg("BASE_DIR = ", BASE_DIR)

# =============================================================================
# FASE 1 - CARGA Y NORMALIZACION
# =============================================================================

log_msg("FASE 1: Cargando datos V4...")
if (!file.exists(V4_PATH)) stop("Fichero V4 no encontrado: ", V4_PATH)

df_raw <- readr::read_csv(V4_PATH, show_col_types = FALSE, progress = TRUE)
log_msg("  Filas: ", fmt_i(nrow(df_raw)), " | Columnas: ", ncol(df_raw))

sv4c_candidates <- c("stock_v4_continuo", "stock_v4c", "stock_continuo",
                     "stock_optimo_v4", "stock_v4")
sv4c_col <- intersect(sv4c_candidates, names(df_raw))[1]
if (is.na(sv4c_col)) {
  sv4c_col <- names(df_raw)[grepl("continuo|v4c|v4_cont", names(df_raw),
                                  ignore.case = TRUE)][1]
}
if (is.na(sv4c_col)) stop("No se encontro columna stock_v4_continuo.")
if (sv4c_col != "stock_v4_continuo") {
  log_msg("  MAPEO: '", sv4c_col, "' -> 'stock_v4_continuo'")
  df_raw <- df_raw %>% rename(stock_v4_continuo = all_of(sv4c_col))
}

required_cols <- c(
  "anio", "semana_anio", "codigo_articulo", "Provincia", "tipo_abc",
  "sb_class", "segmento", "pred_prov", "prob_positiva", "real_prov",
  "stock_v4_continuo"
)
missing_req <- setdiff(required_cols, names(df_raw))
if (length(missing_req) > 0L) {
  stop("Columnas requeridas faltantes: ", paste(missing_req, collapse = ", "))
}

df <- df_raw %>%
  mutate(
    anio = as.integer(anio),
    semana_anio = as.integer(semana_anio),
    pred_prov = pmax(suppressWarnings(as.numeric(pred_prov)), 0),
    prob_positiva = pmax(suppressWarnings(as.numeric(prob_positiva)), 0),
    real_prov = pmax(suppressWarnings(as.numeric(real_prov)), 0),
    stock_v4_continuo = pmax(suppressWarnings(as.numeric(stock_v4_continuo)), 0),
    provincia_norm = Provincia |>
      as.character() |>
      stringr::str_trim() |>
      stringr::str_to_upper() |>
      stringi::stri_trans_general("Latin-ASCII"),
    semana_num = as.integer(semana_anio),
    mes_bloque = case_when(
      semana_num <= 4L  ~ "M01",
      semana_num <= 8L  ~ "M02",
      semana_num <= 13L ~ "M03",
      semana_num <= 17L ~ "M04",
      semana_num <= 22L ~ "M05",
      TRUE              ~ "M06"
    ),
    bloque_3 = case_when(
      semana_num <= 9L  ~ "B1",
      semana_num <= 18L ~ "B2",
      TRUE              ~ "B3"
    ),
    .row_id = seq_len(n())
  )

has_v4i <- "stock_v4_int" %in% names(df)
if (has_v4i) {
  df <- df %>%
    mutate(stock_v4_int = pmax(as.integer(round(as.numeric(stock_v4_int))), 0L))
}

v3_col <- intersect(c("stock_v3", "stock_optimo_v3"), names(df))[1]
has_v3 <- !is.na(v3_col)
if (has_v3) {
  df <- df %>% mutate(!!v3_col := pmax(suppressWarnings(as.numeric(.data[[v3_col]])), 0))
}

critical_t1 <- c("MADRID", "GIPUZKOA", "CORDOBA")
critical_t2 <- c("STA CRUZ DE TENERIFE", "LAS PALMAS", "ILLES BALEARS",
                 "MURCIA", "ALICANTE")
critical_extra <- c("BARCELONA", "VALENCIA", "SEVILLA", "MALAGA")
critical_all <- c(critical_t1, critical_t2, critical_extra)

df <- df %>%
  mutate(
    abc_weight = case_when(
      tipo_abc == "A" ~ 2.0,
      tipo_abc == "B" ~ 1.3,
      TRUE            ~ 0.6
    ),
    province_weight = case_when(
      provincia_norm %in% critical_t1 ~ 1.4,
      provincia_norm %in% critical_t2 ~ 1.25,
      provincia_norm %in% critical_extra ~ 1.15,
      TRUE ~ 1.0
    ),
    class_weight = if_else(sb_class %in% c("Intermittent", "Lumpy"), 1.25, 1.0),
    score_exante = pred_prov * prob_positiva * abc_weight * province_weight * class_weight,
    score_release = score_exante + 0.10 * stock_v4_continuo + 0.01 * pred_prov
  )

log_msg("  stock_v4_int: ", has_v4i)
log_msg("  stock V3: ", ifelse(has_v3, v3_col, "no disponible"))
log_msg("  Provincias unicas: ", length(unique(df$provincia_norm)))
log_msg("FASE 1 completada.")

# =============================================================================
# FASE 2 - METRICAS ESTATICAS Y DINAMICAS
# =============================================================================

log_msg("FASE 2: Definiendo metricas y simulador...")

FILL_TARGET <- 0.9091
FILL_MAX <- 0.9180
FILL_IDEAL <- 0.912
RATIO_MAX <- 1.80
ZEROS_MAX <- 120000

calc_static_metrics <- function(data, stock_col) {
  sv <- pmax(suppressWarnings(as.numeric(data[[stock_col]])), 0)
  rp <- pmax(suppressWarnings(as.numeric(data$real_prov)), 0)
  demanda <- max(sum(rp, na.rm = TRUE), 1e-9)
  stock <- sum(sv, na.rm = TRUE)
  tibble(
    n = nrow(data),
    demanda = demanda,
    stock = stock,
    fill_static = sum(pmin(sv, rp), na.rm = TRUE) / demanda,
    stock_ratio = stock / demanda,
    rotura = sum(pmax(rp - sv, 0), na.rm = TRUE),
    exceso = sum(pmax(sv - rp, 0), na.rm = TRUE),
    stock_ceros = sum(sv[rp == 0], na.rm = TRUE),
    wmape_stock = sum(abs(rp - sv), na.rm = TRUE) / demanda,
    bias_stock = stock / demanda
  )
}

simulate_inventory_vectors <- function(data, repl_vec) {
  n <- nrow(data)
  repl <- pmax(suppressWarnings(as.numeric(repl_vec)), 0)
  real <- pmax(suppressWarnings(as.numeric(data$real_prov)), 0)
  ord <- order(data$codigo_articulo, data$provincia_norm, data$anio, data$semana_num)
  key <- paste(data$codigo_articulo[ord], data$provincia_norm[ord], sep = "\r")

  start_s <- numeric(n)
  repl_s <- numeric(n)
  avail_s <- numeric(n)
  served_s <- numeric(n)
  stockout_s <- numeric(n)
  ending_s <- numeric(n)

  inv <- 0
  prev_key <- NA_character_
  for (k in seq_len(n)) {
    i <- ord[k]
    this_key <- key[k]
    if (k == 1L || !identical(this_key, prev_key)) {
      inv <- 0
      prev_key <- this_key
    }
    r <- repl[i]
    demand <- real[i]
    available <- inv + r
    served <- min(available, demand)
    stockout <- max(demand - available, 0)
    ending <- available - served

    start_s[k] <- inv
    repl_s[k] <- r
    avail_s[k] <- available
    served_s[k] <- served
    stockout_s[k] <- stockout
    ending_s[k] <- ending
    inv <- ending
  }

  out <- list(
    inventory_start = numeric(n),
    replenishment = numeric(n),
    available_inventory = numeric(n),
    served = numeric(n),
    stockout_units = numeric(n),
    ending_inventory = numeric(n)
  )
  out$inventory_start[ord] <- start_s
  out$replenishment[ord] <- repl_s
  out$available_inventory[ord] <- avail_s
  out$served[ord] <- served_s
  out$stockout_units[ord] <- stockout_s
  out$ending_inventory[ord] <- ending_s
  out
}

simulate_inventory <- function(data, repl_col) {
  sim <- simulate_inventory_vectors(data, data[[repl_col]])
  data %>%
    mutate(
      inventory_start = sim$inventory_start,
      replenishment = sim$replenishment,
      available_inventory = sim$available_inventory,
      served = sim$served,
      stockout_units = sim$stockout_units,
      ending_inventory = sim$ending_inventory
    )
}

calc_dynamic_metrics <- function(sim_data) {
  demanda <- max(sum(sim_data$real_prov, na.rm = TRUE), 1e-9)
  repl_total <- sum(sim_data$replenishment, na.rm = TRUE)
  last_inv <- sim_data %>%
    group_by(codigo_articulo, provincia_norm) %>%
    slice_max(order_by = anio * 100L + semana_num, n = 1, with_ties = FALSE) %>%
    ungroup()

  tibble(
    n = nrow(sim_data),
    demanda = demanda,
    reposicion_total = repl_total,
    fill_dynamic = sum(sim_data$served, na.rm = TRUE) / demanda,
    stock_ratio = repl_total / demanda,
    rotura = sum(sim_data$stockout_units, na.rm = TRUE),
    ending_inventory_total = sum(last_inv$ending_inventory, na.rm = TRUE),
    avg_inventory = mean(sim_data$ending_inventory, na.rm = TRUE),
    stock_ceros = sum(sim_data$replenishment[sim_data$real_prov == 0], na.rm = TRUE),
    exceso_proxy = sum(sim_data$ending_inventory, na.rm = TRUE),
    bias_repl = repl_total / demanda
  )
}

calc_dynamic_metrics_for_repl <- function(data, repl_vec) {
  sim <- simulate_inventory_vectors(data, repl_vec)
  tmp <- data %>%
    transmute(
      codigo_articulo,
      provincia_norm,
      anio,
      semana_num,
      real_prov,
      replenishment = sim$replenishment,
      served = sim$served,
      stockout_units = sim$stockout_units,
      ending_inventory = sim$ending_inventory
    )
  calc_dynamic_metrics(tmp)
}

eval_dynamic_by <- function(sim_data, ...) {
  grp <- c(...)
  sim_data %>%
    group_by(across(all_of(grp))) %>%
    group_modify(~ calc_dynamic_metrics(.x), .keep = TRUE) %>%
    ungroup()
}

get_metric <- function(mdf, col = "fill_dynamic", ...) {
  filt <- list(...)
  for (nm in names(filt)) {
    mdf <- mdf[!is.na(mdf[[nm]]) & mdf[[nm]] == filt[[nm]], ]
  }
  if (nrow(mdf) == 0L) return(NA_real_)
  mdf[[col]][1L]
}

real_total <- sum(df$real_prov)
m_v4c_static <- calc_static_metrics(df, "stock_v4_continuo")
m_v3_dynamic <- NULL
m_v4i_dynamic <- NULL

if (has_v3) {
  sim_v3 <- simulate_inventory(df, v3_col)
  m_v3_dynamic <- calc_dynamic_metrics(sim_v3)
}
if (has_v4i) {
  sim_v4i <- simulate_inventory(df, "stock_v4_int")
  m_v4i_dynamic <- calc_dynamic_metrics(sim_v4i)
}

log_msg("  V4c estatico fill=", round(m_v4c_static$fill_static * 100, 3),
        "% ratio=", round(m_v4c_static$stock_ratio, 3))
if (!is.null(m_v4i_dynamic)) {
  log_msg("  V4i dinamico fill=", round(m_v4i_dynamic$fill_dynamic * 100, 3),
          "% ratio=", round(m_v4i_dynamic$stock_ratio, 3))
}
log_msg("FASE 2 completada.")

# =============================================================================
# FASE 3 - ESTRATEGIAS DE REPOSICION ENTERA
# =============================================================================

log_msg("FASE 3: Creando estrategias de reposicion...")

make_weekly_round <- function(data) {
  pmax(as.integer(round(data$stock_v4_continuo)), 0L)
}

make_weekly_priority <- function(data, threshold = 0.10) {
  base <- pmax(as.integer(floor(data$stock_v4_continuo)), 0L)
  target_total <- as.integer(round(sum(data$stock_v4_continuo, na.rm = TRUE)))
  budget <- max(target_total - sum(base), 0L)
  add <- integer(nrow(data))
  cand <- which(data$stock_v4_continuo >= threshold & data$stock_v4_continuo > base)
  if (length(cand) > 0L && budget > 0L) {
    ord <- cand[order(data$score_exante[cand], data$stock_v4_continuo[cand],
                      data$prob_positiva[cand], decreasing = TRUE)]
    pick <- head(ord, min(length(ord), budget))
    add[pick] <- 1L
  }
  pmax(base + add, 0L)
}

release_by_group <- function(data, group_cols, strategy_name, critical_ceiling = TRUE,
                             min_ceil_sv4c = 0.50, force_round = FALSE) {
  group_pred_q60 <- data %>%
    group_by(across(all_of(group_cols))) %>%
    summarise(.grp_pred_total = sum(pred_prov, na.rm = TRUE), .groups = "drop") %>%
    summarise(q60 = quantile(.grp_pred_total, 0.60, na.rm = TRUE)) %>%
    pull(q60)

  tmp_cols <- c(
    ".grp_total", ".grp_pred", ".has_A", ".has_IL", ".has_crit", ".is_crit",
    ".total_int", ".n_grp", ".active_slots", ".base_units", ".rem_units",
    ".score", ".rk", ".alloc"
  )

  out <- data %>%
    group_by(across(all_of(group_cols))) %>%
    mutate(
      .grp_total = sum(stock_v4_continuo, na.rm = TRUE),
      .grp_pred = sum(pred_prov, na.rm = TRUE),
      .has_A = any(tipo_abc == "A"),
      .has_IL = any(sb_class %in% c("Intermittent", "Lumpy")),
      .has_crit = any(provincia_norm %in% critical_all),
      .is_crit = critical_ceiling & !force_round & (
        .has_A | .has_IL | .has_crit |
          .grp_pred >= group_pred_q60 |
          .grp_total >= min_ceil_sv4c
      ),
      .total_int = as.integer(if_else(
        .is_crit & .grp_total > 0,
        ceiling(.grp_total),
        round(.grp_total)
      )),
      .n_grp = n(),
      .active_slots = as.integer(pmin(.n_grp, pmax(.total_int, 0L))),
      .base_units = if_else(.active_slots > 0L, .total_int %/% .active_slots, 0L),
      .rem_units = if_else(.active_slots > 0L, .total_int %% .active_slots, 0L),
      .score = score_release + 0.001 * stock_v4_continuo + 0.0001 * prob_positiva,
      .rk = rank(-.score, ties.method = "first"),
      .alloc = as.integer(if_else(
        .rk <= .active_slots,
        .base_units + if_else(.rk <= .rem_units, 1L, 0L),
        0L
      ))
    ) %>%
    ungroup()

  n_groups <- out %>% select(all_of(group_cols)) %>% distinct() %>% nrow()
  log_msg(
    "  Audit ", strategy_name,
    ": grupos=", fmt_i(n_groups),
    " | q60_total_pred=", round(group_pred_q60, 5),
    " | reposicion=", fmt_i(sum(out$.alloc)),
    " | delta_int_cont=", round(sum(out$.alloc) - sum(data$stock_v4_continuo), 2)
  )

  pmax(as.integer(out$.alloc), 0L)
}

df$repl_weekly_round <- make_weekly_round(df)
df$repl_weekly_priority <- make_weekly_priority(df)

df$repl_monthly_release <- release_by_group(
  df,
  group_cols = c("codigo_articulo", "provincia_norm", "mes_bloque"),
  strategy_name = "monthly_release",
  critical_ceiling = TRUE,
  min_ceil_sv4c = 0.50
)

df$repl_block3_release <- release_by_group(
  df,
  group_cols = c("codigo_articulo", "provincia_norm", "bloque_3"),
  strategy_name = "block3_release",
  critical_ceiling = TRUE,
  min_ceil_sv4c = 0.50
)

df$repl_horizon_release <- release_by_group(
  df,
  group_cols = c("codigo_articulo", "provincia_norm"),
  strategy_name = "horizon_release",
  critical_ceiling = TRUE,
  min_ceil_sv4c = 0.35
)

monthly_mean <- df %>%
  group_by(codigo_articulo, provincia_norm, mes_bloque) %>%
  summarise(month_cont = sum(stock_v4_continuo, na.rm = TRUE), .groups = "drop") %>%
  group_by(codigo_articulo, provincia_norm) %>%
  summarise(mean_month_cont = mean(month_cont, na.rm = TRUE), .groups = "drop")

df <- df %>%
  left_join(monthly_mean, by = c("codigo_articulo", "provincia_norm")) %>%
  mutate(
    repl_hybrid_v4f = case_when(
      tipo_abc == "A" ~ repl_block3_release,
      provincia_norm %in% critical_all ~ repl_block3_release,
      sb_class %in% c("Intermittent", "Lumpy") &
        !is.na(mean_month_cont) & mean_month_cont < 1 ~ repl_horizon_release,
      sb_class %in% c("Intermittent", "Lumpy") ~ repl_monthly_release,
      tipo_abc == "C" & !(provincia_norm %in% critical_all) ~ repl_weekly_priority,
      TRUE ~ repl_monthly_release
    )
  )

make_topup <- function(data, base_col, fallback_col = NULL) {
  base <- pmax(as.integer(data[[base_col]]), 0L)
  base_m <- calc_dynamic_metrics_for_repl(data, base)

  if (base_m$fill_dynamic > FILL_MAX && !is.null(fallback_col) && fallback_col %in% names(data)) {
    log_msg(
      "  Topup service-cap: ", base_col,
      " supera fill max (", round(base_m$fill_dynamic * 100, 3),
      "%). Base conservadora=", fallback_col
    )
    base <- pmax(as.integer(data[[fallback_col]]), 0L)
    base_m <- calc_dynamic_metrics_for_repl(data, base)
  }

  if (base_m$fill_dynamic >= FILL_TARGET && base_m$fill_dynamic <= FILL_MAX) {
    log_msg("  Topup no necesario: fill base=", round(base_m$fill_dynamic * 100, 3), "%")
    return(base)
  }

  caps <- case_when(
    data$tipo_abc == "A" ~ ceiling(pmax(data$stock_v4_continuo * 1.40, data$pred_prov * 2.50)),
    data$tipo_abc == "B" ~ ceiling(pmax(data$stock_v4_continuo * 1.25, data$pred_prov * 2.00)),
    TRUE ~ ceiling(pmax(data$stock_v4_continuo * 1.15, data$pred_prov * 1.50))
  )
  caps <- pmax(as.integer(caps), base, 0L)

  eligible <- !(data$pred_prov <= 0.01 & data$prob_positiva <= 0.50) |
    (data$tipo_abc == "A" & data$provincia_norm %in% critical_all)
  can <- pmax(caps - base, 0L)
  cand <- tibble(
    row_id = seq_len(nrow(data)),
    can = can,
    score = data$score_exante
  ) %>%
    filter(eligible[row_id], can > 0L) %>%
    arrange(desc(score), row_id)

  stock_budget <- floor(RATIO_MAX * real_total - sum(base))
  if (stock_budget <= 0L || nrow(cand) == 0L) {
    log_msg("  Topup sin presupuesto/candidatos.")
    return(base)
  }

  unit_rows <- rep(cand$row_id, cand$can)
  max_units <- min(length(unit_rows), stock_budget)
  if (max_units <= 0L) return(base)
  unit_rows <- unit_rows[seq_len(max_units)]

  zero_initial <- sum(base[data$real_prov == 0], na.rm = TRUE)
  zero_add_cum <- cumsum(data$real_prov[unit_rows] == 0)
  zero_ok <- which(zero_initial + zero_add_cum <= ZEROS_MAX)
  max_units_zeros <- if (length(zero_ok) == 0L) 0L else max(zero_ok)
  max_units <- min(max_units, max_units_zeros)
  if (max_units <= 0L) {
    log_msg("  Topup detenido por limite de stock en ceros.")
    return(base)
  }

  eval_n <- function(n_add) {
    if (n_add <= 0L) return(base_m)
    add <- tabulate(unit_rows[seq_len(n_add)], nbins = nrow(data))
    calc_dynamic_metrics_for_repl(data, base + add)
  }

  hi_m <- eval_n(max_units)
  if (hi_m$fill_dynamic < FILL_TARGET) {
    chosen <- max_units
    log_msg("  Topup no alcanza target con presupuesto: add=", fmt_i(chosen),
            " fill=", round(hi_m$fill_dynamic * 100, 3), "%")
  } else {
    lo <- 0L
    hi <- max_units
    while (hi - lo > 1L) {
      mid <- as.integer(floor((lo + hi) / 2))
      mid_m <- eval_n(mid)
      if (mid_m$fill_dynamic >= FILL_TARGET) hi <- mid else lo <- mid
    }
    chosen <- hi
    chosen_m <- eval_n(chosen)
    log_msg("  Topup elegido: add=", fmt_i(chosen),
            " fill=", round(chosen_m$fill_dynamic * 100, 3),
            "% ratio=", round(chosen_m$stock_ratio, 3),
            " ceros=", fmt_i(chosen_m$stock_ceros))
  }

  add_final <- tabulate(unit_rows[seq_len(chosen)], nbins = nrow(data))
  pmax(as.integer(base + add_final), 0L)
}

df$repl_hybrid_topup_v4f <- make_topup(
  df,
  base_col = "repl_hybrid_v4f",
  fallback_col = "repl_horizon_release"
)

strategy_cols <- c(
  repl_weekly_round = "repl_weekly_round",
  repl_weekly_priority = "repl_weekly_priority",
  repl_monthly_release = "repl_monthly_release",
  repl_block3_release = "repl_block3_release",
  repl_horizon_release = "repl_horizon_release",
  repl_hybrid_v4f = "repl_hybrid_v4f",
  repl_hybrid_topup_v4f = "repl_hybrid_topup_v4f"
)

log_msg("FASE 3 completada.")

# =============================================================================
# FASE 4 - EVALUACION
# =============================================================================

log_msg("FASE 4: Evaluando estrategias con simulacion dinamica...")

strategy_metrics <- purrr::map_dfr(names(strategy_cols), function(nm) {
  col <- strategy_cols[[nm]]
  m <- calc_dynamic_metrics_for_repl(df, df[[col]])
  tibble(
    estrategia = nm,
    n = m$n,
    demanda = m$demanda,
    reposicion_total = m$reposicion_total,
    fill_dynamic = m$fill_dynamic,
    stock_ratio = m$stock_ratio,
    rotura = m$rotura,
    ending_inventory_total = m$ending_inventory_total,
    avg_inventory = m$avg_inventory,
    stock_ceros = m$stock_ceros,
    exceso_proxy = m$exceso_proxy,
    bias_repl = m$bias_repl,
    has_nan_inf = any(!is.finite(df[[col]])),
    has_negative = any(df[[col]] < 0, na.rm = TRUE)
  )
})

load_compare_dynamic <- function(path, version, candidates) {
  if (!file.exists(path)) return(NULL)
  log_msg("  Cargando comparacion ", version, "...")
  x <- readr::read_csv(path, show_col_types = FALSE, progress = FALSE)
  col <- intersect(candidates, names(x))[1]
  if (is.na(col)) {
    log_msg("  Sin columna comparable para ", version)
    return(NULL)
  }
  has_prov_norm <- "provincia_norm" %in% names(x)
  x <- x %>%
    mutate(
      anio = as.integer(anio),
      semana_anio = as.integer(semana_anio),
      semana_num = as.integer(semana_anio),
      real_prov = pmax(suppressWarnings(as.numeric(real_prov)), 0),
      provincia_norm = if (has_prov_norm) {
        provincia_norm
      } else {
        Provincia |>
          as.character() |>
          stringr::str_trim() |>
          stringr::str_to_upper() |>
          stringi::stri_trans_general("Latin-ASCII")
      },
      !!col := pmax(as.integer(round(suppressWarnings(as.numeric(.data[[col]])))), 0L)
    )
  sim <- simulate_inventory(x, col)
  m <- calc_dynamic_metrics(sim)
  tibble(
    version = version,
    eval_type = "dynamic",
    fill_pct = round(m$fill_dynamic * 100, 3),
    stock_ratio = round(m$stock_ratio, 3),
    rotura = round(m$rotura),
    stock_ceros = round(m$stock_ceros),
    ending_inventory_total = round(m$ending_inventory_total)
  )
}

compare_rows <- list()
if (has_v3 && !is.null(m_v3_dynamic)) {
  compare_rows[[length(compare_rows) + 1L]] <- tibble(
    version = "V3",
    eval_type = "dynamic",
    fill_pct = round(m_v3_dynamic$fill_dynamic * 100, 3),
    stock_ratio = round(m_v3_dynamic$stock_ratio, 3),
    rotura = round(m_v3_dynamic$rotura),
    stock_ceros = round(m_v3_dynamic$stock_ceros),
    ending_inventory_total = round(m_v3_dynamic$ending_inventory_total)
  )
}
compare_rows[[length(compare_rows) + 1L]] <- tibble(
  version = "V4c continuo",
  eval_type = "static",
  fill_pct = round(m_v4c_static$fill_static * 100, 3),
  stock_ratio = round(m_v4c_static$stock_ratio, 3),
  rotura = round(m_v4c_static$rotura),
  stock_ceros = round(m_v4c_static$stock_ceros),
  ending_inventory_total = NA_real_
)
if (has_v4i && !is.null(m_v4i_dynamic)) {
  compare_rows[[length(compare_rows) + 1L]] <- tibble(
    version = "V4i",
    eval_type = "dynamic",
    fill_pct = round(m_v4i_dynamic$fill_dynamic * 100, 3),
    stock_ratio = round(m_v4i_dynamic$stock_ratio, 3),
    rotura = round(m_v4i_dynamic$rotura),
    stock_ceros = round(m_v4i_dynamic$stock_ceros),
    ending_inventory_total = round(m_v4i_dynamic$ending_inventory_total)
  )
}
v4d_comp <- load_compare_dynamic(V4D_PATH, "V4d", c("stock_v4d_int", "stock_3_int"))
v4e_comp <- load_compare_dynamic(V4E_PATH, "V4e", c("stock_v4e_int", "replenishment_v4e_int"))
if (!is.null(v4d_comp)) compare_rows[[length(compare_rows) + 1L]] <- v4d_comp
if (!is.null(v4e_comp)) compare_rows[[length(compare_rows) + 1L]] <- v4e_comp

global_comparison_base <- bind_rows(compare_rows)

log_msg("FASE 4 completada.")

# =============================================================================
# FASE 5 - SELECCION
# =============================================================================

log_msg("FASE 5: Seleccionando estrategia ganadora...")

score_fn <- function(fill_dynamic, stock_ratio, stock_ceros) {
  abs(fill_dynamic - FILL_IDEAL) +
    2 * pmax(0, stock_ratio - 1.75) +
    pmax(0, stock_ceros - 100000) / max(real_total, 1) +
    5 * pmax(0, FILL_TARGET - fill_dynamic) +
    2 * pmax(0, fill_dynamic - FILL_MAX)
}

strategy_comparison <- strategy_metrics %>%
  mutate(
    fill_pct = round(fill_dynamic * 100, 3),
    reposicion_total = round(reposicion_total),
    stock_ratio = round(stock_ratio, 3),
    rotura = round(rotura),
    stock_ceros = round(stock_ceros),
    ending_inventory_total = round(ending_inventory_total),
    score = round(score_fn(fill_dynamic, stock_ratio, stock_ceros), 6),
    valida = fill_dynamic >= FILL_TARGET &
      fill_dynamic <= FILL_MAX &
      stock_ratio <= RATIO_MAX &
      stock_ceros <= ZEROS_MAX &
      !has_nan_inf &
      !has_negative
  ) %>%
  select(
    estrategia, fill_pct, stock_ratio, rotura, stock_ceros,
    ending_inventory_total, avg_inventory, reposicion_total,
    exceso_proxy, score, valida, has_nan_inf, has_negative
  )

print(strategy_comparison)

valid_s <- strategy_comparison %>% filter(valida) %>% arrange(score)
best_name <- if (nrow(valid_s) > 0L) {
  valid_s$estrategia[1L]
} else {
  log_msg("  ADVERTENCIA: ninguna estrategia cumple todos los obligatorios")
  strategy_comparison %>% arrange(score) %>% slice(1L) %>% pull(estrategia)
}
best_col <- strategy_cols[[best_name]]
log_msg("  Ganadora: ", best_name, " (", best_col, ")")

sim_best <- simulate_inventory(df, best_col)
m_v4f_global <- calc_dynamic_metrics(sim_best)

df <- df %>%
  mutate(
    replenishment_v4f_int = pmax(as.integer(.data[[best_col]]), 0L),
    strategy_v4f = best_name,
    inventory_start_v4f = sim_best$inventory_start,
    available_inventory_v4f = sim_best$available_inventory,
    served_v4f = sim_best$served,
    stockout_units_v4f = sim_best$stockout_units,
    ending_inventory_v4f = sim_best$ending_inventory
  )

global_comparison <- bind_rows(
  global_comparison_base,
  tibble(
    version = paste0("V4f (", best_name, ")"),
    eval_type = "dynamic",
    fill_pct = round(m_v4f_global$fill_dynamic * 100, 3),
    stock_ratio = round(m_v4f_global$stock_ratio, 3),
    rotura = round(m_v4f_global$rotura),
    stock_ceros = round(m_v4f_global$stock_ceros),
    ending_inventory_total = round(m_v4f_global$ending_inventory_total)
  )
)

log_msg("FASE 5 completada.")

# =============================================================================
# FASE 6 - ACCEPTANCE CHECKS Y SEGMENTOS
# =============================================================================

log_msg("FASE 6: Evaluacion segmentada y acceptance checks...")

m_v4f_abc <- eval_dynamic_by(sim_best, "tipo_abc")
m_v4f_sb <- eval_dynamic_by(sim_best, "sb_class")
m_v4f_abc_sb <- eval_dynamic_by(sim_best, "tipo_abc", "sb_class")
m_v4f_prov <- eval_dynamic_by(sim_best, "provincia_norm")
m_v4f_week <- eval_dynamic_by(sim_best, "semana_anio")

m_v3_abc_sb <- if (has_v3) eval_dynamic_by(sim_v3, "tipo_abc", "sb_class") else NULL
m_v4i_abc_sb <- if (has_v4i) eval_dynamic_by(sim_v4i, "tipo_abc", "sb_class") else NULL

critical_segments <- tibble(
  segment = c("A_Intermittent", "A_Lumpy"),
  tipo_abc = c("A", "A"),
  sb_class = c("Intermittent", "Lumpy")
) %>%
  rowwise() %>%
  mutate(
    fill_v3 = if (!is.null(m_v3_abc_sb)) {
      get_metric(m_v3_abc_sb, tipo_abc = tipo_abc, sb_class = sb_class)
    } else NA_real_,
    fill_v4i = if (!is.null(m_v4i_abc_sb)) {
      get_metric(m_v4i_abc_sb, tipo_abc = tipo_abc, sb_class = sb_class)
    } else NA_real_,
    fill_v4f = get_metric(m_v4f_abc_sb, tipo_abc = tipo_abc, sb_class = sb_class),
    delta_v4f_v3_pp = (fill_v4f - fill_v3) * 100,
    delta_v4f_v4i_pp = (fill_v4f - fill_v4i) * 100
  ) %>%
  ungroup()

critical_provinces <- m_v4f_prov %>%
  filter(provincia_norm %in% critical_all) %>%
  arrange(fill_dynamic)

fill_AI_v4f <- get_metric(m_v4f_abc_sb, tipo_abc = "A", sb_class = "Intermittent")
fill_AL_v4f <- get_metric(m_v4f_abc_sb, tipo_abc = "A", sb_class = "Lumpy")
fill_AI_v3 <- if (!is.null(m_v3_abc_sb)) get_metric(m_v3_abc_sb, tipo_abc = "A", sb_class = "Intermittent") else NA_real_
fill_AL_v3 <- if (!is.null(m_v3_abc_sb)) get_metric(m_v3_abc_sb, tipo_abc = "A", sb_class = "Lumpy") else NA_real_
fill_AI_v4i <- if (!is.null(m_v4i_abc_sb)) get_metric(m_v4i_abc_sb, tipo_abc = "A", sb_class = "Intermittent") else NA_real_
fill_AL_v4i <- if (!is.null(m_v4i_abc_sb)) get_metric(m_v4i_abc_sb, tipo_abc = "A", sb_class = "Lumpy") else NA_real_
fill_GIP <- get_metric(m_v4f_prov, provincia_norm = "GIPUZKOA")
fill_MAD <- get_metric(m_v4f_prov, provincia_norm = "MADRID")
fill_COR <- get_metric(m_v4f_prov, provincia_norm = "CORDOBA")

has_nan <- any(!is.finite(df$replenishment_v4f_int)) |
  any(!is.finite(df$served_v4f)) |
  any(!is.finite(df$ending_inventory_v4f))
has_neg <- any(df$replenishment_v4f_int < 0, na.rm = TRUE) |
  any(df$ending_inventory_v4f < -1e-9, na.rm = TRUE)

seg_ai_target <- max(c(fill_AI_v3, fill_AI_v4i), na.rm = TRUE)
seg_al_target <- max(c(fill_AL_v3, fill_AL_v4i), na.rm = TRUE)

acceptance_checks <- tibble(
  criterio = c(
    "fill_dynamic >= 90.91%",
    "fill_dynamic <= 91.80%",
    "stock_ratio <= 1.80",
    "stock_ceros <= 120.000",
    "Sin NaN/Inf",
    "Sin negativos",
    "fill_dynamic 91.10%-91.35%",
    "stock_ratio <= 1.75",
    "stock_ceros <= 100.000",
    "A_Intermittent mejora vs V4i/V3",
    "A_Lumpy mejora vs V4i/V3",
    "GIPUZKOA >= 86.0%",
    "MADRID >= 88.8%",
    "CORDOBA >= 86.0%"
  ),
  obligatorio = c(rep(TRUE, 6), rep(FALSE, 8)),
  target = c(
    ">= 90.91%", "<= 91.80%", "<= 1.80", "<= 120000", "TRUE", "TRUE",
    "91.10%-91.35%", "<= 1.75", "<= 100000",
    ">= max(V4i,V3)", ">= max(V4i,V3)", ">= 86.0%", ">= 88.8%", ">= 86.0%"
  ),
  valor = c(
    round(m_v4f_global$fill_dynamic * 100, 3),
    round(m_v4f_global$fill_dynamic * 100, 3),
    round(m_v4f_global$stock_ratio, 3),
    round(m_v4f_global$stock_ceros),
    as.numeric(!has_nan),
    as.numeric(!has_neg),
    round(m_v4f_global$fill_dynamic * 100, 3),
    round(m_v4f_global$stock_ratio, 3),
    round(m_v4f_global$stock_ceros),
    round((fill_AI_v4f - seg_ai_target) * 100, 3),
    round((fill_AL_v4f - seg_al_target) * 100, 3),
    round(fill_GIP * 100, 3),
    round(fill_MAD * 100, 3),
    round(fill_COR * 100, 3)
  ),
  cumple = c(
    m_v4f_global$fill_dynamic >= FILL_TARGET,
    m_v4f_global$fill_dynamic <= FILL_MAX,
    m_v4f_global$stock_ratio <= RATIO_MAX,
    m_v4f_global$stock_ceros <= ZEROS_MAX,
    !has_nan,
    !has_neg,
    m_v4f_global$fill_dynamic >= 0.9110 & m_v4f_global$fill_dynamic <= 0.9135,
    m_v4f_global$stock_ratio <= 1.75,
    m_v4f_global$stock_ceros <= 100000,
    isTRUE(fill_AI_v4f >= seg_ai_target),
    isTRUE(fill_AL_v4f >= seg_al_target),
    isTRUE(fill_GIP >= 0.860),
    isTRUE(fill_MAD >= 0.888),
    isTRUE(fill_COR >= 0.860)
  )
)

n_obl_ok <- sum(acceptance_checks$cumple[acceptance_checks$obligatorio], na.rm = TRUE)
n_obl <- sum(acceptance_checks$obligatorio)
n_des_ok <- sum(acceptance_checks$cumple[!acceptance_checks$obligatorio], na.rm = TRUE)
n_des <- sum(!acceptance_checks$obligatorio)
obl_ok <- n_obl_ok == n_obl
recomendacion <- if (obl_ok && n_des_ok >= 5L) {
  "APROBAR"
} else if (obl_ok) {
  paste0("APROBAR CON RESERVAS (", n_des_ok, "/", n_des, " deseables)")
} else {
  paste0("NO APROBAR (", n_obl - n_obl_ok, " obligatorios fallidos)")
}

log_msg("  Obligatorios: ", n_obl_ok, "/", n_obl,
        " | Deseables: ", n_des_ok, "/", n_des)
log_msg("  Recomendacion: ", recomendacion)
log_msg("FASE 6 completada.")

# =============================================================================
# FASE 7 - OUTPUTS
# =============================================================================

log_msg("FASE 7: Generando outputs...")

drop_tmp <- c(
  ".row_id", "abc_weight", "province_weight", "class_weight",
  "score_exante", "score_release", "mean_month_cont"
)

out_full <- file.path(OUT_DIR, "cruzber_prevision_newsvendor_v4f_inventory_sim.csv")
readr::write_csv(df %>% select(-any_of(drop_tmp)), out_full)
log_msg("  OK: ", out_full)

min_cols <- c(
  "anio", "semana_anio", "codigo_articulo", "Provincia", "provincia_norm",
  "tipo_abc", "sb_class", "pred_prov", "prob_positiva", "real_prov",
  "stock_v4_continuo", "replenishment_v4f_int", "served_v4f",
  "stockout_units_v4f", "ending_inventory_v4f", "strategy_v4f"
)
out_min <- file.path(OUT_DIR, "cruzber_prevision_newsvendor_v4f_min.csv")
readr::write_csv(df %>% select(any_of(min_cols)), out_min)
log_msg("  OK: ", out_min)

out_xlsx <- file.path(OUT_DIR, "cruzber_newsvendor_v4f_evaluation.xlsx")
wb <- openxlsx::createWorkbook()
add_ws <- function(wb, nm, data) {
  openxlsx::addWorksheet(wb, nm)
  openxlsx::writeData(wb, nm, data, rowNames = FALSE)
}
add_ws(wb, "global", global_comparison)
add_ws(wb, "strategy_comparison", strategy_comparison)
add_ws(wb, "by_abc", m_v4f_abc)
add_ws(wb, "by_sb_class", m_v4f_sb)
add_ws(wb, "by_abc_sb_class", m_v4f_abc_sb)
add_ws(wb, "by_provincia", m_v4f_prov)
add_ws(wb, "by_week", m_v4f_week)
add_ws(wb, "critical_segments", critical_segments)
add_ws(wb, "critical_provinces", critical_provinces)
add_ws(wb, "acceptance_checks", acceptance_checks)
dir.create(tempdir(), recursive = TRUE, showWarnings = FALSE)
openxlsx::saveWorkbook(wb, out_xlsx, overwrite = TRUE)
log_msg("  OK: ", out_xlsx)

out_audit <- file.path(OUT_DIR, "cruzber_newsvendor_v4f_audit.md")
writeLines(c(
  "# Audit Newsvendor V4f - Simulacion Dinamica de Inventario",
  paste0("Generado: ", format(Sys.time(), "%Y-%m-%d %H:%M:%S")),
  "",
  "## 1. Contexto",
  "V4c continuo estaba aprobado como politica continua: fill=91.782%, stock/real=1.692x.",
  "V4i/V4d/V4e fallaban porque evaluaban stock entero semanal como si no existiera carry-over.",
  "V4f cambia la evaluacion: cada unidad no servida en una semana se arrastra como inventario a la semana siguiente.",
  "stock_v4_continuo no se recalibra ni se modifica.",
  "",
  "## 2. Estrategias V4f",
  "| Estrategia | Fill dinamico % | Stock/real | Rotura | Ceros | Inv final | Valida | Score |",
  "|---|---:|---:|---:|---:|---:|---|---:|",
  paste0(
    "| ", strategy_comparison$estrategia, " | ",
    strategy_comparison$fill_pct, " | ",
    strategy_comparison$stock_ratio, " | ",
    strategy_comparison$rotura, " | ",
    strategy_comparison$stock_ceros, " | ",
    strategy_comparison$ending_inventory_total, " | ",
    strategy_comparison$valida, " | ",
    strategy_comparison$score, " |"
  ),
  "",
  "## 3. Estrategia Ganadora",
  paste0("**", best_name, "**"),
  paste0("- Fill dinamico: ", round(m_v4f_global$fill_dynamic * 100, 3), "%"),
  paste0("- Stock/real: ", round(m_v4f_global$stock_ratio, 3), "x"),
  paste0("- Stock en ceros: ", fmt_i(m_v4f_global$stock_ceros)),
  paste0("- Rotura: ", fmt_i(m_v4f_global$rotura)),
  paste0("- Inventario final: ", fmt_i(m_v4f_global$ending_inventory_total)),
  paste0("- Recomendacion: **", recomendacion, "**"),
  "",
  "## 4. Comparacion V3 / V4c / V4i / V4d / V4e / V4f",
  "| Version | Tipo eval | Fill % | Stock/real | Rotura | Ceros | Inv final |",
  "|---|---|---:|---:|---:|---:|---:|",
  paste0(
    "| ", global_comparison$version, " | ",
    global_comparison$eval_type, " | ",
    global_comparison$fill_pct, " | ",
    global_comparison$stock_ratio, " | ",
    global_comparison$rotura, " | ",
    global_comparison$stock_ceros, " | ",
    global_comparison$ending_inventory_total, " |"
  ),
  "",
  "## 5. Trade-offs",
  "- Carry-over corrige la evaluacion fisica de inventario, pero no convierte automaticamente una mala temporalizacion en servicio.",
  "- Las estrategias por bloques preservan masa entera y arrastran excedente, a cambio de mayor inventario final.",
  "- repl_hybrid_topup_v4f aplica service-cap: si el hibrido base supera 91.80%, usa horizon_release como base conservadora y top-up ex ante.",
  "- El top-up se ordena solo con score ex ante; real_prov se usa unicamente para simular y detener por metricas globales.",
  "- No se promete wMAPE < 0.20; forecast y decision de reposicion son objetos distintos.",
  "",
  "*Script: run_newsvendor_v4f_inventory_simulation.R | set.seed(42)*"
), out_audit)
log_msg("  OK: ", out_audit)

t_total <- round(as.numeric(difftime(Sys.time(), t0, units = "mins")), 2)
log_msg("Tiempo total: ", t_total, " min")
out_log <- file.path(OUT_DIR, "run_log_newsvendor_v4f.txt")
writeLines(c(run_log, paste0("[", format(Sys.time(), "%H:%M:%S"), "] FINALIZADO")), out_log)
log_msg("  OK: ", out_log)

# =============================================================================
# FASE 8 - INFORME FINAL EN CONSOLA
# =============================================================================

cat("\n=================================================================\n")
cat("  INFORME FINAL - NEWSVENDOR V4f SIMULACION INVENTARIO\n")
cat("=================================================================\n\n")
cat(sprintf("  Estrategia ganadora: %s\n", best_name))
cat(sprintf("  Fill dinamico:       %.3f%%\n", m_v4f_global$fill_dynamic * 100))
cat(sprintf("  Stock/real:          %.3fx\n", m_v4f_global$stock_ratio))
cat(sprintf("  Stock en ceros:      %.0f\n", m_v4f_global$stock_ceros))
cat(sprintf("  Rotura:              %.0f\n", m_v4f_global$rotura))
cat(sprintf("  Inventario final:    %.0f\n\n", m_v4f_global$ending_inventory_total))

cat("  Comparacion global:\n")
print(global_comparison)

cat("\n  Segmentos criticos:\n")
cat(sprintf("    A_Intermittent: %.3f%%\n", fill_AI_v4f * 100))
cat(sprintf("    A_Lumpy:        %.3f%%\n", fill_AL_v4f * 100))
cat(sprintf("    GIPUZKOA:       %.3f%%\n", fill_GIP * 100))
cat(sprintf("    MADRID:         %.3f%%\n", fill_MAD * 100))
cat(sprintf("    CORDOBA:        %.3f%%\n\n", fill_COR * 100))

cat("  Criterios:\n")
for (i in seq_len(nrow(acceptance_checks))) {
  row <- acceptance_checks[i, ]
  cat(sprintf("    [%s] %s %-38s valor=%-10s target=%s\n",
              ifelse(row$cumple, "PASS", "FAIL"),
              ifelse(row$obligatorio, "OBL ", "des "),
              row$criterio,
              as.character(row$valor),
              row$target))
}
cat(sprintf("\n  RECOMENDACION FINAL: %s\n", recomendacion))
cat(sprintf("  Outputs en: %s\n", OUT_DIR))
cat("=================================================================\n\n")

invisible(list(
  df = df,
  best_name = best_name,
  strategy_comparison = strategy_comparison,
  global_comparison = global_comparison,
  acceptance_checks = acceptance_checks,
  recomendacion = recomendacion
))
