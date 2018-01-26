# Program to adjust baseline domain parameter files for 
# sensitivity analysis. The following files will be adjusted:
# 1.) Fulldom.nc
# 2.) HYDRO_TBL_2D.nc
# 3.) soil_properties.nc
# 4.) GWBUCKPARM.nc

# Program is contingent on specific COMPLETE flag being
# generated from R. If this file is not created, then
# this program will exit gracefully without creating 
# it's own COMPLETE flag. Without the Python-generated
# COMPLETE flag, the workflow will generate an erroor
# message.

# Logan Karsten
# National Center for Atmospheric Research
# Research Applications Laboratory
# 303-497-2693

import argparse
import sys
from netCDF4 import Dataset
import os
import shutil
import pandas as pd
import time

def main(argv):
    # Parse arguments. Only input necessary is the run directory.
    parser = argparse.ArgumentParser(description='Main program to adjust input ' + \
             'parameters for the National Water Model')
    parser.add_argument('fullDomOrig',metavar='fullDomOrig',type=str,nargs='+',
                        help='Original Fulldom.nc file.')
    parser.add_argument('hydroOrig',metavar='hydroOrig',type=str,nargs='+',
                        help='Original HYDRO_TBL_2D.nc')
    parser.add_argument('soilOrig',metavar='soilOrig',type=str,nargs='+',
                        help='Original soil_properties.nc')
    parser.add_argument('gwOrig',metavar='GWBUCKPARM.nc',type=str,nargs='+',
                        help='Original GWBUCKPARM.nc')
    parser.add_argument('workDir',metavar='workDir',type=str,nargs='+',
                        help='Directory containing run subdirectories where final parameter' + \
                             ' files will reside')
    parser.add_argument('nIter',metavar='nIter',type=int,nargs='+',
                        help='Total number of parameter permutations')


    args = parser.parse_args()
    fullDomOrig = str(args.fullDomOrig[0])
    hydroOrig = str(args.hydroOrig[0])
    soilOrig = str(args.soilOrig[0])
    gwOrig = str(args.gwOrig[0])
    workDir = str(args.workDir[0])
    nIter = int(args.nIter[0])
    
    # Compose input file paths.
    rCompletePath = workDir + "/R_PRE_COMPLETE"
    adjTbl = workDir + "/params_new.txt"
    outFlag = workDir + "/preProc.COMPLETE"
    
    # If R COMPLETE flag not present, this implies the R code didn't run
    # to completion.
    if not os.path.isfile(rCompletePath):
        sys.exit(1)
        
    # Sleep for a few seconds in case R is still touching R_COMPLETE, or
    # from lingering parallel processes.
    time.sleep(10)
    
    os.remove(rCompletePath)
    
    # Read in new parameters table.
    newParams = pd.read_csv(adjTbl,sep=' ')
    paramNames = list(newParams.columns.values)
    
    # Loop through each parameter permutation. Copy the original parameter
    # file over to the run directory, then proceed to update the file
    # based on the values in the parameter table generated by R.
    for i in range(0,nIter):
        runDir = workDir + "/OUTPUT_" + str(i)
        
        print runDir
        if not os.path.isdir(runDir):
            sys.exit(1)
            
        # Copy default parameter files over to the run directory
        try:
            tmpPath = runDir + "/Fulldom.nc"
            print tmpPath
            shutil.copy(fullDomOrig,tmpPath)
        except:
            sys.exit(1)
        try:
            tmpPath = runDir + "/HYDRO_TBL_2D.nc"
            print tmpPath
            shutil.copy(hydroOrig,tmpPath)
        except:
            sys.exit(1)
        try:
            tmpPath = runDir + "/soil_properties.nc"
            print tmpPath
            shutil.copy(soilOrig,tmpPath)
        except:
            sys.exit(1)
        try:
            tmpPath = runDir + "/GWBUCKPARM.nc"
            print tmpPath
            shutil.copy(gwOrig,tmpPath)
        except:
            sys.exit(1)
            
        # Compose output file paths.
        fullDomOut = runDir + "/Fulldom.nc"
        hydroOut = runDir + "/HYDRO_TBL_2D.nc"
        soilOut = runDir + "/soil_properties.nc"
        gwOut = runDir + '/GWBUCKPARM.nc'
            
        # Open NetCDF parameter files for adjustment.
        idFullDom = Dataset(fullDomOut,'a')
        idSoil2D = Dataset(soilOut,'a')
        idGw = Dataset(gwOut,'a')
        idHydroTbl = Dataset(hydroOut,'a')
        
        # Loop through and adjust each parameter accordingly.
        for param in paramNames:
            if param == "bexp":
                idSoil2D.variables['bexp'][:,:,:,:] = idSoil2D.variables['bexp'][:,:,:,:]*float(newParams.bexp[i])
                
            if param == "smcmax":
                idSoil2D.variables['smcmax'][:,:,:,:] = idSoil2D.variables['smcmax'][:,:,:,:]*float(newParams.smcmax[i])
        
            if param == "slope":
                idSoil2D.variables['slope'][:,:,:] = float(newParams.slope[i])
        
            if param == "lksatfac":
                idFullDom.variables['LKSATFAC'][:,:] = float(newParams.lksatfac[i])
        
            if param == "zmax":
                idGw.variables['Zmax'][:] = float(newParams.zmax[i])
        
            if param == "expon":
                idGw.variables['Expon'][:] = float(newParams.expon[i])
        
            if param == "cwpvt":
                idSoil2D.variables['cwpvt'][:,:,:] = idSoil2D.variables['cwpvt'][:,:,:]*float(newParams.cwpvt[i])
        
            if param == "vcmx25":
                idSoil2D.variables['vcmx25'][:,:,:] = idSoil2D.variables['vcmx25'][:,:,:]*float(newParams.vcmx25[i])
        
            if param == "mp":
                idSoil2D.variables['mp'][:,:,:] = idSoil2D.variables['mp'][:,:,:]*float(newParams.mp[i])
        
            if param == "hvt":
                idSoil2D.variables['hvt'][:,:,:] = idSoil2D.variables['hvt'][:,:,:]*float(newParams.hvt[i])
        
            if param == "mfsno":
                idSoil2D.variables['mfsno'][:,:,:] = idSoil2D.variables['mfsno'][:,:,:]*float(newParams.mfsno[i])
        
            if param == "refkdt":
                idSoil2D.variables['refkdt'][:,:,:] = float(newParams.refkdt[i])
        
            if param == "dksat":
                idSoil2D.variables['dksat'][:,:,:,:] = idSoil2D.variables['dksat'][:,:,:,:]*float(newParams.dksat[i])
        
            if param == "retdeprtfac":
                idFullDom.variables['RETDEPRTFAC'][:,:] = float(newParams.retdeprtfac[i])
            
            if param == "ovroughrtfac":
                idFullDom.variables['OVROUGHRTFAC'][:,:] = float(newParams.ovroughrtfac[i])
            
            if param == "dksat":
                idHydroTbl.variables['LKSAT'][:,:] = idHydroTbl.variables['LKSAT'][:,:]*float(newParams.dksat[i])
            
            if param == "smcmax":
                idHydroTbl.variables['SMCMAX1'][:,:] = idHydroTbl.variables['SMCMAX1'][:,:]*float(newParams.smcmax[i])       
        
            
    # Close NetCDF files
    idFullDom.close()
    idSoil2D.close()
    idGw.close()
    idHydroTbl.close()
            
    # Touch empty COMPLETE flag file. This will be seen by workflow, demonstrating
    # calibration iteration is complete.
    try:
        open(outFlag,'a').close()
    except:
        sys.exit(6)

if __name__ == "__main__":
    main(sys.argv[1:]) 
