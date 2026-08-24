# https://wiki.hpc.rug.nl/habrok/advanced_job_management/running_jobs_on_gpus
# Persistent shared storage                      
export QGPU_KEEP_ONLY="log,qfep.out"
export QGPU_ARCHIVE_EN="1"
export QGPU_SCRATCH_BASE="/scratch/$USER/qgpu_mps"           

# Hábrók GPU request
export SBATCH_GPUS_PER_NODE="a100:1"
export SBATCH_PARTITION=""
unset SBATCH_GRES

# One quarter of an A100 node
export SBATCH_CPUS_PER_TASK=16
export SBATCH_MEM=24G
export SBATCH_TIME=2:00:00

# Runtime software
export QGPU_MODULE_PURGE=1
export QGPU_MODULES="OpenMPI/4.1.4-GCC-11.3.0 CUDA/12.6.0"

# Replace these with your Hábrók installations
export QDYN="/home6/p323093/code/Q/bin/qdyn"
export QFEP="/home6/p323093/code/Q/src/q6/bin/q6/qfep"


./run_qgpu_mps_slurm.sh \
--dataset cdk2 \
--only FEP_1h1s_31 \
--system both \
--replicates 10 \
--dry-run