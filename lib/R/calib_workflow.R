#!/usr/bin/env Rscript
args <- commandArgs(trailingOnly=TRUE)
namelistFile <- args[1]
#mCurrent <- args[2]

#.libPaths("/glade/u/home/adugger/system/R/Libraries/R3.2.2")
#library(rwrfhydro)
library(data.table)
library(ggplot2)
library(ncdf4)
library(plyr)

#########################################################
# SETUP
#########################################################

source("calib_utils.R")
source(namelistFile)
objFunc <- get(objFn)

# Metrics
#metrics <- c("cor", "rmse", "bias", "nse", "nselog", "nsewt", "kge", "msof")
metrics <- c("cor", "rmse", "bias", "nse", "nselog", "nsewt", "kge", "msof", "hyperResMultiObj")

#########################################################
# MAIN CODE
#########################################################

# First loop check
if (file.exists(paste0(runDir, "/proj_data.Rdata"))) { 
   # If the run directories have changed for any reason, over-write them in the
   # R Dataset file. This is for when a user may take over a job, and move
   # the data.  
   writePlotDirCheck3 <- paste0(runDir, "/plots")
   outPathCheck3 <- paste0(runDir, "/OUTPUT")
   runDirCheck3 <- runDir

   load(paste0(runDir, "/proj_data.Rdata"))

   if (writePlotDir != writePlotDirCheck3){
      writePlotDir <- writePlotDirCheck3
      outPath <- outPathCheck
      runDir <- runDirCheck
      rm(writePlotDirCheck3,outPathCheck)
   }  
} else {
   # First run so need to initialize
   #ReadNamelist(paste0(runDir, "/calibScript.R"))
   cyclecount <- 0
   lastcycle <- FALSE

   # Read parameter bounds 
   paramBnds <- read.table(paste0(runDir, "/calib_parms.tbl"), header=TRUE, sep=",", stringsAsFactors=FALSE)
   paramBnds <- subset(paramBnds, paramBnds$calib_flag==1)

   # Setup plot directory
   writePlotDir <- paste0(runDir, "/plots")
   dir.create(writePlotDir)

   # Load obs so we have them for next iteration
   load(paste0(runDir, "/OBS/obsStrData.Rdata"))
   if ("q_cms" %in% names(obsStrData)) obsStrData$q_cms <- NULL

   # Find the index of the gage
   #rtLink <- ReadRouteLink(rtlinkFile)
   #gageIndx <- which(rtLink$link == linkId)
   #rm(rtLink)

   # Setup value lists from paramBnds
   xnames <- paramBnds$parameter
   x0 <- paramBnds$ini
   names(x0) <- xnames
   x_min <- paramBnds$minValue
   names(x_min) <- xnames
   x_max <- paramBnds$maxValue
   names(x_max) <- xnames

   # Initialize parameter archive DF
   write("Initialize parameter archive", stdout())
   x_archive <- as.data.frame(matrix(, nrow=1, ncol=length(xnames)+2+length(metrics)))
   names(x_archive) <- c("iter", xnames, "obj", metrics)

   # Output parameter set
   x_new <- x0
   cyclecount <- 1

   x_new_out <- c(cyclecount, x_new)
   names(x_new_out)[1] <- "iter"
   # MOVE TO END: write.table(data.frame(t(x_new_out)), file=paste0(runDir, "/params_new.txt"), row.names=FALSE, sep=" ")

   # Save and exit
   rm(objFn, mCurrent, r, siteId, rtlinkFile, linkId, startDate, ncores)
   save.image(paste0(runDir, "/proj_data.Rdata"))
   
   # Write param files
   write.table(data.frame(t(x_new_out)), file=paste0(runDir, "/params_new.txt"), row.names=FALSE, sep=" ")

   #system(paste0("touch ", runDir, "/R_COMPLETE"))
   fileConn <- file(paste0(runDir, "/R_COMPLETE"))
   writeLines('', fileConn)
   close(fileConn)

   quit("no")
}

if (cyclecount > 0) {

 if (mCurrent < cyclecount) {
   # Extra check for python workflow. If the counts get off due to a crash, just spit out previous params_new and params_stats.
   write(paste0("Cycle counts off so repeating last export. mCurrent=", mCurrent, " cyclecount=", cyclecount), stdout())
   if (exists("paramStats")) write.table(paramStats, file=paste0(runDir, "/params_stats.txt"), row.names=FALSE, sep=" ")
   if (exists("x_new_out")) write.table(data.frame(t(x_new_out)), file=paste0(runDir, "/params_new.txt"), row.names=FALSE, sep=" ")

   fileConn <- file(paste0(runDir, "/R_COMPLETE"))
   writeLines('', fileConn)
   close(fileConn)

   quit("no")

 } else {

   # Read model out and calculate performance metric
   outPath <- paste0(runDir, "/OUTPUT")
   write(paste0("Output dir: ", outPath), stdout())

   # Setup parallel
   if (ncores>1) {
        parallelFlag <- TRUE
        library(doParallel)
        #cl <- makeForkCluster(ncores)
        cl <- makePSOCKcluster(ncores)
        registerDoParallel(cl)
   } else {
        parallelFlag <- FALSE
   }

   # Read files
   write(paste0("Reading model out files. Parallel ", parallelFlag, " ncores=", ncores), stdout())
   system.time({
   filesList <- list.files(path = outPath,
                          pattern = glob2rx("*.CHANOBS_DOMAIN*"),
                          full.names = TRUE)
   filesListDate <- as.POSIXct(unlist(plyr::llply(strsplit(basename(filesList),"[.]"), '[',1)), format = "%Y%m%d%H%M", tz = "UTC")
   whFiles <- which(filesListDate >= startDate)
   filesList <- filesList[whFiles]
   if (length(filesList) == 0) stop("No matching files in specified directory.")

   # Find the index of the gage from the first file in the list.
   idTmp <- nc_open(filesList[1])
   featureIdTmp <- ncvar_get(idTmp,'feature_id')
   gageIndx <- which(featureIdTmp == linkId)
   print(gageIndx)
   print(whFiles[0])
   nc_close(idTmp)
   rm(idTmp)
   rm(featureIdTmp)
   
   chrt <- as.data.table(plyr::ldply(filesList, ReadChFile, gageIndx, .parallel = parallelFlag))
   })

   # Stop cluster
   if (parallelFlag) stopCluster(cl)

   # Check for empty output
   if (nrow(chrt) < 1) {
       write(paste0("No data found in model output for link ", linkId, " after start date ", startDate), stdout())
       fileConn <- file(paste0(runDir, "/CALC_STATS_MISSING"))
       writeLines('', fileConn)
       close(fileConn)
       quit("no")
   }

   # Convert the observation dataset to a data.table if it hasn't already.
   obsStrData <- as.data.table(obsStrData)

   # Convert to daily if needed and tag object
   if (calcDailyStats) {
     chrt.d <- Convert2Daily(chrt)
     chrt.d[, site_no := siteId]
     assign(paste0("chrt.obj.", cyclecount), chrt.d)
     chrt.obj <- copy(chrt.d)
     obs.obj <- Convert2Daily(obsStrData)
     obs.obj[, site_no := siteId]
   } else {
     chrt[, site_no := siteId]
     assign(paste0("chrt.obj.", cyclecount), chrt)
     chrt.obj <- copy(chrt)
     obs.obj <- copy(obsStrData)
   }

   # Merge
   setkey(chrt.obj, "site_no", "POSIXct")
   if ("Date" %in% names(obs.obj)) obs.obj[, Date := NULL]
   # Convert the observation dataset to a data.table if it hasn't already.
   obs.obj <- as.data.table(obs.obj)
   setkey(obs.obj, "site_no", "POSIXct")
   chrt.obj <- merge(chrt.obj, obs.obj, by=c("site_no", "POSIXct"), all.x=TRUE, all.y=FALSE)
   # Check for empty output
   if (nrow(chrt.obj) < 1) {
      write(paste0("No data found in obs for gage ", siteId, " after start date ", startDate), stdout())
      fileConn <- file(paste0(runDir, "/CALC_STATS_MISSING"))
      writeLines('', fileConn)
      close(fileConn)
      quit("no")
   }

   # Calc objective function
   F_new <- objFunc(chrt.obj$q_cms, chrt.obj$obs)
   if (objFn %in% c("Nse", "NseLog", "NseWt", "Kge")) F_new <- 1 - F_new

   # Calc stats
   chrt.obj.nona <- chrt.obj[!is.na(q_cms) & !is.na(obs),]
   statCor <- cor(chrt.obj.nona$q_cms, chrt.obj.nona$obs)
   statRmse <- Rmse(chrt.obj$q_cms, chrt.obj$obs, na.rm=TRUE)
   statBias <- PBias(chrt.obj$q_cms, chrt.obj$obs, na.rm=TRUE)
   statNse <- Nse(chrt.obj$q_cms, chrt.obj$obs, na.rm=TRUE)
   statNseLog <- NseLog(chrt.obj$q_cms, chrt.obj$obs, na.rm=TRUE)
   statNseWt <- NseWt(chrt.obj.nona$q_cms, chrt.obj.nona$obs)
   statKge <- Kge(chrt.obj$q_cms, chrt.obj$obs, na.rm=TRUE)
   statHyperResMultiObj <- hyperResMultiObj(chrt.obj$q_cms, chrt.obj$obs, na.rm=TRUE)
   if (calcDailyStats) {
      statMsof <- Msof(chrt.obj$q_cms, chrt.obj$obs, scales=c(1,10,30))
   } else {
      statMsof <- Msof(chrt.obj$q_cms, chrt.obj$obs, scales=c(1,24))
   }

   # Archive results
   #x_archive[cyclecount,] <- c(cyclecount, x_new, F_new, statCor, statRmse, statBias, statNse, statNseLog, statNseWt, statKge, statMsof)
   x_archive[cyclecount,] <- c(cyclecount, x_new, F_new, statCor, statRmse, statBias, statNse, statNseLog, statNseWt, statKge, statMsof, statHyperResMultiObj)

   # Evaluate objective function
   if (cyclecount == 1) {
      x_best <- x_new
      F_best <- F_new
      iter_best <- cyclecount
      bestFlag <- 1
   } else if (F_new <= F_best) {
      x_best <- x_new
      F_best <- F_new
      iter_best <- cyclecount
      bestFlag <- 1
   } else {
      bestFlag <- 0
   }

   # Add best flag and output
   paramStats <- cbind(x_archive[cyclecount,c("iter", "obj", metrics)], data.frame(best=bestFlag))
   #MOVE WRITE TO END: write.table(paramStats, file=paste0(runDir, "/params_stats.txt"), row.names=FALSE, sep=" ")

   if (cyclecount < m) {
      # Select next parameter set
      x_new <- DDS.sel(i=cyclecount, m=m, r=r, xnames=xnames, x_min=x_min, x_max=x_max, x_best=x_best)
      cyclecount <- cyclecount+1  

      # Output next parameter set
      x_new_out <- c(cyclecount, x_new)
      names(x_new_out)[1] <- "iter"
      #MOVE WRITE TO END: write.table(data.frame(t(x_new_out)), file=paste0(runDir, "/params_new.txt"), row.names=FALSE, sep=" ")
      write(x_new_out, stdout())
   } else {
      lastcycle <- TRUE
   }


#########################################################
# PLOTS
#########################################################
# First we check if all the objective function values are less than the threshold (here 5), define it as no outlier in the iterations
# If there are objFun values greater than the threshold in the objFun, then calulate the 90% of the objFun
# Any iteration with objFun values above the 90% would be flagged as outlier. And then two plots will be created 
# one with all iteration including the outliers, two only 90% of the data if there was an outlier in the model. 
 
objFunThreshold <- 5
objFunQuantile <- quantile(x_archive$obj, 0.9)

if (any(x_archive$obj > objFunThreshold)) {
   write("Outliers found!", stdout())

   # Check which outlier threshold to use
   if (any(x_archive$obj <= objFunThreshold)) {
     x_archive_plot <- subset(x_archive, x_archive$obj <= objFunThreshold)
     x_archive_plot_count <- nrow(x_archive) - nrow(x_archive_plot) 
     x_archive_plot_threshold <- objFunThreshold
   } else {
     x_archive_plot <- subset(x_archive, x_archive$obj <= objFunQuantile)
     x_archive_plot_count <- nrow(x_archive) - nrow(x_archive_plot)
     x_archive_plot_threshold <- objFunQuantile
   }

   if (!exists("x_archive_plot_count_track")) x_archive_plot_count_track <- data.frame()
   x_archive_plot_count_track <- rbind(x_archive_plot_count_track, data.frame(iter=ifelse(lastcycle, cyclecount, cyclecount-1), outliers=nrow(x_archive)-nrow(x_archive_plot)))

   # Outlier count
   if (nrow(x_archive_plot_count_track) > 0) {
       write("Outlier count plot...", stdout())
       gg <- ggplot(data=x_archive_plot_count_track, aes(x=iter, y=outliers)) +
            geom_point() + theme_bw() +
            labs(x="run", y="count of outlier cycles")
       ggsave(filename=paste0(writePlotDir, "/", siteId, "_calib_outliers.png"),
            plot=gg, units="in", width=6, height=5, dpi=300)
   }

} else {
  write("No outliers found.", stdout())
  # All the objFun vlaues are less than the threshold defined above, therefore, there will not be any outliers specified
   x_archive_plot <- x_archive
   x_archive_plot_count <- 0
   x_archive_plot_threshold <- objFunThreshold
}

#**************************************************************************************************************************************
#                                   Create the plots with outlier
#**************************************************************************************************************************************

   # Update basic objective function plot
   write("Basin objective function plot...", stdout())
   gg <- ggplot(data=x_archive, aes(x=iter, y=obj)) + 
              geom_point() + theme_bw() + 
              labs(x="run", y="objective function")
   ggsave(filename=paste0(writePlotDir, "/", siteId, "_calib_run_obj_outlier.png"),
              plot=gg, units="in", width=6, height=5, dpi=300)

   # Update the Objective function versus the parameter variable
   write("Obj function vs. params...", stdout())
   DT.m1 = melt(x_archive[, setdiff(names(x_archive), metrics)], id.vars = c("obj"), measure.vars = setdiff( names(x_archive), c(metrics, "iter", "obj")))
   DT.m1 <- subset(DT.m1, !is.na(DT.m1$value))
   gg <- ggplot2::ggplot(DT.m1, ggplot2::aes(value, obj))
   gg <- gg + ggplot2::geom_point(size = 1, color = "red", alpha = 0.3)+facet_wrap(~variable, scales="free_x")
   gg <- gg + ggplot2::ggtitle(paste0("Scatter Plot of Obj. function versus parameters: ", siteId))
   gg <- gg + ggplot2::xlab("Parameter Values")+theme_bw()+ggplot2::ylab("Objective Function")
   ggsave(filename=paste0(writePlotDir, "/", siteId, "_obj_vs_parameters_calib_run_outlier.png"),
         plot=gg, units="in", width=8, height=6, dpi=300)


   # Plot the variables as a function of calibration runs
   write("Params over runs...", stdout())
   DT.m1 = melt(x_archive[, setdiff(names(x_archive), metrics)], id.vars = c("iter"), measure.vars = setdiff(names(x_archive), c("iter", metrics)))
   DT.m1 <- subset(DT.m1, !is.na(DT.m1$value))
   gg <- ggplot2::ggplot(DT.m1, ggplot2::aes(iter, value))
   gg <- gg + ggplot2::geom_point(size = 1, color = "red", alpha = 0.3)+facet_wrap(~variable, scales="free")
   gg <- gg + ggplot2::ggtitle(paste0("Parameter change with iteration: ", siteId))
   gg <- gg + ggplot2::xlab("Calibration Iteration")+theme_bw()
   ggsave(filename=paste0(writePlotDir, "/", siteId, "_parameters_calib_run_outlier.png"),
         plot=gg, units="in", width=8, height=6, dpi=300)

   # Plot all the stats
   write("Metrics plot...", stdout())
   #DT.m1 = melt(x_archive[,which(names(x_archive) %in% c("iter", "obj", "cor", "rmse", "bias", "nse", "nselog", "nsewt", "kge", "msof"))],
   #            iter.vars = c("iter"), measure.vars = c("obj", "cor", "rmse", "bias", "nse", "nselog", "nsewt", "kge", "msof"))
   DT.m1 = melt(x_archive[,which(names(x_archive) %in% c("iter", "obj", "cor", "rmse", "bias", "nse", "nselog", "nsewt", "kge", "msof", "hyperResMultiObj"))],
               iter.vars = c("iter"), measure.vars = c("obj", "cor", "rmse", "bias", "nse", "nselog", "nsewt", "kge", "msof", "hyperResMultiObj"))
   DT.m1 <- subset(DT.m1, !is.na(DT.m1$value))
   gg <- ggplot2::ggplot(DT.m1, ggplot2::aes(iter, value))
   gg <- gg + ggplot2::geom_point(size = 1, color = "red", alpha = 0.3)+facet_wrap(~variable, scales="free")
   gg <- gg + ggplot2::ggtitle(paste0("Metric Sensitivity: ", siteId))
   gg <- gg + ggplot2::xlab("Calibration Iteration No.")+theme_bw()+ylab("Value")
   ggsave(filename=paste0(writePlotDir, "/", siteId, "_metric_calib_run_outlier.png"),
         plot=gg, units="in", width=8, height=6, dpi=300)

#############################################################################################################################################################################
#                      Create the plots without outliers
############################################################################################################################################################################3

  # Update basic objective function plot
   write("Basin objective function plot...", stdout())
   gg <- ggplot(data=x_archive_plot, aes(x=iter, y=obj)) +
              geom_point() + theme_bw() +
              labs(x="run", y="objective function") +
              ggtitle(paste0("ObjFun: ", siteId,  ", No. outliers = ", x_archive_plot_count, ", Threshold = ",  formatC(x_archive_plot_threshold, digits  = 4)))

   ggsave(filename=paste0(writePlotDir, "/", siteId, "_calib_run_obj.png"),
              plot=gg, units="in", width=6, height=5, dpi=300)

   # Update the Objective function versus the parameter variable
   write("Obj function vs. params...", stdout())
   DT.m1 = melt(x_archive_plot[, setdiff(names(x_archive_plot), metrics)], id.vars = c("obj"), measure.vars = setdiff( names(x_archive_plot), c(metrics, "iter", "obj")))
   DT.m1 <- subset(DT.m1, !is.na(DT.m1$value))
   gg <- ggplot2::ggplot(DT.m1, ggplot2::aes(value, obj))
   gg <- gg + ggplot2::geom_point(size = 1, color = "red", alpha = 0.3)+facet_wrap(~variable, scales="free_x")
   gg <- gg + ggplot2::ggtitle(paste0("ObjFun vs. Params: ", siteId,  ", No. outliers = ", x_archive_plot_count, ", Threshold = ",  formatC(x_archive_plot_threshold, digits  = 4)))
   gg <- gg + ggplot2::xlab("Parameter Values")+theme_bw()+ggplot2::ylab("Objective Function")
   ggsave(filename=paste0(writePlotDir, "/", siteId, "_obj_vs_parameters_calib_run.png"),
         plot=gg, units="in", width=8, height=6, dpi=300)


   # Plot the variables as a function of calibration runs
   write("Params over runs...", stdout())
   DT.m1 = melt(x_archive_plot[, setdiff(names(x_archive_plot), metrics)], id.vars = c("iter"), measure.vars = setdiff(names(x_archive_plot), c("iter", metrics)))
   DT.m1 <- subset(DT.m1, !is.na(DT.m1$value))
   gg <- ggplot2::ggplot(DT.m1, ggplot2::aes(iter, value))
   gg <- gg + ggplot2::geom_point(size = 1, color = "red", alpha = 0.3)+facet_wrap(~variable, scales="free")
   gg <- gg + ggplot2::ggtitle(paste0("Parameter vs. iteration: ", siteId,  ", No. outliers = ", x_archive_plot_count, ", Threshold = ",  formatC(x_archive_plot_threshold, digits  = 4)))
   gg <- gg + ggplot2::xlab("Calibration Iteration")+theme_bw()
   ggsave(filename=paste0(writePlotDir, "/", siteId, "_parameters_calib_run.png"),
         plot=gg, units="in", width=8, height=6, dpi=300)

   # Plot all the stats
   write("Metrics plot...", stdout())
   #DT.m1 = melt(x_archive_plot[,which(names(x_archive_plot) %in% c("iter", "obj", "cor", "rmse", "bias", "nse", "nselog", "nsewt", "kge", "msof"))],
   #            iter.vars = c("iter"), measure.vars = c("obj", "cor", "rmse", "bias", "nse", "nselog", "nsewt", "kge", "msof"))
   DT.m1 = melt(x_archive_plot[,which(names(x_archive_plot) %in% c("iter", "obj", "cor", "rmse", "bias", "nse", "nselog", "nsewt", "kge", "msof", "hyperResMultiObj"))],
               iter.vars = c("iter"), measure.vars = c("obj", "cor", "rmse", "bias", "nse", "nselog", "nsewt", "kge", "msof", "hyperResMultiObj"))
   DT.m1 <- subset(DT.m1, !is.na(DT.m1$value))
   gg <- ggplot2::ggplot(DT.m1, ggplot2::aes(iter, value))
   gg <- gg + ggplot2::geom_point(size = 1, color = "red", alpha = 0.3)+facet_wrap(~variable, scales="free")
   gg <- gg + ggplot2::ggtitle(paste0("Metric Sensitivity: ", siteId, ", No. outliers = ", x_archive_plot_count, ", Threshold = ",  formatC(x_archive_plot_threshold, digits  = 4)))
   gg <- gg + ggplot2::xlab("Calibration Iteration No.")+theme_bw()+ylab("Value")
   ggsave(filename=paste0(writePlotDir, "/", siteId, "_metric_calib_run.png"),
         plot=gg, units="in", width=8, height=6, dpi=300)

   # Plot the time series of the observed, control, best calibration result and last calibration iteration
   write("Hydrograph...", stdout())
   # The first iteration is the control run  called chrt.obj.1
   controlRun <- copy(chrt.obj.1)
   controlRun [, run := "Control Run"]
   # We have already advanced the cyclescount, so subtract 1 to get last complete
   lastRun <- copy(get(paste0("chrt.obj.", ifelse(lastcycle, cyclecount, cyclecount-1))))
   lastRun [ , run := "Last Run"]
   # the best iteration should be find
   bestRun <- copy(get(paste0("chrt.obj.", iter_best)))
   bestRun [ , run := "Best Run"]

   obsStrDataPlot <- copy(obs.obj)
   setnames(obsStrDataPlot, "obs", "q_cms")
   obsStrDataPlot <- obsStrDataPlot[, c("q_cms", "POSIXct", "site_no"), with=FALSE]
   obsStrDataPlot <- obsStrDataPlot[as.integer(POSIXct) >= min(as.integer(controlRun$POSIXct)) & as.integer(POSIXct) <= max(as.integer(controlRun$POSIXct)),]
   obsStrDataPlot[ , run := "Observation"]

   chrt.obj_plot <- rbindlist(list(controlRun, lastRun, bestRun, obsStrDataPlot), use.names = TRUE, fill=TRUE)
   # Cleanup
   rm(controlRun, lastRun, bestRun, obsStrDataPlot)


   gg <- ggplot2::ggplot(chrt.obj_plot, ggplot2::aes(POSIXct, q_cms, color = run))
   gg <- gg + ggplot2::geom_line(size = 0.3, alpha = 0.7)
   gg <- gg + ggplot2::ggtitle(paste0("Streamflow time series for ", siteId))
   #gg <- gg + scale_x_datetime(limits = c(as.POSIXct("2008-10-01"), as.POSIXct("2013-10-01")))
   gg <- gg + ggplot2::xlab("Date")+theme_bw( base_size = 15) + ylab ("Streamflow (cms)")
   gg <- gg + scale_color_manual(name="", values=c('black', 'dodgerblue', 'orange' , "dark green"),
                                 limits=c('Observation','Control Run', "Best Run", "Last Run"),
                                  label=c('Observation','Control Run', "Best Run", "Last Run"))

   ggsave(filename=paste0(writePlotDir, "/", siteId, "_hydrograph.png"),
           plot=gg, units="in", width=8, height=4, dpi=300)


# Plot the scatter plot of the best, last and control run.
   write("Scatterplot...", stdout())
   maxval <- max(chrt.obj_plot$q_cms, rm.na = TRUE)
   gg <- ggplot()+ geom_point(data = merge(chrt.obj_plot [run %in% c("Control Run", "Last Run", "Best Run")], obs.obj, by=c("site_no", "POSIXct"), all.x=FALSE, all.y=FALSE),
                              aes (obs, q_cms, color = run), alpha = 0.5)
   gg <- gg + scale_color_manual(name="", values=c('dodgerblue', 'orange' , "dark green"),
                                 limits=c('Control Run', "Best Run", "Last Run"),
                                 label=c('Control Run', "Best Run", "Last Run"))
   gg <- gg + ggtitle(paste0("Simulated vs observed flow : ", siteId )) + theme_bw( base_size = 15)
   gg <- gg + geom_abline(intercept = 0, slope = 1) + coord_equal()+ xlim(0,maxval) + ylim(0,maxval)
   gg <- gg + xlab("Observed flow (cms)") + ylab ("Simulated flow (cms)")

   ggsave(filename=paste0(writePlotDir, "/", siteId, "_scatter.png"),
           plot=gg, units="in", width=8, height=8, dpi=300)



#########################################################
# SAVE & EXIT
#########################################################

   # Save and exit
   rm(objFn, mCurrent, r, siteId, rtlinkFile, linkId, startDate, ncores)
   save.image(paste0(runDir, "/proj_data.Rdata"))

   # Write param files
   write.table(paramStats, file=paste0(runDir, "/params_stats.txt"), row.names=FALSE, sep=" ")
   if (cyclecount <= m) write.table(data.frame(t(x_new_out)), file=paste0(runDir, "/params_new.txt"), row.names=FALSE, sep=" ")

   #system(paste0("touch ", runDir, "/R_COMPLETE"))
   fileConn <- file(paste0(runDir, "/R_COMPLETE"))
   writeLines('', fileConn)
   close(fileConn)

   write(summary(proc.time()), stdout())

   quit("no")

 }

}



