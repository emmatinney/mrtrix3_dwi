#!/bin/bash 
#SBATCH --job-name=mrtrix
#SBATCH --time=24:00:00
#SBATCH -n 1
#SBATCH --cpus-per-task=16
#SBATCH --mem-per-cpu=4G

#if [ $# -lt 1 ] ; then
#        echo '
#------ MRTRIX PRE-PROCESSING FOR FBA --------

#'
#	       exit 0
#fi

#while getopts i: flag

#do
	
#    case "${flag}" in
#		i) SUBJID="$OPTARG";;
#    esac
	
#done
	
	#load required software
	module unload fsl #was causing issues before ... just unload in case something already loaded
	module load singularity
	module load fsl/6.0.0
	module load freesurfer
	. ${FSLDIR}/etc/fslconf/fsl.sh
	
	#bind folder to singularity
	export SINGULARITY_BIND="/work/cnelab/TECHS/MRI:/mnt,/shared/centos7"
	SUBJID=04

	#define/create some directories
	RAW_DIR=/mnt/raw/Techs_${SUBJID}_pre #where the raw DWI data are stored
	RAW_DIR_NS=/work/cnelab/TECHS/MRI/raw/Techs_${SUBJID}_pre
	#RAW_DIR_FMAP_NS=/work/cnelab/TECHS/MRI/BID/${SUBJID}/fmap
	#RAW_DIR_FMAP=/mnt/BID/${SUBJID}/fmap
	FS_DIR=/mnt/BIDS/derivatives/freesurfer_7.2.0/sub-${SUBJID} #where the already-run Freesurfer output is stored
	FS_DIR_NS=/work/cnelab/TECHS/MRI/BIDS/derivatives/freesurfer_7.2.0/sub-${SUBJID} #non-singularity path to freesurfer folder
	SUBJECTS_DIR=/work/cnelab/TECHS/MRI/BIDS/sub-${SUBJID} #for freesurfer commands
	PP_DIR=/mnt/preprocessed_data/dwi/sub-${SUBJID} #where the additionally processed data are stored
	PP_DIR_NS=/work/cnelab/TECHS/MRI/preprocessed_data/dwi/sub-${SUBJID} #path to pre-processed folder OUTSIDE singularity 
	RF_DIR=/work/cnelab/TECHS/MRI/preprocessed_data/dwi/GROUP-RF #where the subject-specific tissue response functions should be copied to, for group averaging 
	if [ ! -d ${PP_DIR_NS} ]; then mkdir ${PP_DIR_NS}; fi
	if [ ! -d ${RF_DIR} ]; then mkdir ${RF_DIR}; fi

	#path to mrtrix3 singularity container, for executing mrtrix commands
	mx=/shared/container_repository/MRtrix/MRtrix3.sif
	
	
    singularity exec ${mx} dwifslpreproc ${PP_DIR}/DWI_APPA_DN_UR.mif ${PP_DIR}/DWI_APPA_DN_UR_UD.mif -nocleanup -rpe_all -pe_dir AP
	singularity exec ${mx} mrconvert ${PP_DIR}/DWI_APPA_DN_UR_UD.mif ${PP_DIR}/DWI_APPA_DN_UR_UD.nii.gz
	singularity exec ${mx} mrinfo $PP_DIR/DWI_APPA_DN_UR_UD.mif -export_grad_fsl $PP_DIR/DWI_APPA_DN_UR_UD.bvec $PP_DIR/DWI_APPA_DN_UR_UD.bval

	#bias field correction using ants, save out bias field as image - note *BC = bias-corrected
	singularity exec ${mx} dwibiascorrect ants ${PP_DIR}/DWI_APPA_DN_UR_UD.mif ${PP_DIR}/DWI_APPA_DN_UR_UD_BC.mif -bias ${PP_DIR}/BIAS.mif
	
	#create mean b-zero image (undistorted, bias field-corrected), save as .nii.gz
	singularity exec ${mx} dwiextract ${PP_DIR}/DWI_APPA_DN_UR_UD_BC.mif -bzero ${PP_DIR}/DWI_APPA_DN_UR_UD_BC_B0S.mif
	singularity exec ${mx} mrmath ${PP_DIR}/DWI_APPA_DN_UR_UD_BC_B0S.mif mean $PP_DIR/MEANB0.nii.gz -axis 3
	  
	#create brain mask - two versions (one using dwi2mask and another using fsl's bet, just in case one works better ...)
	singularity exec ${mx} dwi2mask ${PP_DIR}/DWI_APPA_DN_UR_UD_BC.mif ${PP_DIR}/MASK.mif 
	bet2 ${PP_DIR_NS}/MEANB0.nii.gz ${PP_DIR_NS}/ALTMASK_BET2.nii.gz -m
	singularity exec ${mx} mrconvert ${PP_DIR}/MASK.mif ${PP_DIR}/MASK.nii.gz
    #perform DTIFIT for TBSS analysis
    dtifit -k DWI_APPA_DN_UR_UD.nii.gz -o ${SUBJID}_output -m ALTMASK_BET2_mask.nii.gz -r DWI_APPA_DN_UR_UD.bvec -b DWI_APPA_DN_UR_UD.bval 

	#estimate subject-specific tissue response functions using 'dhollander' method
	singularity exec ${mx} dwi2response dhollander -voxels ${PP_DIR}/RF_VOXELS_DHOLL.mif ${PP_DIR}/DWI_APPA_DN_UR_UD_BC.mif ${PP_DIR}/RF_WM_DHOLL.txt ${PP_DIR}/RF_GM_DHOLL.txt ${PP_DIR}/RF_CSF_DHOLL.txt 
	
	#copy subject-specific tissue response functions to common group directory for group-averaging
	cp ${PP_DIR_NS}/RF_WM_DHOLL.txt ${RF_DIR}/${SUBJID}_RF_WM_DHOLL.txt 
	cp ${PP_DIR_NS}/RF_GM_DHOLL.txt ${RF_DIR}/${SUBJID}_RF_GM_DHOLL.txt
	cp ${PP_DIR_NS}/RF_CSF_DHOLL.txt ${RF_DIR}/${SUBJID}_RF_CSF_DHOLL.txt
	
	#workaround to use old fsl. fsl_sub not working in other version
	module unload fsl
	module unload fsl/6.0.0
	module load fsl/2019-01-11
	. ${FSLDIR}/etc/fslconf/fsl.sh
	
	#generate a "5 tissue type" segmentation from freesurfer output using hybrid surface-volume method
	singularity exec ${mx} 5ttgen -nocrop hsvs ${FS_DIR} ${PP_DIR}/5tt_hsvs.nii.gz #note save as .nii.gz because want to apply transforms to this outside of mrtrix 
	
	#calculate registration (DWI-to-T1), using Freesurfer's bbregister
	bbregister --s ../derivatives/freesurfer_7.2.0/sub-${SUBJID} --mov ${PP_DIR_NS}/MEANB0.nii.gz --reg ${PP_DIR_NS}/MEANB02MRIFS.lta --dti --o ${PP_DIR_NS}/MEANB02MRIFS.nii.gz
	
	#register 5tt segmentation to mean b0, using INVERSE of transform calculated above
	mri_vol2vol --mov ${PP_DIR_NS}/MEANB0.nii.gz --targ ${PP_DIR_NS}/5tt_hsvs.nii.gz --lta ${PP_DIR_NS}/MEANB02MRIFS.lta --inv --interp nearest --o ${PP_DIR_NS}/5tt_hsvs2MEANB0.nii.gz
	