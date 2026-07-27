# https://wiki.hpc.rug.nl/habrok/advanced_job_management/running_jobs_on_gpus
# Persistent shared storage                      
  # Snellius A100 allocation: exactly one quarter-node
  export SBATCH_PARTITION="gpu_a100"
  export SBATCH_GPUS_PER_NODE="1"
  unset SBATCH_GRES

  export SBATCH_CPUS_PER_TASK="18"
  export SBATCH_MEM="24G"
  export SBATCH_TIME="2:00:00"

  # Shared result location and job-local staging


  # Preserve every QDyn/QFEP output in staged_run.tar.gz
  export CLEAN_AFTER="0"

  # Let MPS share the GPU dynamically
  unset MPS_ACTIVE_THREAD_PERCENTAGE

  # Load a clean, current Snellius software environment
  export QGPU_MODULE_PURGE="1"
  export QGPU_MODULES="2024 CUDA/12.6.0"

  # Adjust to your Q installation
  export QDYN="$HOME/code/Q/bin/qdyn"
  export QFEP="$HOME/code/Q/src/q6/bin/q6/qfep"



  export QGPU_SCRATCH_BASE="/scratch-shared/$USER/qgpu_mps/bace"
  export JOB_NAME="cdk2-mps-bace"
./run_qgpu_mps_slurm.sh \
--dataset cdk2 \
--only FEP_1h1s_31 \
--system both \
--replicates 10 \
--dry-run