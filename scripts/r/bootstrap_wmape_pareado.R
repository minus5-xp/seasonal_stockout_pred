#!/usr/bin/env Rscript

suppressWarnings(options(stringsAsFactors = FALSE, scipen = 999))

print_help <- function() {
  cat(
"bootstrap_wmape_pareado.R

Bootstrap pareado para comparar delta de wMAPE entre un baseline y variantes.

Uso:
  Rscript bootstrap_wmape_pareado.R --input archivo.csv [opciones]
  Rscript bootstrap_wmape_pareado.R --write-template plantilla.csv

Opciones:
  --input PATH            CSV de entrada con filas emparejadas.
  --out-prefix PATH       Prefijo de salida. Si no se indica, se deriva de --input.
  --targets TEXT          Targets separados por coma. Por defecto: T0,T1,T2,T3,T4
  --baseline TEXT         Target baseline. Por defecto: T0
  --segment-col TEXT      Columna de segmento. Por defecto: segment
  --id-col TEXT           Columna identificadora opcional. Por defecto: row_id
  --actual-col TEXT       Columna real compartida si no hay reales por target. Por defecto: real
  --actual-prefix TEXT    Prefijo de reales por target. Por defecto: real_
  --pred-prefix TEXT      Prefijo de predicciones por target. Por defecto: pred_
  --n-boot INT            Numero de replicas bootstrap. Por defecto: 5000
  --seed INT              Semilla. Por defecto: 20260503
  --write-template PATH   Escribe un CSV de ejemplo y termina.
  --help                  Muestra esta ayuda.

Formato esperado del CSV:
  - Opcion A: real compartido
      row_id,segment,real,pred_T0,pred_T1,...
  - Opcion B: real por target
      row_id,segment,real_T0,pred_T0,real_T1,pred_T1,...

Salidas:
  - <out-prefix>_wmape_summary.csv
  - <out-prefix>_paired_bootstrap.csv
"
  )
}

parse_args <- function(args) {
  cfg <- list(
    input = NULL,
    out_prefix = NULL,
    targets = "T0,T1,T2,T3,T4",
    baseline = "T0",
    segment_col = "segment",
    id_col = "row_id",
    actual_col = "real",
    actual_prefix = "real_",
    pred_prefix = "pred_",
    n_boot = 5000L,
    seed = 20260503L,
    write_template = NULL
  )

  i <- 1L
  while (i <= length(args)) {
    key <- args[[i]]
    if (key == "--help") {
      print_help()
      quit(save = "no", status = 0)
    }
    if (!startsWith(key, "--")) {
      stop("Argumento no reconocido: ", key, call. = FALSE)
    }

    key_name <- sub("^--", "", key)
    if (grepl("=", key_name, fixed = TRUE)) {
      parts <- strsplit(key_name, "=", fixed = TRUE)[[1]]
      key_name <- parts[[1]]
      value <- paste(parts[-1], collapse = "=")
    } else {
      if (i == length(args)) {
        stop("Falta valor para ", key, call. = FALSE)
      }
      i <- i + 1L
      value <- args[[i]]
    }

    key_name <- gsub("-", "_", key_name, fixed = TRUE)

    if (!key_name %in% names(cfg)) {
      stop("Parametro no soportado: --", key_name, call. = FALSE)
    }
    cfg[[key_name]] <- value
    i <- i + 1L
  }

  cfg$n_boot <- as.integer(cfg$n_boot)
  cfg$seed <- as.integer(cfg$seed)
  cfg$targets <- trimws(strsplit(cfg$targets, ",", fixed = TRUE)[[1]])
  cfg
}

ensure_dir <- function(path) {
  dir_path <- dirname(path)
  if (!dir.exists(dir_path)) {
    dir.create(dir_path, recursive = TRUE, showWarnings = FALSE)
  }
}

write_template <- function(path) {
  example <- data.frame(
    row_id = 1:12,
    segment = c(rep("SE", 6), rep("IL", 6)),
    real_T0 = c(105, 98, 120, 115, 90, 88, 22, 18, 0, 14, 30, 12),
    pred_T0 = c(101, 95, 118, 110, 94, 85, 20, 17, 2, 12, 26, 10),
    real_T1 = c(108, 100, 124, 117, 91, 90, 25, 19, 0, 15, 31, 13),
    pred_T1 = c(103, 97, 121, 111, 97, 86, 22, 17, 2, 13, 27, 10),
    real_T2 = c(104, 97, 119, 114, 89, 87, 24, 19, 0, 15, 32, 13),
    pred_T2 = c(100, 94, 117, 109, 93, 84, 21, 16, 2, 12, 27, 10),
    real_T3 = c(100, 94, 114, 110, 86, 84, 24, 18, 0, 14, 31, 12),
    pred_T3 = c(99, 92, 113, 107, 92, 83, 20, 16, 2, 11, 26, 10),
    real_T4 = c(112, 104, 130, 123, 96, 94, 24, 18, 0, 15, 31, 13),
    pred_T4 = c(106, 99, 125, 116, 99, 89, 22, 18, 2, 13, 28, 11)
  )
  ensure_dir(path)
  write.csv(example, path, row.names = FALSE)
  cat("Plantilla escrita en:", normalizePath(path, winslash = "/", mustWork = FALSE), "\n")
}

safe_wmape <- function(actual, pred) {
  den <- sum(actual, na.rm = TRUE)
  if (!is.finite(den) || den <= 0) {
    return(NA_real_)
  }
  sum(abs(actual - pred), na.rm = TRUE) / den
}

safe_bias <- function(actual, pred) {
  den <- sum(actual, na.rm = TRUE)
  if (!is.finite(den) || den <= 0) {
    return(NA_real_)
  }
  sum(pred, na.rm = TRUE) / den
}

resolve_actual_col <- function(df_names, target, actual_col, actual_prefix) {
  variant_col <- paste0(actual_prefix, target)
  if (variant_col %in% df_names) {
    return(variant_col)
  }
  if (actual_col %in% df_names) {
    return(actual_col)
  }
  stop(
    "No se encontro columna real para ", target,
    ". Buscado: ", variant_col, " o ", actual_col,
    call. = FALSE
  )
}

resolve_pred_col <- function(df_names, target, pred_prefix) {
  pred_col <- paste0(pred_prefix, target)
  if (!pred_col %in% df_names) {
    stop("No se encontro columna de prediccion para ", target, ": ", pred_col, call. = FALSE)
  }
  pred_col
}

paired_bootstrap_delta <- function(actual_base, pred_base,
                                   actual_comp, pred_comp,
                                   n_boot, seed) {
  stopifnot(
    length(actual_base) == length(pred_base),
    length(actual_comp) == length(pred_comp),
    length(actual_base) == length(actual_comp)
  )

  err_base <- abs(actual_base - pred_base)
  err_comp <- abs(actual_comp - pred_comp)

  delta_obs <- safe_wmape(actual_comp, pred_comp) - safe_wmape(actual_base, pred_base)
  wmape_base_obs <- safe_wmape(actual_base, pred_base)
  wmape_comp_obs <- safe_wmape(actual_comp, pred_comp)

  n <- length(actual_base)
  delta_boot <- rep(NA_real_, n_boot)

  set.seed(seed)
  filled <- 0L
  attempts <- 0L
  max_attempts <- n_boot * 20L

  while (filled < n_boot && attempts < max_attempts) {
    attempts <- attempts + 1L
    idx <- sample.int(n, size = n, replace = TRUE)

    den_base <- sum(actual_base[idx], na.rm = TRUE)
    den_comp <- sum(actual_comp[idx], na.rm = TRUE)

    if (!is.finite(den_base) || !is.finite(den_comp) || den_base <= 0 || den_comp <= 0) {
      next
    }

    filled <- filled + 1L
    delta_boot[[filled]] <- sum(err_comp[idx], na.rm = TRUE) / den_comp -
      sum(err_base[idx], na.rm = TRUE) / den_base
  }

  if (filled == 0L) {
    stop("Bootstrap invalido: no se pudo generar ninguna replica con denominador positivo.", call. = FALSE)
  }

  if (filled < n_boot) {
    delta_boot <- delta_boot[seq_len(filled)]
    warning("Solo se generaron ", filled, " replicas bootstrap validas.")
  }

  ci <- as.numeric(quantile(delta_boot, probs = c(0.025, 0.975), na.rm = TRUE, names = FALSE))
  p_less_equal <- mean(delta_boot <= 0, na.rm = TRUE)
  p_greater_equal <- mean(delta_boot >= 0, na.rm = TRUE)
  p_two_sided <- min(1, 2 * min(p_less_equal, p_greater_equal))

  list(
    n_boot_valid = length(delta_boot),
    wmape_base = wmape_base_obs,
    wmape_comp = wmape_comp_obs,
    delta_obs = delta_obs,
    delta_mean_boot = mean(delta_boot, na.rm = TRUE),
    ci_low = ci[[1]],
    ci_high = ci[[2]],
    p_two_sided = p_two_sided,
    p_comp_better = p_less_equal,
    p_comp_worse = p_greater_equal
  )
}

segment_levels <- function(df, segment_col) {
  if (!segment_col %in% names(df)) {
    return("ALL")
  }
  segs <- unique(as.character(df[[segment_col]]))
  segs <- segs[!is.na(segs) & nzchar(segs)]
  c("ALL", sort(segs))
}

subset_segment <- function(df, segment_col, segment_value) {
  if (segment_value == "ALL" || !segment_col %in% names(df)) {
    return(df)
  }
  df[as.character(df[[segment_col]]) == segment_value, , drop = FALSE]
}

args <- parse_args(commandArgs(trailingOnly = TRUE))

if (!is.null(args$write_template)) {
  write_template(args$write_template)
  quit(save = "no", status = 0)
}

if (is.null(args$input)) {
  print_help()
  stop("Debes indicar --input o --write-template.", call. = FALSE)
}

if (!file.exists(args$input)) {
  stop("No existe el archivo de entrada: ", args$input, call. = FALSE)
}

if (is.null(args$out_prefix)) {
  input_no_ext <- sub("\\.[^.]+$", "", args$input)
  args$out_prefix <- paste0(input_no_ext, "_bootstrap_wmape")
}

df <- read.csv(args$input, check.names = FALSE)

if (nrow(df) == 0L) {
  stop("El archivo de entrada no contiene filas.", call. = FALSE)
}

summary_rows <- list()
comparison_rows <- list()

segments <- segment_levels(df, args$segment_col)

for (segment_value in segments) {
  df_seg <- subset_segment(df, args$segment_col, segment_value)
  if (nrow(df_seg) == 0L) {
    next
  }

  for (target in args$targets) {
    actual_col <- resolve_actual_col(names(df_seg), target, args$actual_col, args$actual_prefix)
    pred_col <- resolve_pred_col(names(df_seg), target, args$pred_prefix)
    keep <- is.finite(df_seg[[actual_col]]) & is.finite(df_seg[[pred_col]])
    dft <- df_seg[keep, , drop = FALSE]
    if (nrow(dft) == 0L) {
      next
    }

    summary_rows[[length(summary_rows) + 1L]] <- data.frame(
      segment = segment_value,
      target = target,
      n_rows = nrow(dft),
      actual_col = actual_col,
      pred_col = pred_col,
      sum_real = sum(dft[[actual_col]], na.rm = TRUE),
      sum_pred = sum(dft[[pred_col]], na.rm = TRUE),
      sum_abs_error = sum(abs(dft[[actual_col]] - dft[[pred_col]]), na.rm = TRUE),
      wmape = safe_wmape(dft[[actual_col]], dft[[pred_col]]),
      bias = safe_bias(dft[[actual_col]], dft[[pred_col]])
    )
  }

  for (target in args$targets) {
    if (identical(target, args$baseline)) {
      next
    }

    actual_base_col <- resolve_actual_col(names(df_seg), args$baseline, args$actual_col, args$actual_prefix)
    pred_base_col <- resolve_pred_col(names(df_seg), args$baseline, args$pred_prefix)
    actual_comp_col <- resolve_actual_col(names(df_seg), target, args$actual_col, args$actual_prefix)
    pred_comp_col <- resolve_pred_col(names(df_seg), target, args$pred_prefix)

    keep <- is.finite(df_seg[[actual_base_col]]) &
      is.finite(df_seg[[pred_base_col]]) &
      is.finite(df_seg[[actual_comp_col]]) &
      is.finite(df_seg[[pred_comp_col]])

    dft <- df_seg[keep, , drop = FALSE]
    if (nrow(dft) == 0L) {
      next
    }

    boot <- paired_bootstrap_delta(
      actual_base = dft[[actual_base_col]],
      pred_base = dft[[pred_base_col]],
      actual_comp = dft[[actual_comp_col]],
      pred_comp = dft[[pred_comp_col]],
      n_boot = args$n_boot,
      seed = args$seed + match(segment_value, segments) + match(target, args$targets) * 1000L
    )

    comparison_rows[[length(comparison_rows) + 1L]] <- data.frame(
      segment = segment_value,
      baseline = args$baseline,
      comparator = target,
      n_rows = nrow(dft),
      actual_base_col = actual_base_col,
      pred_base_col = pred_base_col,
      actual_comp_col = actual_comp_col,
      pred_comp_col = pred_comp_col,
      n_boot = boot$n_boot_valid,
      wmape_baseline = boot$wmape_base,
      wmape_comparator = boot$wmape_comp,
      delta_wmape_obs = boot$delta_obs,
      delta_wmape_boot_mean = boot$delta_mean_boot,
      ci95_low = boot$ci_low,
      ci95_high = boot$ci_high,
      p_two_sided = boot$p_two_sided,
      p_comp_better = boot$p_comp_better,
      p_comp_worse = boot$p_comp_worse,
      comparator_better = !is.na(boot$ci_high) && boot$ci_high < 0,
      comparator_worse = !is.na(boot$ci_low) && boot$ci_low > 0
    )
  }
}

if (length(summary_rows) == 0L) {
  stop("No se pudieron calcular metricas. Revisa columnas reales y de prediccion.", call. = FALSE)
}

summary_df <- do.call(rbind, summary_rows)
comparison_df <- if (length(comparison_rows) > 0L) {
  do.call(rbind, comparison_rows)
} else {
  data.frame()
}

summary_path <- paste0(args$out_prefix, "_wmape_summary.csv")
comparison_path <- paste0(args$out_prefix, "_paired_bootstrap.csv")

ensure_dir(summary_path)
write.csv(summary_df, summary_path, row.names = FALSE)
write.csv(comparison_df, comparison_path, row.names = FALSE)

cat("Resumen wMAPE escrito en:", normalizePath(summary_path, winslash = "/", mustWork = FALSE), "\n")
cat("Bootstrap pareado escrito en:", normalizePath(comparison_path, winslash = "/", mustWork = FALSE), "\n")

cat("\n=== Resumen wMAPE ===\n")
print(summary_df, row.names = FALSE)

if (nrow(comparison_df) > 0L) {
  cat("\n=== Comparativa bootstrap pareado ===\n")
  print(comparison_df, row.names = FALSE)
}
