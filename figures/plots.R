devtools::load_all()
library(tidyverse)
library(cowplot)
library(ggjoy)
library(mvtnorm)

settings = yaml::yaml.load_file("settings.yaml")

timeframe = "train_22"
prepend_timeframe = function(x) {
  paste0("results", "/", timeframe, "/", x)
}

base_size = 12 # 12-point font for figures

# peerj PDFs are 14.59 cm wide
my_ggsave = function(filename, plot, height, width = 14.59, units = "cm", ...){
  ggsave(filename = filename, 
         plot = plot, 
         height = height, 
         width = width, 
         units = units, 
         ...)
}

forecast_results = readRDS(prepend_timeframe("forecast.rds")) %>% 
  filter(!is.na(richness))
gbm_results = bind_rows(readRDS(prepend_timeframe("gbm_TRUE.rds")),
                        readRDS(prepend_timeframe("gbm_FALSE.rds")))
mistnet_results = lapply(dir(prepend_timeframe("mistnet_output/"), 
                             full.names = TRUE,
                             pattern = "TRUE|FALSE"),
                         readRDS) %>% 
  bind_rows()


average_results = bind_rows(readRDS(prepend_timeframe("avg_TRUE.rds")), 
                            readRDS(prepend_timeframe("avg_FALSE.rds")))

my_var = function(x){
  ifelse(length(x) == 1, 0, var(x))
}


rf_results = bind_rows(readRDS(prepend_timeframe("rf_predictions/all_FALSE.rds")),
                       readRDS(prepend_timeframe("rf_predictions/all_TRUE.rds")))

bound = bind_rows(forecast_results, gbm_results, average_results, 
                  rf_results, mistnet_results) %>% 
  group_by(site_id, year, richness, model, use_obs_model) %>% 
  summarize(sd = sqrt(mean(sd^2 + my_var(mean))), mean = mean(mean)) %>% 
  mutate(diff = richness - mean, z = diff / sd,
         p = pnorm(richness, mean, sd),
         deviance = -2 * dnorm(richness, mean, sd, log = TRUE)) %>% 
  ungroup() %>% 
  mutate(
    model_name = forcats::fct_recode(
      factor(model), 
      Average = "average", 
      Naive = "naive",
      Auto.arima = "auto.arima", 
      `Stacked random forest SDMs` = "rf_sdm",
      `Mistnet JSDM` = "mistnet",
      `GBM richness regression` = "richness_gbm"
    )
  )

# Divide squared error by predictive variance to get the optimal sd factor
# for the RF model
rf2 = bound %>% 
  filter(use_obs_model, model == "rf_sdm")
rf_sd_factor = rf2 %>% 
  summarize(sqrt(mean(diff^2 / sd^2))) %>% 
  pull()
rf2$sd = rf2$sd * rf_sd_factor

rf2 = rf2 %>% 
  mutate(p = pnorm(richness, mean, sd),
         deviance = -2 * dnorm(richness, mean, sd, log = TRUE))


# scatterplot -------------------------------------------------------------

ts_models = c("average", "naive", "auto.arima")
env_models = c("richness_gbm", "rf_sdm", "mistnet")
models = c(ts_models, env_models)
model_names = unique(bound$model_name)

R2s = filter(bound, use_obs_model, year %in% c(2004, 2013)) %>% 
  mutate(x = min(mean - 4), y = max(richness)) %>% 
  group_by(model, x, y, year) %>% 
  mutate(R2 = 1 - var(mean - richness) / var(richness)) %>% 
  mutate(R2_formatted = paste("R^2: ", 
                              format(R2,digits = 2, nsmall = 2)))

make_scatterplots = function(models, main){
  x_range = range(bound$mean)
  ggplot(data = filter(bound, use_obs_model, year %in% c(2004, 2013),
                       model %in% models), 
         aes(x = mean, y = richness)) +
    geom_hex() + 
    geom_abline(intercept = 0, slope = 1, alpha = .5) +
    facet_grid(year ~ model) +
    coord_equal() + 
    scale_fill_continuous(low = "gray90", high = "navy",
                          limits = c(1, 30)) +
    geom_text(inherit.aes = FALSE,
              data = filter(R2s, model %in% models),
              aes(x = x, y = y, label = R2_formatted),
              hjust = 0, vjust = 1, size = 3) +
    theme_light(base_size = base_size) +
    xlim(x_range) + 
    ggtitle(main)
}

scatters = plot_grid(
  make_scatterplots(ts_models, main = "A. Time-series models"),
  make_scatterplots(env_models, main = "B. Environmental models"),
  align = "h",
  nrow = 2)
my_ggsave(filename = "figures/scatter.png", plot = scatters, height = 15)

# Violins -----------------------------------------------------------------


for_violins = bound %>% 
  filter(model == "average", use_obs_model) %>% 
  left_join(filter(bound, model != "average", use_obs_model), 
            c("site_id", "year", "use_obs_model"),
            suffix = c(".avg", ".other")) %>% 
  mutate(dev_diff = deviance.other - deviance.avg,
         squared_diff = diff.other^2 - diff.avg^2,
         abs_diff = abs(diff.other) - abs(diff.avg))

make_violins = function(data, ylab = "", ylim, yintercept, adjust = 2, main){
  data %>% 
    ggplot(aes(x = model, y = y)) + 
    geom_hline(yintercept = yintercept, color = alpha(1, .25), size = 1/2) +
    geom_violin(fill = alpha("cornflowerblue", .9), size = 0, adjust = adjust) + 
    stat_summary(fun.data = "mean_cl_boot", colour = "darkblue", geom = "point",
                 size = 1) + 
    coord_cartesian(expand = FALSE, ylim = ylim) +
    theme_cowplot(base_size) +
    ylab(ylab) +
    xlab("Model type") +
    ggtitle(main)
}

# Note that the y axis doesn't extend all the way on this plot because
# of a small number of extreme outliers
model_violins = plot_grid(
  for_violins %>% 
    mutate(model = model.other, y = abs_diff) %>% 
    make_violins(yintercept = 0, 
                 ylim = quantile(for_violins$abs_diff, c(.0005, .9995)),
                 main = "A. Absolute error increase versus \"Average\" baseline",
                 ylab = "Absolute error increase (species)"),
  for_violins %>% 
    mutate(model = model.other, y = dev_diff) %>%
    make_violins(yintercept = 0, 
                 ylim = quantile(for_violins$abs_diff, c(.0005, .9995)), 
                 main = "B. Deviance increase versus \"Average\" baseline",
                 ylab = "Deviance increase"),
  nrow = 2
)
my_ggsave(file = "figures/model_violins.png", 
          plot = model_violins,
          height = 12.5
)


# Metrics over time -------------------------------------------------------

d = bound %>% 
  group_by(year, model, use_obs_model) %>% 
  summarize(rmse = sqrt(mean(diff^2)), 
            mean_deviance = -2 * mean(dnorm(richness, mean, sd, log = TRUE)),
            coverage = mean(p > .025 & p < .975)) %>% 
  filter(use_obs_model) %>% 
  gather(key = "variable", value = "value", rmse, mean_deviance, coverage) %>% 
  mutate(variable = forcats::fct_relevel(variable, "rmse", "mean_deviance", 
                                         "coverage"))

# Possibly-useful alternative 6-color colorblind palette
colors = c("#000000", dichromat::colorschemes$Categorical.12[c(4, 6, 10, 11, 12)])

make_time_error = function(var_name, title){
  ggplot(filter(d, variable == var_name), 
         aes(x = year, y = value, color = model)) +
    geom_line() +
    scale_x_continuous(expand = c(0, 0)) +
    theme_light(base_size = base_size) +
    scale_color_brewer(palette = "Set1") +
    ylab(var_name) + 
    ggtitle(paste0(title, ". ", var_name))
}

plotlist = pmap(
  list(
    levels(d$variable), 
    LETTERS[1:3]
  ), 
  make_time_error
)

# Pull out the legend from one of the plots as its own object, then remove 
# from individual panels
time_error_legend = get_legend(plotlist[[1]])
plotlist = map(plotlist, ~.x + theme(legend.position = "none"))

plotlist[[3]] = plotlist[[3]] + 
  geom_hline(yintercept = 0.95) +
  scale_y_continuous(limits = c(.65, 1.0025), expand = c(0, 0))

time_error = plot_grid(
  plot_grid(plotlist = plotlist, nrow = 3, align = "v"),
  time_error_legend,
  rel_widths = c(4, 1)
)
my_ggsave(file = "figures/performance_time.png", plot = time_error, height = 15)



# Decomposed squared error ------------------------------------------------

barchart_data = bound %>% 
  rename(y = richness, x = mean) %>% 
  filter(use_obs_model) %>% 
  group_by(site_id, model) %>% 
  mutate(
    x_bar = mean(x),
    y_bar = mean(y),
    delta_x = x - x_bar, 
    delta_y = y - y_bar
  ) %>% 
  group_by(model) %>% 
  summarize(`Site-level mean` = var(y_bar - x_bar), 
            `Annual fluctuations` = var(delta_y - delta_x)) %>% 
  gather(key = `Error component`, value = value, -1) %>% 
  mutate(
    env = model %in% env_models,
    model = factor(model, levels = !!models),
    `Error component` = factor(`Error component`, 
                               levels = rev(sort(unique(`Error component`))))
  )


make_error_barchart = function(use_env){
  filter(barchart_data, env == use_env) %>% 
    ggplot(aes(x = model, y = value, fill = `Error component`)) +
    geom_col(position = "dodge") +
    scale_y_continuous(limits = c(0, max(barchart_data$value) + 1), 
                       expand = c(FALSE, FALSE)) +
    theme_cowplot(base_size - 1) + 
    ggtitle(ifelse(use_env, "Environment", "Time series")) + 
    theme(axis.text.x = element_text(angle = 90, hjust = 1, vjust = .5),
          plot.margin = margin(1, 1, 1, 1)) +
    scale_fill_brewer(palette = "Paired") + 
    xlab("")
}

barchart_list = map(c(FALSE, TRUE), make_error_barchart)
barchart_legend = get_legend(barchart_list[[1]])

barcharts = plot_grid(
  plot_grid(
    barchart_list[[1]] + 
      theme(legend.position = "none") + 
      ylab("Mean squared error"),
    barchart_list[[2]] + 
      theme(legend.position = "none") +
      ylab(""),
    align = "h"
  ),
  barchart_legend,
  rel_widths = c(3, 1)
)
my_ggsave("figures/barcharts.png", barcharts, height = 10)



# digging into observer error ---------------------------------------------

obs_model = readRDS(prepend_timeframe("observer_model.rds"))

observer_uncertainties = obs_model$data %>% 
  filter(!in_train) %>% 
  group_by(observer_id, year, site_id, training_observer) %>% 
  summarize(observer_sd = sd(observer_effect)) %>% 
  ungroup() %>% 
  mutate(obs_class = cut_number(observer_sd, 10)) %>% 
  left_join(filter(bound, model == "average", use_obs_model), 
            by = c("year", "site_id"))

obs_joy = observer_uncertainties %>% 
  ggplot(aes(x = observer_sd^2, y = factor(year), 
             fill = year)) + 
  viridis::scale_fill_viridis(option = "B", guide = FALSE,
                              direction = 1) + 
  geom_joy(scale = 5, bandwidth = .75, color = "gray40") + 
  theme_joy(font_size = base_size) +
  ylab(expression("Year" %->% "")) + 
  xlab("Observer-level uncertainty (squared error)") + 
  theme(axis.title.x = element_text(hjust = .5),
        axis.title.y = element_text(hjust = .5))
my_ggsave("figures/observer_uncertainty.png", obs_joy, height = 11)


# Time series -------------------------------------------------------------

make_ts_plots = function(models, ylim, use_obs_model, sample_site_id, 
                         main = ""){
  grid = crossing(model = c(ts_models, env_models),
                  use_obs_model = use_obs_model,
                  year = unique(obs_model$data$year))
  
  time_series_data = obs_model$data %>% 
    filter(site_id == sample_site_id, iteration == 1) %>% 
    select(site_id, year, richness, observer_id, richness) %>% 
    left_join(grid, by = "year") %>% 
    left_join(select(bound, -richness), by = c("year", "model", "use_obs_model",
                                               "site_id")) %>% 
    mutate(model = forcats::fct_relevel(model, unique(models)),
           observer_id = ifelse(use_obs_model, observer_id, 0)) %>% 
    select(site_id, year, model, use_obs_model, mean, sd, richness, observer_id,
           deviance)
  
  faceting = if (length(use_obs_model) == 2) {
    facet_grid(model ~ use_obs_model)
  } else {
    (facet_grid(~ model))
  }
  
  title = if (main != "") {
    ggtitle(main)
  } else {
    NULL
  }
  
  ggplot(filter(time_series_data, model %in% models), aes(x = year)) +
    geom_ribbon(aes(ymin = mean - 1.96 * sd, ymax = mean + 1.96 * sd),
                fill = "gray80") +
    geom_ribbon(aes(ymin = mean - 1 * sd, ymax = mean + 1 * sd),
                fill = "gray60") +
    geom_line(aes(y = mean), color = "gray30") +
    faceting +
    geom_line(aes(y = richness, alpha = .5 * (year < min(bound$year - 1)))) + 
    geom_point(aes(y = richness, fill = factor(observer_id),
                   shape = factor(observer_id)),
               size = 1.25, stroke = .5) +
    scale_alpha(range = c(0, 1), guide = FALSE) + 
    coord_cartesian(ylim = ylim, expand = TRUE) +
    scale_shape_manual(values = c(16, 22, 23), guide = FALSE) + 
    ylab("Richness") +
    scale_fill_manual(values = c("white", "#fdcc8a", "#d7301f"), guide = FALSE) + 
    theme_light(base_size = base_size) + 
    theme(plot.margin = unit(c(10, 7, 1, 7), units = "pt"),
          strip.background = element_rect(fill="white"), 
          strip.text = element_text(color = "black")) +
    title +
    xlab("Year")
}

# The warning about missing values is just saying that there are no predictions
# before 2004.
model_predictions = list(ts_models, env_models) %>% 
  map(~make_ts_plots(.x, 
                     ylim = c(33, 68), 
                     use_obs_model = TRUE, 
                     sample_site_id = 72084,
                     main = ifelse(
                       all(.x %in% ts_models),
                       "A. Time series models", 
                       "B. Environmental models"))
  ) %>% 
  plot_grid(plotlist = ., nrow = 2)
  
my_ggsave(filename = "figures/model_predictions.png", 
       plot = model_predictions, 
       height = 10)


obs_predictions = make_ts_plots(
  c("average", "naive", "rf_sdm"), ylim = c(41, 91), 
  use_obs_model = c(TRUE, FALSE), sample_site_id = 72035,
  main = ""
)
my_ggsave("figures/observer_predictions.png", 
          obs_predictions, 
          height = 10)


# correlations in the residuals -------------------------------------------

# Need to bring in obs_model$data because we're looking at training residuals
residuals = obs_model$data %>% 
  filter(in_train) %>% 
  mutate(predicted = site_effect + observer_effect + c(obs_model$intercept)) %>% 
  left_join(distinct(bound, site_id, year, richness),
            c("site_id", "year", "richness")) %>% 
  group_by(site_id, year) %>% 
  summarize(diff = mean(richness - predicted)) %>% 
  ungroup() %>% 
  spread(key = site_id, value = diff) %>% 
  select(-year) %>% 
  as.matrix()



# Ornstein-Uhlenbeck negative log-likelihood
ou_nll = function(x) {
  l = x["l"]         # Lengthscale
  sigma = x["sigma"] # standard deviation
  
  # Build the covariance matrix based on l & sigma
  covariance = matrix(NA, nrow = nrow(residuals), ncol = nrow(residuals))
  for (i in 1:nrow(residuals)) {
    for (j in 1:nrow(residuals)) {
      # OU process covariance, pp. 85-86 of Gaussian Processes 
      # for Machine Learning
      covariance[i, j] = sigma^2 * exp(-l * abs(i - j))
    }
  }
  
  # Negative log-likelihood objective
  - sum(
    sapply(
      1:ncol(residuals),
      function(i){
        # Multivariate Gaussian log-likelihood based on each column of y.
        # Only use the non-NA entries in y and in the covariance
        non_na = !is.na(residuals[,i])
        dmvnorm(residuals[non_na,i], 
                sigma = covariance[non_na, non_na], 
                log = TRUE)
      }
    )
  )
}
o = optim(c(l = exp(-2), sigma = sd(residuals, na.rm = TRUE)), 
          ou_nll, 
          control = list(trace = 1))

residual_autocor = exp(-o$par["l"])


# Numbers for the manuscript ----------------------------------------------


forecast_intercept_rate = forecast_results %>% 
  filter(model == "auto.arima", use_obs_model) %>% 
  pull(coef_names) %>% 
  map(~.x == "intercept") %>% 
  flatten_lgl() %>% 
  mean()
forecast_intercept_percent = round(100 * forecast_intercept_rate)


observer_deviance_data = bound %>% 
  mutate(use_obs_model = forcats::fct_recode(factor(use_obs_model), 
                                             no = "FALSE", 
                                             yes = "TRUE")) %>% 
  select(site_id, year, model, use_obs_model, deviance) %>% 
  spread(key = use_obs_model, value = deviance) %>% 
  mutate(y = no - yes)

observer_error_data = bound %>% 
  mutate(use_obs_model = forcats::fct_recode(factor(use_obs_model), 
                                             no = "FALSE", 
                                             yes = "TRUE")) %>% 
  select(site_id, year, model, use_obs_model, diff) %>% 
  spread(key = use_obs_model, value = diff) %>% 
  mutate(y = abs(no) - abs(yes))


obs_violins = plot_grid(
  make_violins(observer_error_data, 
               main = "Absolute error reduction from observer model",
               ylab = "Reduction in absolute\nrichness error (species)",
               ylim = quantile(observer_error_data$y, c(.0005, .9995)), 
               yintercept = 0),
  make_violins(observer_deviance_data, 
               main = "Deviance reduction from observer model",
               ylab = "Posterior weight of\nobserver model",
               ylim = quantile(observer_deviance_data$y, c(.005, .995)), 
               yintercept = 0),
  nrow = 2
)
my_ggsave("figures/observers.png", obs_violins, height = 10)


# RF versus RF2 -----------------------------------------------------------

rf2_diff = bound$deviance[bound$use_obs_model & bound$model == "rf_sdm"] - rf2$deviance
rf2_plot = ggplot(NULL, aes(x = rf2_diff)) + 
  geom_density(n = 1000, adjust = 1, trim = FALSE, fill = "cornflowerblue",
               color = 0) + 
  geom_vline(xintercept = 0) +
  geom_vline(xintercept = mean(rf2_diff), color = "red") + 
  theme_light(base_size = base_size) +
  scale_y_continuous(expand = c(FALSE, FALSE)) +
  xlab("Deviance improvement from scaling the SDM uncertainty")

my_ggsave("figures/rf2.png", rf2_plot, height = 10)

# Numerical odds and ends for manuscript ----------------------------------
bbs_data = get_pop_ts_env_data(
  start_yr = settings$start_yr, 
  end_yr = settings$timeframes[[timeframe]]$end_yr, 
  last_train_year = settings$timeframes[[timeframe]]$last_train_year, 
  min_year_percentage = settings$min_year_percentage)

variance_components = data_frame(site = obs_model$site_sigma^2, 
                                 observer = obs_model$observer_sigma^2,
                                 residual = obs_model$sigma^2)
variance_frac = colMeans(variance_components / rowSums(variance_components))

ms_numbers = list(
  N_species =  bbs_data %>% 
    distinct(species_id) %>% 
    nrow(),
  N_runs = obs_model$data %>% 
    distinct(site_id, year) %>% 
    nrow(),
  N_sites = obs_model$data %>% 
    distinct(site_id) %>% 
    nrow(),
  N_predict_sites = bound %>% 
    distinct(site_id) %>% 
    nrow(),
  N_predictions = bound %>% 
    distinct(site_id, year) %>% 
    nrow(),
  N_obs = obs_model$data %>% 
    distinct(observer_id) %>% 
    nrow(),
  richness_summary = obs_model$data %>% 
    distinct(site_id, year, richness) %>% 
    summarize(mean = round(mean(richness)),
              min = min(richness),
              max = max(richness)),
  n_gbm = gbm_results %>% 
    filter(site_id == 2001, year == 2004) %>% 
    group_by(use_obs_model) %>% 
    summarize(means = mean(n.trees)) %>% 
    pull(means) %>% 
    signif(2),
  rf_coverage_pct = bound %>% 
    filter(model == "rf_sdm", use_obs_model) %>% 
    summarize(round(100 * mean(p > .025 & p < .975))) %>% 
    pull(),
  ts_R2s = R2s %>% 
    filter(model %in% ts_models) %>% 
    pull(R2) %>% 
    range() %>% 
    format(digits = 2) %>% 
    paste(collapse = "-"),
  env_R2s = R2s %>% 
    filter(model %in% env_models) %>% 
    pull(R2) %>% 
    range() %>% 
    format(digits = 2) %>% 
    paste(collapse = "-"),
  variance_percent = as.list(round(variance_frac * 100)),
  pct_is_average = forecast_results %>% 
    group_by(use_obs_model) %>% 
    filter(model == "auto.arima") %>% 
    summarize(is_avg = mean(100 * map_lgl(coef_names, ~all(.x == "intercept")))) %>% 
    pull(is_avg) %>% 
    round(),
  resid_sd = round(sqrt(mean(obs_model$sigma^2)), 1),
  residual_autocor = residual_autocor,
  mistnet_rmse = bound %>% 
    filter(use_obs_model, model == "mistnet") %>% 
    summarize(sqrt(mean(diff^2))) %>% 
    pull(),
  mistnet_rmse_singles = mistnet_results %>% 
    filter(use_obs_model) %>% 
    summarize(sqrt(mean((mean - richness)^2))) %>% 
    pull()
)  
cat(yaml::as.yaml(ms_numbers), file = "manuscript/numbers.yaml")
