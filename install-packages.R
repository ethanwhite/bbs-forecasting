if (!require("pacman")) install.packages("pacman")

pacman::p_load(broom, DBI, devtools, doParallel, dplyr, forecast, ggplot2, gimms, Hmisc, maptools, mgcv, prism, raster, rgdal, rgeos, stringr, sp, tidyr)
pacman::p_load_gh("seantuck12/MODISTools", "ropensci/ecoretriever", "rstats-db/RSQLite")

#install.packages(c("broom", "rgdal", "rgeos", "gimms", "prism"), repos = "http://cloud.r-project.org/")
#install_github("seantuck12/MODISTools")
#install_github("ropensci/ecoretriever")
#install_github("rstats-db/RSQLite")