# Hábrók: adaptive lambda walk with 5x longer windows, benchmark inputs unchanged.
#
# Purpose: test whether longer sampling changes FEP_1h1r_1h1q in the original
# benchmark pose (baseline walk: ddG -2.63 +- 0.34, exp -0.51) and lowers the
# spread between replicates (protein-leg SD about 1.0).
#
# Run from the perturbations directory:
#   bash harbork_walk_long.sh            # dry run, prints the sbatch command
#   bash harbork_walk_long.sh --submit   # submit
#
# The inputs cdk2/1.water/FEP_1h1r_1h1q and cdk2/2.protein/FEP_1h1r_1h1q must
# exist. If they do not, generate them in cdk2/ with the usual setupFEP command.

EDGE="${EDGE:-FEP_1h1r_1h1q}"

# No trajectories: the walk never writes them. walk.tsv records the steps per window.
export QGPU_KEEP_ONLY="en,qfep.out,walk.tsv,walk.log,walk.err"
export QGPU_ARCHIVE_EN="0"
# Separate scratch base, so the normal-length cdk2 results are not overwritten.
export QGPU_SCRATCH_BASE="/scratch/$USER/qgpu_walk_long"

# Hábrók GPU request: one quarter of an A100 node
export SBATCH_GPUS_PER_NODE="a100:1"
export SBATCH_PARTITION=""
unset SBATCH_GRES
export SBATCH_CPUS_PER_TASK=16
export SBATCH_MEM=24G
# Normal length needs about 40 min for both legs; 5x longer needs 3-4 h.
export SBATCH_TIME=8:00:00

# Python API: adaptive walk
export QGPU_SCHEDULE=walk
export QGPU_PYTHON=$HOME/venvs/qgpu/bin/python
export QGPU_MODULE_PURGE=1
export QGPU_MODULES="OpenMPI/4.1.4-GCC-11.3.0 CUDA/12.6.0 Python/3.10.4-GCCcore-11.3.0"

# Defaults are --block 1000 --min-blocks 10 --max-blocks 50 (20-100 ps per window).
# Here: 100-500 ps per window. The block length stays 1000 steps, so the
# stability check runs as often as in the baseline.
export QGPU_WALK_ARGS="--min-blocks 50 --max-blocks 250"

export QDYN="/home6/p323093/code/Q/bin/qdyn"
export QFEP="/home6/p323093/code/Q/src/q6/bin/q6/qfep"

DRY_RUN="--dry-run"
if [[ "${1:-}" == "--submit" ]]; then
    DRY_RUN=""
fi

./run_qgpu_mps_slurm.sh \
--dataset cdk2 \
--only "$EDGE" \
--system both \
--replicates 10 \
$DRY_RUN
