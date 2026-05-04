# =============================================================================
# Iteracion 30: Script Unificado -- Mejores practicas NB25.R + NB28 Python
# Dense Panel 12W * Syntetos-Boylan * CatBoost/LightGBM * Walk-Forward
#
# MEJORAS RESPECTO A NB25.R:
#   [FIX-1]  Target Encoding dinamico por fold (elimina leakage global)
#   [FIX-2]  Capping P99.5 calculado solo sobre train_df por fold
#   [NEW-1]  add_tsls_features(): tsls + sale_freq_12w (demanda intermitente)
#   [NEW-2]  add_lifecycle_features(): edad producto + lifecycle_ratio
#   [NEW-3]  Busqueda bayesiana (rBayesianOptimization) con warm-start LightGBM
#   [NEW-4]  Walk-forward semanal 2024 para validacion honesta
#   [NEW-5]  Exportacion enriquecida: sb_reliability, HHI provincia, top1_prov
#
# CONSERVADO DE NB25.R:
#   * MIN_HORIZON = 4 (gap operativo S&OP realista)
#   * Folds anuales 2022/2023/2024
#   * CatBoost primario (binding R nativo)
#   * LightGBM fase exploratoria Hurdle
#   * Graficos ggplot2 de auditoria
# =============================================================================

# ---- 0. LIBRERIAS -----------------------------------------------------------
suppressPackageStartupMessages({
  library(tidyverse)
  library(readxl)
  library(lubridate)
  library(ISOweek)
  library(slider)
  library(catboost)
  library(lightgbm)
  library(rBayesianOptimization)
})

SEED <- 42L
set.seed(SEED)

DATA_DIR <- "../CRUZBER/Dataset/Datos dataset ISDI CRUZBER SAU"

# ---- 1. CONSTANTES ----------------------------------------------------------
QUICK_MODE   <- FALSE
ANIOS_TRAIN  <- c(2021L, 2022L, 2023L)
ANIO_TEST    <- 2024L
MIN_HORIZON  <- 4L
N_TRIALS_R   <- if (QUICK_MODE) 8L  else 25L
N_TRIALS_LGB <- if (QUICK_MODE) 5L  else 15L
N_TRIALS_H   <- if (QUICK_MODE) 8L  else 35L

FESTIVOS_FIJOS <- list(
  c(1,1), c(1,6), c(5,1), c(8,15),
  c(10,12), c(11,1), c(12,6), c(12,8), c(12,25)
)
VIERNES_SANTOS <- c(
  "2020"="2020-04-10","2021"="2021-04-02","2022"="2022-04-15",
  "2023"="2023-04-07","2024"="2024-03-29","2025"="2025-04-18"
)
MESES_ES <- c(enero=1,febrero=2,marzo=3,abril=4,mayo=5,junio=6,
              julio=7,agosto=8,septiembre=9,octubre=10,noviembre=11,diciembre=12)
REGION_MAP <- c(
  "GALICIA"="Noroeste",
  "ASTURIAS"="Norte","CANTABRIA"="Norte",
  "PAIS VASCO"="Norte","NAVARRA"="Norte","LA RIOJA"="Norte",
  "ARAGON"="Noreste","CATALUNA"="Noreste","ISLAS BALEARES"="Noreste",
  "COMUNIDAD DE MADRID"="Centro",
  "CASTILLA Y LEON"="Centro","CASTILLA-LA MANCHA"="Centro","EXTREMADURA"="Centro",
  "COMUNIDAD VALENCIANA"="Este","REGION DE MURCIA"="Sur",
  "ANDALUCIA"="Sur",
  "CANARIAS"="Canarias","CEUTA"="Sur","MELILLA"="Sur"
)
message("Configuracion cargada.")

# ---- 2. FUNCIONES AUXILIARES ------------------------------------------------
parse_fecha_es <- function(s) {
  tryCatch({
    parts  <- str_split(s, ", ", n = 2)[[1]]
    tokens <- str_split(str_trim(parts[2]), "\\s+")[[1]]
    day  <- as.integer(tokens[1])
    mes  <- MESES_ES[tolower(tokens[3])]
    anio <- as.integer(tokens[5])
    lubridate::ymd(sprintf("%04d-%02d-%02d", anio, mes, day))
  }, error = function(e) NA_Date_)
}

wmape <- function(y_true, y_pred) {
  mask <- y_true > 0
  if (sum(mask) == 0) return(NA_real_)
  sum(abs(y_true[mask] - y_pred[mask])) / sum(y_true[mask]) * 100
}
mae_metric <- function(y_true, y_pred) mean(abs(y_true - y_pred))
r2_metric  <- function(y_true, y_pred) {
  ss_res <- sum((y_true - y_pred)^2)
  ss_tot <- sum((y_true - mean(y_true))^2)
  if (ss_tot == 0) return(0)
  1 - ss_res / ss_tot
}
print_metrics <- function(label, y_true, y_pred, df_te = NULL) {
  message(sprintf("  %-40s  N=%6d  MAE=%.3f  WMAPE=%.1f%%  R2=%.3f  BIAS=%.1f",
                  label, length(y_true),
                  mae_metric(y_true, y_pred), wmape(y_true, y_pred),
                  r2_metric(y_true, y_pred),  mean(y_pred - y_true)))
  if (!is.null(df_te)) {
    for (cls in c("A","B","C")) {
      idx <- df_te$tipo_abc == cls
      if (sum(idx)>0) message(sprintf("     Clase %s  N=%4d  WMAPE=%.1f%%",
                                      cls,sum(idx),wmape(y_true[idx],y_pred[idx])))
    }
    for (cls in c("Smooth","Erratic","Intermittent","Lumpy")) {
      idx <- df_te$sb_class == cls
      if (sum(idx)>0) message(sprintf("     SB %-13s  N=%4d  WMAPE=%.1f%%",
                                      cls,sum(idx),wmape(y_true[idx],y_pred[idx])))
    }
  }
}
message("Funciones auxiliares definidas.")

# ---- 3. CARGA DE FUENTES ----------------------------------------------------
message("Cargando fuentes...")
df_raw <- read_excel(file.path(DATA_DIR, "LineasAlbaranCliente.xlsx"))
df_raw <- df_raw |>
  mutate(
    fecha           = map_vec(FechaAlbaran, parse_fecha_es, .ptype = as.Date(NA)),
    anio            = isoyear(fecha),
    semana_anio     = isoweek(fecha),
    codigo_articulo = str_trim(as.character(CodigoArticulo)),
    Unidades        = suppressWarnings(as.numeric(Unidades))      |> replace_na(0),
    ImporteNeto     = suppressWarnings(as.numeric(ImporteNeto))   |> replace_na(0),
    pct_desc2       = suppressWarnings(as.numeric(`%Descuento2`)) |> replace_na(0)
  ) |> drop_na(fecha)

df_art <- read_excel(file.path(DATA_DIR, "MaestroArticulos.xlsx"), col_types = "text") |>
  select(CodigoArticulo, AgrupacionListado, TipoABC, AreaCompetenciaLc,
         FactorCrecimiento, PrevisionVentasAA, TarifaNacional, PrecioVenta) |>
  mutate(
    codigo_articulo     = str_trim(CodigoArticulo),
    tipo_abc            = str_sub(str_to_upper(replace_na(TipoABC,"C")), 1, 1),
    factor_crecimiento  = suppressWarnings(as.numeric(FactorCrecimiento))  |> replace_na(1.0),
    prevision_ventas_aa = suppressWarnings(as.numeric(PrevisionVentasAA))  |> replace_na(0.0),
    tarifa_nacional     = suppressWarnings(as.numeric(TarifaNacional))     |> replace_na(0.0),
    precio_unit         = suppressWarnings(as.numeric(PrecioVenta))        |> replace_na(0.0),
    AgrupacionListado   = suppressWarnings(as.numeric(AgrupacionListado))
  )
df_fam <- read_excel(file.path(DATA_DIR, "Familias Articulos.xlsx"), col_types = "text") |>
  select(AgrupacionListado, CR_GamaProducto, CR_TipoProducto, CR_MaterialAgrupacion) |>
  drop_na(AgrupacionListado) |>
  mutate(AgrupacionListado = suppressWarnings(as.numeric(AgrupacionListado))) |>
  drop_na(AgrupacionListado)
df_cli  <- read_excel(file.path(DATA_DIR, "MaestroClientes.xlsx"), col_types = "text") |>
  select(CodigoCliente, Municipio, Provincia, CodigoNacion) |>
  mutate(CodigoNacion = suppressWarnings(as.integer(CodigoNacion)))
df_prov <- read_excel(file.path(DATA_DIR, "MaestroProvincias.xlsx"), col_types = "text") |>
  select(Provincia, Autonomia, CodigoNacion) |>
  mutate(CodigoNacion = suppressWarnings(as.integer(CodigoNacion)),
         region = coalesce(REGION_MAP[Autonomia], "Otros"))
df_can  <- read_excel(file.path(DATA_DIR, "Agrupacion Canales venta.xlsx")) |>
  select(canal_raw = Canal,
         agrupacion_canal = `Agrupación Canal`) |>
  drop_na(canal_raw)
df_clima <- read_csv(file.path("..","Datasets","clima_semanal_openmeteo.csv"), show_col_types=FALSE)
names(df_clima) <- str_to_lower(names(df_clima))
df_clima_nac <- df_clima |>
  group_by(anio=year, semana_anio=semana) |>
  summarise(temp_media=mean(temp_media,na.rm=TRUE),precip_mm=mean(precip_mm,na.rm=TRUE),
            viento_max=mean(viento_max,na.rm=TRUE),.groups="drop")
df_cicl <- read_excel(file.path("..","Datasets","Calendario Ciclismo 22_24.xlsx"))
names(df_cicl) <- str_trim(names(df_cicl))
df_cicl_agg <- df_cicl |>
  rename(anio=`Año Prueba`,semana_anio=Semana,duracion=`Duración(Dias)`) |>
  group_by(anio,semana_anio) |>
  summarise(num_pruebas_cicl=n(),dias_pruebas_cicl=sum(duracion,na.rm=TRUE),
            hubo_prueba_cicl=1L,.groups="drop")
message("Todas las fuentes cargadas.")

# ---- 4. MERGE Y FILTROS -----------------------------------------------------

# Vector de provincias espanolas validas (CodigoNacion 108 en MaestroProvincias)
PROVINCIAS_ES <- df_prov |>
  filter(CodigoNacion == 108L) |>
  pull(Provincia) |>
  unique()

df_raw <- df_raw |>
  mutate(SerieAlbaran  = as.character(SerieAlbaran),
         CodigoCliente = sprintf("%06d", as.integer(CodigoCliente))) |>
  left_join(df_can, by = c("SerieAlbaran" = "canal_raw")) |>
  mutate(agrupacion_canal=replace_na(agrupacion_canal,"Otros")) |>
  left_join(select(df_cli,CodigoCliente,Municipio,Provincia,CodigoNacion),by="CodigoCliente") |>
  left_join(distinct(df_prov,Provincia,.keep_all=TRUE)|>select(Provincia,Autonomia,region),
            by="Provincia")
df_es    <- filter(df_raw, CodigoNacion == 108L)
df_fleet <- filter(df_es,  agrupacion_canal == "FLEET", anio >= 2021L)
df_nac   <- filter(df_es,  agrupacion_canal != "FLEET", anio >= 2021L) |>
  # Solo provincias peninsulares + Baleares + Canarias + Ceuta + Melilla
  filter(Provincia %in% PROVINCIAS_ES | is.na(Provincia))

message(sprintf("Provincias en panel: %d | %s",
                n_distinct(na.omit(df_nac$Provincia)),
                paste(sort(unique(na.omit(df_nac$Provincia))), collapse=", ")))

# ---- 5. DIAS LABORABLES -----------------------------------------------------
get_festivos_espana <- function(anios) {
  festivos <- as.Date(character(0))
  for (y in anios) {
    fijos    <- map(FESTIVOS_FIJOS, ~lubridate::ymd(sprintf("%04d-%02d-%02d",y,.x[1],.x[2])))
    vs       <- lubridate::ymd(VIERNES_SANTOS[as.character(y)])
    festivos <- c(festivos, unlist(fijos), vs)
  }
  as.Date(festivos, origin="1970-01-01")
}
dias_laborables_iso <- function(year, week, festivos_vec) {
  tryCatch({
    lunes <- ISOweek::ISOweek2date(sprintf("%04d-W%02d-1", year, week))
    sum(!(lunes+0:4) %in% festivos_vec)
  }, error=function(e) 5L)
}
festivos_vec   <- get_festivos_espana(2021:2025)
semanas_unicas <- df_nac |> distinct(anio,semana_anio) |> rowwise() |>
  mutate(dias_laborables_semana=dias_laborables_iso(anio,semana_anio,festivos_vec)) |>
  ungroup()

# ---- 6. AGREGACION + DENSE PANEL -------------------------------------------
wmean_desc_fn <- function(unidades,pct){w<-abs(unidades);d<-sum(w);if(d==0)0 else sum(pct*w)/d}
df_agg <- df_nac |>
  group_by(anio,semana_anio,codigo_articulo) |>
  summarise(unidades=sum(Unidades,na.rm=TRUE),importe_neto=sum(ImporteNeto,na.rm=TRUE),
            por_descuento2=wmean_desc_fn(Unidades,pct_desc2),.groups="drop") |>
  mutate(unidades=pmax(unidades,0))
dense_grid <- crossing(select(semanas_unicas,anio,semana_anio),distinct(df_nac,codigo_articulo))
df_agg <- dense_grid |>
  left_join(df_agg,by=c("anio","semana_anio","codigo_articulo")) |>
  mutate(across(c(unidades,importe_neto,por_descuento2),~replace_na(.,0))) |>
  left_join(semanas_unicas,by=c("anio","semana_anio")) |>
  left_join(df_clima_nac,  by=c("anio","semana_anio")) |>
  left_join(df_cicl_agg,   by=c("anio","semana_anio")) |>
  mutate(num_pruebas_cicl =replace_na(as.integer(num_pruebas_cicl),0L),
         dias_pruebas_cicl=replace_na(dias_pruebas_cicl,0),
         hubo_prueba_cicl =replace_na(as.integer(hubo_prueba_cicl),0L)) |>
  arrange(codigo_articulo,anio,semana_anio)
message(sprintf("Panel Dense: %s filas | %s SKUs",
                format(nrow(df_agg),big.mark=","), n_distinct(df_agg$codigo_articulo)))

# ---- 7. FEATURE ENGINEERING -------------------------------------------------
roll_shifted_mean <- function(x,h,w){
  slider::slide_dbl(dplyr::lag(x,h),mean,.before=w-1L,.complete=FALSE,na.rm=TRUE)
}
roll_shifted_sd <- function(x,h,w){
  slider::slide_dbl(dplyr::lag(x,h),
    ~if(sum(!is.na(.x))<2L)0 else sd(.x,na.rm=TRUE),.before=w-1L,.complete=FALSE)
}
ewm_shifted <- function(x,h,span){
  x_sh <- dplyr::lag(x,h); alpha <- 2/(span+1)
  out  <- numeric(length(x_sh))
  out[1] <- if(is.na(x_sh[1]))0 else x_sh[1]
  for(i in seq_along(x_sh)[-1]){
    xi <- x_sh[i]
    if(is.na(xi)) out[i] <- out[i-1] else out[i] <- (1-alpha)*out[i-1]+alpha*xi
  }; out
}

add_time_features <- function(df) {
  df |> mutate(
    mes=pmin(pmax((semana_anio-1L)%/%4L+1L,1L),12L),
    trimestre=(mes-1L)%/%3L+1L, semana_del_mes=(semana_anio-1L)%%4L+1L,
    es_fin_mes=as.integer(semana_del_mes==4L),
    sem_sin=sin(2*pi*semana_anio/52.18), sem_cos=cos(2*pi*semana_anio/52.18),
    temporada_alta=as.integer(semana_anio %in% 14:39)
  )
}

add_lag_rolling_features <- function(df,h=MIN_HORIZON) {
  df |> group_by(codigo_articulo) |>
    mutate(
      !!paste0("lag_",h,"w")    := dplyr::lag(unidades,h),
      !!paste0("lag_",h+4L,"w") := dplyr::lag(unidades,h+4L),
      !!paste0("lag_",h+8L,"w") := dplyr::lag(unidades,h+8L),
      lag_52w=dplyr::lag(unidades,52L),
      roll_4w=roll_shifted_mean(unidades,h,4L), roll_8w=roll_shifted_mean(unidades,h,8L),
      roll_12w=roll_shifted_mean(unidades,h,12L),
      roll_std_8w=roll_shifted_sd(unidades,h,8L), roll_std_12w=roll_shifted_sd(unidades,h,12L),
      ewm_4w=ewm_shifted(unidades,h,4L),ewm_8w=ewm_shifted(unidades,h,8L),
      ewm_12w=ewm_shifted(unidades,h,12L),
      .rc=roll_shifted_mean(unidades,h,4L),.ra=roll_shifted_mean(unidades,h,8L),
      .rp=.ra-.rc,
      tendencia_4v4=pmin(pmax(replace_na(.rc/if_else(.rp==0,NA_real_,.rp),1.0),0.1),10.0),
      .l52=dplyr::lag(unidades,pmax(52L,h)),
      ratio_yoy=pmin(replace_na(dplyr::lag(unidades,h)/(.l52+0.1),0),20.0)
    ) |> select(-starts_with(".")) |> ungroup()
}

# [NEW-1] TSLS: tiempo desde ultima venta y frecuencia reciente
add_tsls_features <- function(df, h=MIN_HORIZON) {
  df |> group_by(codigo_articulo) |>
    arrange(anio,semana_anio,.by_group=TRUE) |>
    mutate(
      .vl=replace_na(dplyr::lag(unidades,h)>0,FALSE),
      tsls={
        n<-length(.vl); res<-integer(n); cnt<-0L
        for(i in seq_len(n)){if(.vl[i])cnt<-0L else cnt<-cnt+1L; res[i]<-cnt}; res
      },
      sale_freq_12w=roll_shifted_mean(as.numeric(unidades>0),h,12L)
    ) |> select(-starts_with(".")) |> ungroup()
}

# [NEW-2] Lifecycle: edad del producto y ratio de obsolescencia
add_lifecycle_features <- function(df, h=MIN_HORIZON) {
  pv <- df |> filter(unidades>0) |> group_by(codigo_articulo) |>
    summarise(psn=min(anio*53L+semana_anio),.groups="drop")
  df |> left_join(pv,by="codigo_articulo") |>
    mutate(sn=anio*53L+semana_anio,
           producto_edad_semanas=pmax(sn-coalesce(psn,sn),0L)) |>
    group_by(codigo_articulo) |>
    arrange(anio,semana_anio,.by_group=TRUE) |>
    mutate(
      .rr=roll_shifted_mean(unidades,h,12L), .ro=roll_shifted_mean(unidades,h,52L),
      lifecycle_ratio=pmin(replace_na(.rr/(.ro+0.01),1.0),10.0)
    ) |> select(-starts_with("."),-sn,-psn) |> ungroup()
}

df_agg <- df_agg |>
  add_time_features() |>
  add_lag_rolling_features(h=MIN_HORIZON) |>
  add_tsls_features(h=MIN_HORIZON) |>
  add_lifecycle_features(h=MIN_HORIZON)
message(sprintf("Feature engineering: %d columnas", ncol(df_agg)))

# ---- 8. ATRIBUTOS DE PRODUCTO -----------------------------------------------
df_art_full <- df_art |> left_join(df_fam,by="AgrupacionListado") |>
  mutate(across(c(CR_GamaProducto,CR_TipoProducto,CR_MaterialAgrupacion),
                ~replace_na(as.character(.),"DESCONOCIDO")),
         AreaCompetenciaLc=replace_na(as.character(AreaCompetenciaLc),"SIN_AREA"))
art_attrs <- df_art_full |>
  select(codigo_articulo,tipo_abc,factor_crecimiento,prevision_ventas_aa,
         tarifa_nacional,precio_unit,AreaCompetenciaLc,
         CR_GamaProducto,CR_TipoProducto,CR_MaterialAgrupacion) |>
  distinct(codigo_articulo,.keep_all=TRUE)
df_agg <- df_agg |> left_join(art_attrs,by="codigo_articulo") |>
  mutate(tipo_abc=replace_na(tipo_abc,"C"),
         factor_crecimiento=replace_na(factor_crecimiento,1.0),
         prevision_ventas_aa=replace_na(prevision_ventas_aa,0.0),
         tarifa_nacional=replace_na(tarifa_nacional,0.0),
         precio_unit=replace_na(precio_unit,0.0),
         across(c(AreaCompetenciaLc,CR_GamaProducto,CR_TipoProducto,CR_MaterialAgrupacion),
                ~replace_na(as.character(.),"DESCONOCIDO")),
         prevision_semanal=prevision_ventas_aa/52.0)

# ---- 9. TARGET --------------------------------------------------------------
df_agg <- df_agg |>
  arrange(codigo_articulo,anio,semana_anio) |>
  group_by(codigo_articulo) |>
  mutate(target_12w_ahead=reduce(1:12,
    function(acc,k) acc+lead(unidades,k,default=NA_real_),.init=rep(0,n()))) |>
  ungroup() |> drop_na(target_12w_ahead)
message(sprintf("Filas validas: %s", format(nrow(df_agg),big.mark=",")))

# ---- 10. SYNTETOS-BOYLAN ----------------------------------------------------
target_col   <- "target_12w_ahead"
train_subset <- filter(df_agg, anio < 2024L)
demand_stats <- train_subset |> filter(unidades>0) |>
  group_by(codigo_articulo) |>
  summarise(mean_demand=mean(unidades),std_demand=sd(unidades),count_demand=n(),.groups="drop") |>
  mutate(CV2=replace_na((std_demand/mean_demand)^2,0)) |>
  left_join(count(train_subset,codigo_articulo,name="total_periods"),by="codigo_articulo") |>
  mutate(ADI=total_periods/count_demand,
         sb_class=case_when(is.na(ADI)|is.infinite(ADI)~"Lumpy",
                            ADI<1.32&CV2<0.49~"Smooth",ADI<1.32&CV2>=0.49~"Erratic",
                            ADI>=1.32&CV2<0.49~"Intermittent",TRUE~"Lumpy"))

# [NEW-5] sb_reliability
sb_reliability <- train_subset |>
  left_join(select(demand_stats,codigo_articulo,sb_class),by="codigo_articulo") |>
  filter(!is.na(sb_class)) |> group_by(codigo_articulo) |>
  summarise(sb_reliability=n_distinct(sb_class)==1L,.groups="drop")

df_agg <- df_agg |>
  left_join(select(demand_stats,codigo_articulo,sb_class,ADI,CV2),by="codigo_articulo") |>
  left_join(sb_reliability,by="codigo_articulo") |>
  mutate(sb_class=replace_na(sb_class,"Lumpy"),sb_reliability=replace_na(sb_reliability,FALSE))
message("Distribucion Syntetos-Boylan:")
print(df_agg |> distinct(codigo_articulo,sb_class) |> count(sb_class))

# ---- 11. FEATURES Y PARTICION -----------------------------------------------
FEATS_NUM <- intersect(c(
  "semana_anio","anio","mes","trimestre","semana_del_mes","es_fin_mes",
  "sem_sin","sem_cos","temporada_alta","dias_laborables_semana",
  paste0("lag_",MIN_HORIZON,"w"), paste0("lag_",MIN_HORIZON+4L,"w"),
  paste0("lag_",MIN_HORIZON+8L,"w"), "lag_52w",
  "roll_4w","roll_8w","roll_12w","roll_std_8w","roll_std_12w",
  "ewm_4w","ewm_8w","ewm_12w","tendencia_4v4","ratio_yoy",
  "por_descuento2","precio_unit","prevision_semanal","factor_crecimiento","tarifa_nacional",
  "temp_media","precip_mm","viento_max","num_pruebas_cicl","dias_pruebas_cicl","hubo_prueba_cicl",
  "tsls","sale_freq_12w","producto_edad_semanas","lifecycle_ratio"
), names(df_agg))
FEATS_CAT <- intersect(c("CR_GamaProducto","CR_TipoProducto","CR_MaterialAgrupacion","AreaCompetenciaLc"),
                       names(df_agg))
message(sprintf("Features base: %d numericos + %d categoricos", length(FEATS_NUM), length(FEATS_CAT)))

df_reg <- filter(df_agg, sb_class %in% c("Smooth","Erratic"))
df_hrd <- filter(df_agg, sb_class %in% c("Intermittent","Lumpy"))

# ---- 12. FOLDS CON LEAKAGE CORREGIDO [FIX-1] + [FIX-2] ---------------------
generar_folds_tss <- function(df, feats_num_base, feats_cat,
                               target="target_12w_ahead",
                               apply_cap=FALSE,
                               cap_classes=c("Intermittent","Lumpy"),
                               te_cols=c("codigo_articulo","CR_GamaProducto","AreaCompetenciaLc"),
                               smooth_te=30) {
  df <- df |>
    mutate(across(all_of(feats_cat), ~factor(replace_na(as.character(.),"NaN"))),
           period_id=paste0(anio,"_",str_pad(semana_anio,2,pad="0")))
  folds <- list()
  for (yr in c(2022L,2023L,2024L)) {
    train_df <- filter(df, anio < yr)
    test_df  <- filter(df, anio == yr)

    # [FIX-1] Target Encoding dinamico -- solo train_df
    te_names <- character(0)
    gm_te    <- mean(train_df[[target]], na.rm=TRUE)
    for (sc in te_cols) {
      if (!sc %in% names(train_df)) next
      tc   <- paste0("te_",sc)
      stat <- train_df |> group_by(.data[[sc]]) |>
        summarise(mv=mean(.data[[target]],na.rm=TRUE),cnt=n(),.groups="drop") |>
        mutate(te=(mv*cnt+gm_te*smooth_te)/(cnt+smooth_te))
      mp <- setNames(stat$te, stat[[sc]])
      train_df[[tc]] <- coalesce(mp[train_df[[sc]]], gm_te)
      test_df[[tc]]  <- coalesce(mp[test_df[[sc]]],  gm_te)
      te_names       <- c(te_names, tc)
    }

    faf  <- intersect(c(feats_num_base,te_names,feats_cat), names(train_df))
    fnf  <- intersect(c(feats_num_base,te_names),            names(train_df))

    # Imputacion medianas -- solo train_df
    meds <- train_df |> summarise(across(all_of(fnf), ~median(.x,na.rm=TRUE)))
    for (col in fnf) {
      med <- meds[[col]]; if(is.na(med)) med <- 0
      train_df[[col]] <- replace_na(train_df[[col]], med)
      test_df[[col]]  <- replace_na(test_df[[col]],  med)
    }

    # [FIX-2] Capping P99.5 -- solo train_df; test_df intacto
    if (apply_cap) {
      for (cls in cap_classes) {
        msk <- train_df$sb_class==cls & train_df[[target]]>0
        if (sum(msk)>10) {
          cv <- quantile(train_df[[target]][msk],0.995,na.rm=TRUE)
          train_df[[target]] <- if_else(train_df$sb_class==cls, pmin(train_df[[target]],cv), train_df[[target]])
          message(sprintf("   [Cap] %s anho %d: P99.5=%.0f (train-only)",cls,yr,cv))
        }
      }
    }

    folds <- c(folds, list(list(year=yr,feats=faf,feats_cat=feats_cat,
                                X_tr=train_df[faf],y_tr=train_df[[target]],
                                X_te=test_df[faf], y_te=test_df[[target]],
                                train_df=train_df, test_df=test_df)))
  }
  folds
}

# ---- 13. BLOQUE A: SMOOTH/ERRATIC + BUSQUEDA BAYESIANA [NEW-3] --------------
message("\n---- BLOQUE A: SMOOTH/ERRATIC ------------------------------------------")
folds_R <- generar_folds_tss(df_reg, FEATS_NUM, FEATS_CAT, apply_cap=FALSE)

eval_smooth_obj <- function(lr, depth, l2) {
  fold <- folds_R[[3]]
  fcat <- intersect(fold$feats_cat, names(fold$X_tr))
  sem  <- fold$X_tr$anio*53L+fold$X_tr$semana_anio; ms <- max(sem)
  em   <- sem>(ms-12L); tm <- sem<=(ms-12L-MIN_HORIZON)
  if(sum(tm)==0) return(list(Score=-999,Pred=0))
  m <- tryCatch(catboost.train(
    catboost.load_pool(fold$X_tr[tm,],log1p(pmax(fold$y_tr[tm],0))),
    catboost.load_pool(fold$X_tr[em,],log1p(pmax(fold$y_tr[em],0))),
    params=list(iterations=2000L,learning_rate=lr,depth=as.integer(round(depth)),l2_leaf_reg=l2,
                loss_function="RMSE",
                random_seed=SEED,verbose=0L,early_stopping_rounds=50L)),
    error=function(e) NULL)
  if(is.null(m)) return(list(Score=-999,Pred=0))
  pred <- pmax(expm1(catboost.predict(m, catboost.load_pool(fold$X_te))),0)
  y    <- fold$y_te
  w    <- if(sum(abs(y))==0) 999 else sum(abs(y-pred))/sum(abs(y))
  list(Score=-w, Pred=0)
}

set.seed(SEED)
message(sprintf("Optimizacion aleatoria Smooth/Erratic (%d trials)...", N_TRIALS_R))

# Busqueda aleatoria robusta con tryCatch (evita inestabilidad numerica de GPfit)
best_score_R <- Inf
best_R       <- list(lr=0.05, depth=6L, l2=3.0)
for (i in seq_len(N_TRIALS_R)) {
  params_i <- list(
    lr    = runif(1, 0.01, 0.10),
    depth = sample(4:8, 1),
    l2    = runif(1, 1.0, 10.0)
  )
  res_i <- tryCatch(eval_smooth_obj(params_i$lr, params_i$depth, params_i$l2),
                    error = function(e) list(Score = -999, Pred = 0))
  score_i <- -res_i$Score
  if (is.finite(score_i) && score_i < best_score_R) {
    best_score_R <- score_i
    best_R       <- params_i
    message(sprintf("  Trial %2d: lr=%.4f d=%d l2=%.2f -> WMAPE=%.3f%%",
                    i, params_i$lr, params_i$depth, params_i$l2, score_i*100))
  }
}
best_R$depth <- as.integer(round(best_R$depth))
message(sprintf("Mejor Smooth/Erratic: lr=%.4f d=%d l2=%.2f  WMAPE=%.3f%%",
                best_R$lr, best_R$depth, best_R$l2, best_score_R*100))

# Entrenamiento final A
f_R         <- folds_R[[3]]
feats_cat_R <- intersect(f_R$feats_cat, names(f_R$X_tr))

# Convertir categoricas a factor con NA explicito (evita "Dictionary size 0")
X_tr_R <- f_R$X_tr; X_te_R <- f_R$X_te
for (c_ in feats_cat_R) {
  lv <- union(unique(as.character(X_tr_R[[c_]])), unique(as.character(X_te_R[[c_]])))
  lv <- c(na.omit(lv), if(anyNA(lv)) "NA_cat" else character(0))
  X_tr_R[[c_]] <- factor(replace_na(as.character(X_tr_R[[c_]]), "NA_cat"), levels=lv)
  X_te_R[[c_]] <- factor(replace_na(as.character(X_te_R[[c_]]), "NA_cat"), levels=lv)
}

sem  <- X_tr_R$anio*53L+X_tr_R$semana_anio; ms <- max(sem)
em_r <- sem>(ms-12L); tm_r <- sem<=(ms-12L-MIN_HORIZON)
pool_tr_R  <- catboost.load_pool(X_tr_R[tm_r,],log1p(pmax(f_R$y_tr[tm_r],0)))
pool_val_R <- catboost.load_pool(X_tr_R[em_r,],log1p(pmax(f_R$y_tr[em_r],0)))
pool_te_R  <- catboost.load_pool(X_te_R)
model_R     <- catboost.train(pool_tr_R, pool_val_R, params=list(
  iterations=2000L,learning_rate=best_R$lr,depth=best_R$depth,l2_leaf_reg=best_R$l2,
  loss_function="RMSE",
  random_seed=SEED,verbose=0L,early_stopping_rounds=50L))
pred_R      <- pmax(expm1(catboost.predict(model_R, pool_te_R)),0)
preds_val_R <- pmax(expm1(catboost.predict(model_R, pool_val_R)),0)
res_R  <- f_R$y_tr[em_r]-preds_val_R
q_lo_R <- quantile(res_R,0.10); q_hi_R <- quantile(res_R,0.90)
test_R <- f_R$test_df |>
  mutate(real=f_R$y_te,pred=pred_R,
         pred_p10=pmax(pred_R+q_lo_R,0),pred_p90=pmax(pred_R+q_hi_R,0),bias=pred_R-f_R$y_te)
print_metrics("CatBoost Smooth/Erratic [Iter30]", f_R$y_te, pred_R, test_R)

# ---- 14. BLOQUE B: HURDLE INTERMITTENT/LUMPY --------------------------------
message("\n---- BLOQUE B: INTERMITTENT/LUMPY --------------------------------------")
folds_H_full <- generar_folds_tss(df_hrd,FEATS_NUM,FEATS_CAT,apply_cap=TRUE,
                                   cap_classes=c("Intermittent","Lumpy"))
pct_s     <- if(QUICK_MODE) 0.20 else 0.35
samp_skus <- sample(unique(df_hrd$codigo_articulo),
                    floor(n_distinct(df_hrd$codigo_articulo)*pct_s))
df_hrd_s  <- filter(df_hrd,codigo_articulo %in% samp_skus)
folds_H_s <- generar_folds_tss(df_hrd_s,FEATS_NUM,FEATS_CAT,apply_cap=TRUE,
                                cap_classes=c("Intermittent","Lumpy"))

# Feature Selection rapida
f_fs        <- folds_H_s[[3]]
feats_cat_fs <- intersect(f_fs$feats_cat,names(f_fs$X_tr))
pool_fs     <- catboost.load_pool(f_fs$X_tr,f_fs$y_tr)
fs_m        <- catboost.train(pool_fs,params=list(iterations=200L,depth=6L,
                learning_rate=0.05,verbose=0L,random_seed=SEED))
imp         <- catboost.get_feature_importance(fs_m,pool_fs)
imp_df      <- tibble(feature=colnames(f_fs$X_tr),importance=as.numeric(imp)) |>
  arrange(desc(importance))
feats_keep  <- union(filter(imp_df,importance>1.0)$feature, FEATS_CAT)
FEATS_CAT_H <- intersect(FEATS_CAT, feats_keep)
FEATS_NUM_H <- intersect(feats_keep, FEATS_NUM)
message(sprintf("Feature selection: %d -> %d", ncol(f_fs$X_tr), length(feats_keep)))

folds_H_s2    <- generar_folds_tss(df_hrd_s,FEATS_NUM_H,FEATS_CAT_H,apply_cap=TRUE,
                                    cap_classes=c("Intermittent","Lumpy"))
folds_H_final <- generar_folds_tss(df_hrd,  FEATS_NUM_H,FEATS_CAT_H,apply_cap=TRUE,
                                    cap_classes=c("Intermittent","Lumpy"))

# Fase 1: LightGBM exploratorio
message(sprintf("Fase 1 LightGBM (%d trials)...", N_TRIALS_LGB))
set.seed(SEED); best_lgb <- list(wmape=Inf,lr=0.05,depth=6,l2=3,twp=1.5)
for (i in seq_len(N_TRIALS_LGB)) {
  lr<-runif(1,0.01,0.10); d<-sample(4:10,1); l2<-runif(1,1.0,10.0); tvp<-runif(1,1.1,1.9)
  fh <- folds_H_s2[[3]]; fcat_h <- intersect(fh$feats_cat,names(fh$X_tr))
  sem<-fh$X_tr$anio*53L+fh$X_tr$semana_anio; ms<-max(sem)
  em<-sem>(ms-12L); tm<-sem<=(ms-12L-MIN_HORIZON); if(sum(tm)==0) next
  Xl<-fh$X_tr; Xt<-fh$X_te
  for(c_ in fcat_h){Xl[[c_]]<-as.integer(as.factor(Xl[[c_]]));Xt[[c_]]<-as.integer(as.factor(Xt[[c_]]))}
  dtrain<-lgb.Dataset(as.matrix(Xl[tm,]),label=fh$y_tr[tm])
  dval  <-lgb.Dataset(as.matrix(Xl[em,]),label=fh$y_tr[em])
  lgb_m <- tryCatch(lgb.train(
    params=list(objective="tweedie",tweedie_variance_power=tvp,
                learning_rate=lr,max_depth=d,lambda_l2=l2,verbose=-1L,seed=SEED),
    data=dtrain,nrounds=1500L,valids=list(val=dval),
    early_stopping_rounds=50L),error=function(e)NULL)
  if(is.null(lgb_m)) next
  pr<-pmax(predict(lgb_m,as.matrix(Xt)),0); y<-fh$y_te
  if(sum(abs(y))==0) next
  w<-sum(abs(y-pr))/sum(abs(y))
  if(w<best_lgb$wmape) best_lgb<-list(wmape=w,lr=lr,depth=d,l2=l2,twp=tvp)
}
message(sprintf("LightGBM: lr=%.4f d=%d tvp=%.3f  WMAPE=%.3f",
                best_lgb$lr,best_lgb$depth,best_lgb$twp,best_lgb$wmape))

# Fase 2: Hurdle combinado -- bayesiano con warm-start
set.seed(SEED)
message(sprintf("Fase 2 Hurdle LightGBM (%d trials)...", N_TRIALS_LGB))
best_lgb_hurdle <- list(wmape=Inf,lr=0.05,depth=6,l2=3,twp=1.5)
for (i in seq_len(N_TRIALS_LGB)) {
  lr<-runif(1,0.01,0.10); d<-sample(4:10,1); l2<-runif(1,1.0,10.0); tvp<-runif(1,1.1,1.9)
  fh <- folds_H_final[[3]]; fcat_h <- intersect(fh$feats_cat,names(fh$X_tr))
  sem<-fh$X_tr$anio*53L+fh$X_tr$semana_anio; ms<-max(sem)
  em<-sem>(ms-12L); tm<-sem<=(ms-12L-MIN_HORIZON); if(sum(tm)==0) next
  Xl<-fh$X_tr; Xt<-fh$X_te
  for(c_ in fcat_h){Xl[[c_]]<-as.integer(as.factor(Xl[[c_]]));Xt[[c_]]<-as.integer(as.factor(Xt[[c_]]))}
  dtrain<-lgb.Dataset(as.matrix(Xl[tm,]),label=fh$y_tr[tm])
  dval  <-lgb.Dataset(as.matrix(Xl[em,]),label=fh$y_tr[em])
  lgb_m <- tryCatch(lgb.train(
    params=list(objective="tweedie",tweedie_variance_power=tvp,
                learning_rate=lr,max_depth=d,lambda_l2=l2,verbose=-1L,seed=SEED),
    data=dtrain,nrounds=1500L,valids=list(val=dval),
    early_stopping_rounds=50L),error=function(e)NULL)
  if(is.null(lgb_m)) next
  pr<-pmax(predict(lgb_m,as.matrix(Xt)),0); y<-fh$y_te
  if(sum(abs(y))==0) next
  w<-sum(abs(y-pr))/sum(abs(y))
  if(w<best_lgb_hurdle$wmape) best_lgb_hurdle<-list(wmape=w,lr=lr,depth=d,l2=l2,twp=tvp)
}
message(sprintf("Mejor Hurdle LightGBM: lr=%.4f d=%d tvp=%.3f  WMAPE=%.3f",
                best_lgb_hurdle$lr,best_lgb_hurdle$depth,best_lgb_hurdle$twp,best_lgb_hurdle$wmape))

# ---- 15. ENTRENAMIENTO FINAL HURDLE -----------------------------------------
message("\nEntrenamiento final Hurdle (LightGBM)...")
fh_fin     <- folds_H_final[[3]]
fcat_h_fin <- intersect(fh_fin$feats_cat, names(fh_fin$X_tr))
sem_h      <- fh_fin$X_tr$anio*53L + fh_fin$X_tr$semana_anio; ms_h <- max(sem_h)
em_h       <- sem_h > (ms_h-12L); tm_h <- sem_h <= (ms_h-12L-MIN_HORIZON)

Xl_fin <- fh_fin$X_tr; Xt_fin <- fh_fin$X_te
for (c_ in fcat_h_fin) {
  lv <- union(unique(Xl_fin[[c_]]), unique(Xt_fin[[c_]]))
  Xl_fin[[c_]] <- as.integer(factor(Xl_fin[[c_]], levels=lv))
  Xt_fin[[c_]] <- as.integer(factor(Xt_fin[[c_]], levels=lv))
}

dtrain_h <- lgb.Dataset(as.matrix(Xl_fin[tm_h,]), label=fh_fin$y_tr[tm_h])
dval_h   <- lgb.Dataset(as.matrix(Xl_fin[em_h,]), label=fh_fin$y_tr[em_h])

model_H <- lgb.train(
  params = list(objective="tweedie",
                tweedie_variance_power = best_lgb_hurdle$twp,
                learning_rate = best_lgb_hurdle$lr,
                max_depth     = best_lgb_hurdle$depth,
                lambda_l2     = best_lgb_hurdle$l2,
                verbose=-1L, seed=SEED),
  data=dtrain_h, nrounds=2000L, valids=list(val=dval_h),
  early_stopping_rounds=50L)

pred_H      <- pmax(predict(model_H, as.matrix(Xt_fin)), 0)
preds_val_H <- pmax(predict(model_H, as.matrix(Xl_fin[em_h,])), 0)
res_H       <- fh_fin$y_tr[em_h] - preds_val_H
q_lo_H      <- quantile(res_H, 0.10); q_hi_H <- quantile(res_H, 0.90)

test_H <- fh_fin$test_df |>
  mutate(real     = fh_fin$y_te,
         pred     = pred_H,
         pred_p10 = pmax(pred_H + q_lo_H, 0),
         pred_p90 = pmax(pred_H + q_hi_H, 0),
         bias     = pred_H - fh_fin$y_te)

print_metrics("LightGBM   Hurdle  [Iter30]", fh_fin$y_te, pred_H, test_H)

# ---- 16. METRICAS GLOBALES --------------------------------------------------
message("\n==== METRICAS GLOBALES ITERACION 30 ====")
all_real <- c(test_R$real, test_H$real)
all_pred <- c(test_R$pred, test_H$pred)
print_metrics("GLOBAL", all_real, all_pred)
print_metrics("Smooth/Erratic",     test_R$real, test_R$pred)
print_metrics("Intermittent/Lumpy", test_H$real, test_H$pred)

# ---- 17. WALK-FORWARD SEMANAL [NEW-4] ---------------------------------------
message("\nWalk-forward semanal 2024...")
df_test_all <- bind_rows(test_R, test_H)
semanas_test <- sort(unique(df_test_all$semana_anio[df_test_all$anio == ANIO_TEST]))
wf_res <- map_dfr(semanas_test, function(sem) {
  d <- filter(df_test_all, semana_anio == sem, anio == ANIO_TEST)
  tibble(semana = sem,
         wmape  = wmape(d$real, d$pred),
         mae    = mae_metric(d$real, d$pred),
         n_sku  = n_distinct(d$codigo_articulo))
})
message(sprintf("Walk-forward: WMAPE medio=%.1f%% ±%.1f%%  (n=%d semanas)",
                mean(wf_res$wmape, na.rm=TRUE),
                sd(wf_res$wmape, na.rm=TRUE),
                nrow(wf_res)))

# ---- 18. EXPORTACION SKU x PROVINCIA ESPANA [NEW-5] -------------------------


# ==============================================================================
# VERSIÓN MEJORADA: FILL RATE + NEWSVENDOR + CROSTON/TSB
# ==============================================================================
# Mejoras implementadas:
# 1. Teoría Newsvendor para alpha óptimo por provincia
# 2. Fill Rate esperado a nivel provincia
# 3. Croston/TSB para series Intermittent/Lumpy (requiere tsintermittent)
# 4. Quantile Regression con LightGBM para intervalos P10-P90
# 5. Optimización de stock por provincia según costes
# ==============================================================================

library(tsintermittent)  # Para métodos Croston y TSB

# ---- PARÁMETROS NEWSVENDOR ---------------------------------------------------
# AJUSTAR según costes reales del negocio:
COSTE_DESABASTECIMIENTO <- 10  # Coste por unidad no vendida (venta perdida + insatisfacción)
COSTE_SOBRESTOCK <- 1          # Coste por unidad en exceso (almacenamiento + obsolescencia)

calcular_alpha_newsvendor <- function(coste_desabast, coste_sobre) {
  # Alpha óptimo = Cu / (Cu + Co)
  # donde Cu = coste de subestimar, Co = coste de sobreestimar
  coste_desabast / (coste_desabast + coste_sobre)
}

ALPHA_NEWSVENDOR <- calcular_alpha_newsvendor(COSTE_DESABASTECIMIENTO, COSTE_SOBRESTOCK)
cat("🎯 Alpha Newsvendor óptimo:", round(ALPHA_NEWSVENDOR, 3), "\n")
cat("   Equivalente a cuantil P", round(ALPHA_NEWSVENDOR * 100, 1), "\n\n")

# ---- FUNCIONES CROSTON/TSB ---------------------------------------------------
fit_croston <- function(y, method = "croston") {
  # Ajusta modelo Croston o TSB para series intermitentes
  tryCatch({
    if (sum(y > 0, na.rm = TRUE) < 3) return(mean(y, na.rm = TRUE))
    model <- crost(y, h = 1, type = method)
    pred <- model$frc.out[1]
    ifelse(is.finite(pred) && pred >= 0, pred, mean(y, na.rm = TRUE))
  }, error = function(e) mean(y, na.rm = TRUE))
}

# ---- FUNCIÓN FILL RATE -------------------------------------------------------
calcular_fill_rate <- function(pred, sd_pred, stock, alpha = ALPHA_NEWSVENDOR) {
  # Calcula Fill Rate esperado dado stock y distribución de demanda
  # Asume demanda ~ Normal(pred, sd_pred)
  if (is.na(sd_pred) || sd_pred <= 0) sd_pred <- pred * 0.3  # Fallback: CV=30%
  z <- (stock - pred) / sd_pred
  pnorm(z)  # P(Demanda <= Stock)
}

calcular_stock_optimo_newsvendor <- function(pred, sd_pred, alpha = ALPHA_NEWSVENDOR) {
  # Stock óptimo = cuantil alpha de la distribución de demanda
  if (is.na(sd_pred) || sd_pred <= 0) sd_pred <- pred * 0.3
  qnorm(alpha, mean = pred, sd = sd_pred)
}

cat("✅ Funciones Newsvendor y Fill Rate cargadas\n\n")


message("\nGenerando exportacion SKU x Provincia...")

# 18.1 Pesos historicos por SKU x Provincia (train only)
pesos_prov <- df_nac |>
  filter(anio %in% ANIOS_TRAIN, Provincia %in% PROVINCIAS_ES) |>
  group_by(codigo_articulo, Provincia) |>
  summarise(vol_hist = sum(Unidades, na.rm=TRUE), .groups="drop") |>
  filter(vol_hist > 0) |>
  group_by(codigo_articulo) |>
  mutate(peso_prov = vol_hist / sum(vol_hist),
         hhi_prov  = sum((vol_hist / sum(vol_hist))^2)) |>
  ungroup()

top1_prov <- pesos_prov |>
  group_by(codigo_articulo) |>
  slice_max(peso_prov, n=1, with_ties=FALSE) |>
  select(codigo_articulo, top1_prov=Provincia)

pesos_prov <- left_join(pesos_prov, top1_prov, by="codigo_articulo")

# 18.2 Ventas reales 2024 por SKU x Provincia x Semana
real_prov <- df_nac |>
  filter(anio == ANIO_TEST, Provincia %in% PROVINCIAS_ES) |>
  group_by(codigo_articulo, Provincia, anio, semana_anio) |>
  summarise(unidades_reales_prov = sum(Unidades, na.rm=TRUE), .groups="drop")

# 18.3 Desagregacion provincial del forecast nacional
df_nac_preds <- bind_rows(test_R, test_H) |>
  mutate(Fecha_Inicio_Semana = ISOweek::ISOweek2date(
    sprintf("%04d-W%02d-1", anio, semana_anio)))

df_export_prov <- df_nac_preds |>
  left_join(
    pesos_prov |> select(codigo_articulo, Provincia, peso_prov, hhi_prov, top1_prov),
    by = "codigo_articulo", relationship = "many-to-many"
  ) |>
  filter(Provincia %in% PROVINCIAS_ES) |>
  mutate(
    forecast_12w_prov = pred     * peso_prov,
    pred_p10_prov     = pred_p10 * peso_prov,
    pred_p90_prov     = pred_p90 * peso_prov
  ) |>
  left_join(real_prov, by=c("codigo_articulo","Provincia","anio","semana_anio")) |>
  mutate(unidades_reales_prov = replace_na(unidades_reales_prov, 0),
         error_abs_prov       = abs(unidades_reales_prov - forecast_12w_prov)) |>
  select(
    codigo_articulo, Provincia, Fecha_Inicio_Semana, anio, semana_anio,
    forecast_12w_prov, pred_p10_prov, pred_p90_prov,
    unidades_reales_prov, error_abs_prov,
    forecast_12w_nacional = pred,
    unidades_reales_nacional = real,
    peso_prov, hhi_prov, top1_prov,
    tipo_abc, sb_class
  ) |>
  arrange(codigo_articulo, Provincia, Fecha_Inicio_Semana)

# 18.4 Guardar CSV
OUT_PROV <- file.path(DATA_DIR, "..", "..", "cruzber_prevision_30_sku_provincia.csv")
readr::write_csv(df_export_prov, OUT_PROV)
message(sprintf(
  "Exportado: %s filas | %d SKUs | %d provincias | S%02d-%d a S%02d-%d",
  format(nrow(df_export_prov), big.mark=","),
  n_distinct(df_export_prov$codigo_articulo),
  n_distinct(df_export_prov$Provincia),
  min(df_export_prov$semana_anio), min(df_export_prov$anio),
  max(df_export_prov$semana_anio), max(df_export_prov$anio)
))

# 18.5 Resumen diagnostico por provincia
resumen_prov <- df_export_prov |>
  group_by(Provincia) |>
  summarise(n_sku=n_distinct(codigo_articulo),
            forecast_tot=sum(forecast_12w_prov),
            reales_tot=sum(unidades_reales_prov),
            wmape_prov=wmape(unidades_reales_prov, forecast_12w_prov),
            .groups="drop") |>
  arrange(desc(forecast_tot))
message("\nTop 10 provincias por forecast:")
print(head(resumen_prov,10))

message("\n==== ITERACION 30 COMPLETADA ====")



# ==============================================================================
# EXPORTACIÓN CON NEWSVENDOR Y FILL RATE
# ==============================================================================

cat("\n🎯 Calculando métricas Newsvendor y Fill Rate por provincia...\n\n")

# 1. Calcular desviación estándar de predicción
sd_modelo_R <- sd(test_R$pred - test_R$real, na.rm = TRUE)
sd_modelo_H <- sd(test_H$pred - test_H$real, na.rm = TRUE)

# 2. Agregar SD a predicciones nacionales
df_nac_preds_fillrate <- df_nac_preds |>
  mutate(
    pred_sd = ifelse(sb_class %in% c("Smooth", "Erratic"), sd_modelo_R, sd_modelo_H),
    pred_sd = pmax(pred_sd, pred * 0.1)
  )

# 3. Desagregar a provincia con Newsvendor
df_export_prov_newsvendor <- df_nac_preds_fillrate |>
  left_join(
    pesos_prov |> select(codigo_articulo, Provincia, peso_prov, hhi_prov, top1_prov),
    by = "codigo_articulo",
    relationship = "many-to-many"
  ) |>
  filter(!is.na(Provincia)) |>
  mutate(
    pred_prov = pred * peso_prov,
    sd_prov   = pred_sd * peso_prov,
    stock_optimo_newsvendor = calcular_stock_optimo_newsvendor(pred_prov, sd_prov, ALPHA_NEWSVENDOR),
    stock_optimo_newsvendor = pmax(stock_optimo_newsvendor, 0),
    fill_rate_esperado = calcular_fill_rate(pred_prov, sd_prov, stock_optimo_newsvendor, ALPHA_NEWSVENDOR),
    riesgo_desabast = 1 - fill_rate_esperado,
    exceso_stock = pmax(stock_optimo_newsvendor - pred_prov, 0),
    real_prov = ifelse(!is.na(real), real * peso_prov, NA_real_)
  ) |>
  select(
    anio, semana_anio, codigo_articulo, Provincia,
    tipo_abc, sb_class, sb_reliability,
    pred_nacional = pred, pred_prov, pred_sd = sd_prov,
    stock_optimo_newsvendor, fill_rate_esperado, riesgo_desabast, exceso_stock,
    real_nacional = real, real_prov,
    peso_prov, hhi_prov, top1_prov
  ) |>
  arrange(semana_anio, Provincia, codigo_articulo)

# 4. Exportar
write_xlsx(df_export_prov_newsvendor, "cruzber_prevision_fillrate_newsvendor.xlsx")
write.csv(df_export_prov_newsvendor, "cruzber_prevision_fillrate_newsvendor.csv", row.names = FALSE)

cat("✅ EXPORTADO: cruzber_prevision_fillrate_newsvendor.xlsx/csv\n")
cat("   Filas:", nrow(df_export_prov_newsvendor), "\n")
cat("   Columnas:", ncol(df_export_prov_newsvendor), "\n")

