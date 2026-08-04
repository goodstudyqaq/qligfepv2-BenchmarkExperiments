/home/sguo/code/qligfepv2-BenchmarkExperiments/perturbations

srun -p staging -t 04:00:00 -c 2 --mem=4G \
  bash -c 'source /home/sguo/code/qligfepv2-BenchmarkExperiments/perturbations/backup_qgpu_mps.sh &&
           QGPU_BACKUP_INCLUDE_EN=1 backup_qgpu_mps'


sbatch \
  --job-name=qgpu_backup2 \
  --partition=staging \
  --time=04:00:00 \
  --ntasks=1 \
  --cpus-per-task=2 \
  --mem=4G \
  --chdir="$PWD" \
  --output=qgpu_backup.%j.log \
  --wrap='bash -c "source /home/sguo/code/qligfepv2-BenchmarkExperiments/perturbations/backup_qgpu_mps.sh && QGPU_BACKUP_INCLUDE_EN=1 QGPU_BACKUP_THREADS=2 backup_qgpu_mps"'